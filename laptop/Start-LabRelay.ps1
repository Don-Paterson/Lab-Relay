<#
.SYNOPSIS
    Lab-Relay laptop watcher: sends scripts from outbox\ to the lab and collects results.

.DESCRIPTION
    Run this on the laptop while a lab session is in use. It:
      - watches outbox\ and, once a .ps1 has stopped changing, commits it to the private
        channel repo as a job, then moves the original to outbox\sent\
      - pulls the channel every PollSeconds and copies finished results into results\<jobId>\
      - shows the lab's heartbeat so you can see whether the runner is alive
      - squashes the channel history when it grows past CompactThresholdMB

    Nothing that comes back from the lab is ever executed here. Results are filtered by
    name, extension and size before they are written to results\.

    Authentication is whatever git already uses on this machine (Git Credential Manager
    holding the fine-grained PAT).

.PARAMETER Root
    The Lab-Relay folder. Defaults to the parent of the folder this script is in.

.PARAMETER Once
    Do one full cycle (send, pull, collect) and exit. Useful for testing.

.PARAMETER Compact
    Squash the channel history now, then continue (or exit with -Once).

.PARAMETER ChannelUrl
    Override the channel remote. For testing against a local bare repository.

.EXAMPLE
    .\laptop\Start-LabRelay.ps1

.EXAMPLE
    .\laptop\Start-LabRelay.ps1 -Compact -Once
#>
[CmdletBinding()]
param(
    [string]$Root,
    [switch]$Once,
    [switch]$Compact,
    [string]$ChannelUrl
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = (Resolve-Path -LiteralPath $Root).Path
$cfg  = Import-PowerShellDataFile -LiteralPath (Join-Path $Root 'config/relay.psd1')

$paths = [ordered]@{
    Outbox   = Join-Path $Root 'outbox'
    Sent     = Join-Path $Root 'outbox/sent'
    Rejected = Join-Path $Root 'outbox/rejected'
    Results  = Join-Path $Root 'results'
    Logs     = Join-Path $Root 'logs'
    Channel  = Join-Path $Root '.channel'
}
foreach ($p in $paths.Values) { if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }
if (-not $ChannelUrl) { $ChannelUrl = "https://github.com/$($cfg.Owner)/$($cfg.ChannelRepo).git" }

$JobIdPattern  = '^\d{8}-\d{6}-[A-Za-z0-9._-]{1,60}-[0-9a-f]{6}$'
$FileNameRegex = '^[A-Za-z0-9][A-Za-z0-9._ -]{0,100}$'
$TerminalState = @('done', 'failed', 'timeout', 'abandoned', 'expired', 'error', 'rejected')

# ------------------------------------------------------------------ output ---
$script:logFile = Join-Path $paths.Logs ("watcher-{0:yyyyMMdd}.log" -f (Get-Date))
function Write-Relay {
    param([string]$Text, [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'DIM')][string]$Level = 'INFO')
    $colour = @{ INFO = 'White'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red'; DIM = 'DarkGray' }[$Level]
    $line = '{0:HH:mm:ss}  {1}' -f (Get-Date), $Text
    Write-Host $line -ForegroundColor $colour
    try { Add-Content -LiteralPath $script:logFile -Value ("{0:yyyy-MM-dd HH:mm:ss} {1,-5} {2}" -f (Get-Date), $Level, $Text) } catch { }
}

# --------------------------------------------------------------------- git ---
function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments)][string[]]$GitArgs)
    $out = & git -C $paths.Channel @GitArgs 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed ($LASTEXITCODE): $($out -join ' | ')" }
    return $out
}

function Initialize-Channel {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git is not on PATH.' }
    if (-not (Test-Path -LiteralPath (Join-Path $paths.Channel '.git'))) {
        Write-Relay "Cloning channel $ChannelUrl ..."
        Remove-Item -LiteralPath $paths.Channel -Recurse -Force -ErrorAction SilentlyContinue
        $out = & git clone --quiet --branch $cfg.Branch $ChannelUrl $paths.Channel 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw @"
Could not clone $ChannelUrl
$($out -join "`n")
  401/403 -> the PAT has expired or does not cover $($cfg.ChannelRepo)
  not found -> check Owner / ChannelRepo in config\relay.psd1
"@
        }
    }
    # Machine-managed clone: bytes in == bytes out, identifiable commits.
    Invoke-Git config core.autocrlf false | Out-Null
    Invoke-Git config core.safecrlf false | Out-Null
    Invoke-Git config user.name 'Lab-Relay (laptop)' | Out-Null
    Invoke-Git config user.email "$($cfg.Owner)@users.noreply.github.com" | Out-Null

    Sync-Channel
    $attr = Join-Path $paths.Channel '.gitattributes'
    if (-not (Test-Path -LiteralPath $attr)) {
        Set-Content -LiteralPath $attr -Value '* -text' -NoNewline
        Invoke-Git add .gitattributes | Out-Null
        Invoke-Git commit --quiet -m 'Channel: store every file byte-for-byte' | Out-Null
        Push-Channel
    }
}

function Sync-Channel {
    # The channel is written only by this watcher and the lab runner, and every local
    # change is pushed at once - so the remote is always the truth. A hard reset also
    # copes with a history squash done by -Compact.
    Invoke-Git fetch --quiet origin $cfg.Branch | Out-Null
    Invoke-Git reset --quiet --hard "origin/$($cfg.Branch)" | Out-Null
    Invoke-Git clean --quiet -fdx | Out-Null
}

function Push-Channel {
    for ($i = 1; $i -le 4; $i++) {
        & git -C $paths.Channel push --quiet origin "HEAD:$($cfg.Branch)" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return }
        # Usually the lab pushed a result in between. Replay our commit on top.
        Write-Relay "Push rejected (attempt $i) - rebasing on the remote." WARN
        Invoke-Git fetch --quiet origin $cfg.Branch | Out-Null
        & git -C $paths.Channel rebase --quiet "origin/$($cfg.Branch)" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { & git -C $paths.Channel rebase --abort 2>&1 | Out-Null; throw 'Rebase onto the channel failed.' }
        Start-Sleep -Seconds (2 * $i)
    }
    throw 'Could not push to the channel after 4 attempts.'
}

# ------------------------------------------------------------------ outbox ---
$script:seen = @{}   # path -> "length|mtimeTicks" from the previous look

function Test-FileReady {
    param([IO.FileInfo]$File)
    $sig = '{0}|{1}' -f $File.Length, $File.LastWriteTimeUtc.Ticks
    $prev = $script:seen[$File.FullName]
    $script:seen[$File.FullName] = $sig
    $quiet = ((Get-Date).ToUniversalTime() - $File.LastWriteTimeUtc).TotalSeconds -ge $cfg.StableSeconds
    if (-not $quiet) { return $false }
    if ($prev -and $prev -ne $sig) { return $false }
    try {
        $fs = [IO.File]::Open($File.FullName, 'Open', 'Read', 'None')   # exclusive: nobody still writing
        $fs.Dispose()
        return $true
    } catch { return $false }
}

function Get-SafeName {
    param([string]$Name)
    $n = ($Name -replace '[^A-Za-z0-9._-]', '-') -replace '-{2,}', '-'
    $n = $n.Trim('-', '.')
    if ($n.Length -gt 60) { $n = $n.Substring(0, 60) }
    if (-not $n) { $n = 'script' }
    return $n
}

function Get-JobOptions {
    param([string]$Text)
    $opts = @{ timeout = [int]$cfg.DefaultTimeoutSeconds }
    foreach ($m in [regex]::Matches($Text, '(?im)^\s*#\s*relay:\s*(.+)$')) {
        foreach ($pair in ($m.Groups[1].Value -split '[\s,;]+')) {
            if ($pair -match '^timeout=(\d+)$') {
                $opts.timeout = [math]::Min([int]$Matches[1], [int]$cfg.MaxTimeoutSeconds)
            }
        }
    }
    return $opts
}

function Move-Unique {
    param([string]$Source, [string]$DestDir, [string]$Name)
    $dest = Join-Path $DestDir $Name
    if (Test-Path -LiteralPath $dest) {
        $base = [IO.Path]::GetFileNameWithoutExtension($Name); $ext = [IO.Path]::GetExtension($Name)
        $dest = Join-Path $DestDir ('{0}_{1:HHmmssfff}{2}' -f $base, (Get-Date), $ext)
    }
    Move-Item -LiteralPath $Source -Destination $dest
    return $dest
}

function Publish-Outbox {
    $files = Get-ChildItem -LiteralPath $paths.Outbox -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '^[.~]|\.tmp$|~$' } | Sort-Object LastWriteTimeUtc

    # Forget files that have gone.
    foreach ($k in @($script:seen.Keys)) { if (-not (Test-Path -LiteralPath $k)) { $script:seen.Remove($k) } }

    $ready = @()
    foreach ($f in $files) {
        if ($f.Extension.ToLowerInvariant() -notin $cfg.JobExtensions) {
            $to = Move-Unique $f.FullName $paths.Rejected $f.Name
            Write-Relay "Not sent: $($f.Name) - only $($cfg.JobExtensions -join ', ') files run in the lab. Moved to outbox\rejected\." WARN
            continue
        }
        if ($f.Length -gt $cfg.MaxFileBytes) {
            Move-Unique $f.FullName $paths.Rejected $f.Name | Out-Null
            Write-Relay "Not sent: $($f.Name) is larger than $([int]($cfg.MaxFileBytes / 1MB)) MB." WARN
            continue
        }
        if (Test-FileReady $f) { $ready += $f }
    }
    if (-not $ready) { return }

    Sync-Channel
    $made = @()
    foreach ($f in $ready) {
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        $sha   = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $safe  = Get-SafeName $f.BaseName
        $now   = (Get-Date).ToUniversalTime()
        do {
            $jobId = '{0:yyyyMMdd-HHmmss}-{1}-{2}' -f $now, $safe, $sha.Substring(0, 6)
            $jobDir = Join-Path $paths.Channel "jobs/$jobId"
            $now = $now.AddSeconds(1)
        } while (Test-Path -LiteralPath $jobDir)

        $text = [Text.Encoding]::UTF8.GetString($bytes)
        $opts = Get-JobOptions $text
        New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
        $scriptName = $safe + $f.Extension.ToLowerInvariant()
        [IO.File]::WriteAllBytes((Join-Path $jobDir $scriptName), $bytes)
        $job = [ordered]@{
            id         = $jobId
            script     = $scriptName
            original   = $f.Name
            sha256     = $sha
            bytes      = $bytes.Length
            queuedUtc  = (Get-Date).ToUniversalTime().ToString('o')
            timeout    = $opts.timeout
            from       = [Environment]::MachineName
        }
        $job | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $jobDir 'job.json') -Encoding utf8NoBOM
        $made += [pscustomobject]@{ Id = $jobId; File = $f; Timeout = $opts.timeout }
    }

    Invoke-Git add jobs | Out-Null
    $msg = if ($made.Count -eq 1) { "job $($made[0].Id)" } else { "jobs: $($made.Id -join ', ')" }
    Invoke-Git commit --quiet -m $msg | Out-Null
    Push-Channel

    foreach ($m in $made) {
        $script:seen.Remove($m.File.FullName)
        Move-Unique $m.File.FullName $paths.Sent ("{0}{1}" -f $m.Id, $m.File.Extension) | Out-Null
        Write-Relay ("Sent   {0}  (timeout {1}s)" -f $m.Id, $m.Timeout) OK
    }
}

# ----------------------------------------------------------------- results ---
$script:reported = @{}   # jobId -> last status shown

function Receive-Results {
    $resRoot = Join-Path $paths.Channel 'results'
    if (-not (Test-Path -LiteralPath $resRoot)) { return }

    foreach ($dir in Get-ChildItem -LiteralPath $resRoot -Directory) {
        $jobId = $dir.Name
        if ($jobId -notmatch $JobIdPattern) { continue }
        $rj = Join-Path $dir.FullName 'result.json'
        if (-not (Test-Path -LiteralPath $rj -PathType Leaf)) { continue }
        try { $res = Get-Content -LiteralPath $rj -Raw | ConvertFrom-Json } catch { continue }
        $status = "$($res.status)"

        if ($status -notin $TerminalState) {
            if ($script:reported[$jobId] -ne $status) {
                $script:reported[$jobId] = $status
                Write-Relay "Lab    $jobId  $status" DIM
            }
            continue
        }

        $dest = Join-Path $paths.Results $jobId
        $localRj = Join-Path $dest 'result.json'
        if ((Test-Path -LiteralPath $localRj) -and
            ((Get-FileHash -LiteralPath $localRj).Hash -eq (Get-FileHash -LiteralPath $rj).Hash)) { continue }

        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        $skipped = @()
        foreach ($f in Get-ChildItem -LiteralPath $dir.FullName -Force) {
            $why = $null
            if ($f.PSIsContainer)                                      { $why = 'sub-folder' }
            elseif ($f.Name -notmatch $FileNameRegex)                  { $why = 'unsafe name' }
            elseif ($f.Extension.ToLowerInvariant() -notin $cfg.ResultExtensions) { $why = "extension $($f.Extension)" }
            elseif ($f.Length -gt $cfg.MaxFileBytes)                   { $why = "larger than $([int]($cfg.MaxFileBytes / 1MB)) MB" }
            if ($why) { $skipped += "$($f.Name)  ($why)"; continue }
            if ($f.Name -eq 'result.json') { continue }               # written last
            $tmp = Join-Path $dest ".$($f.Name).tmp"
            Copy-Item -LiteralPath $f.FullName -Destination $tmp -Force
            Move-Item -LiteralPath $tmp -Destination (Join-Path $dest $f.Name) -Force
        }
        if ($skipped) {
            Set-Content -LiteralPath (Join-Path $dest '_skipped.txt') -Encoding utf8NoBOM -Value (
                @('Files the lab returned that the collector did not accept:') + $skipped)
        }
        Copy-Item -LiteralPath $rj -Destination $localRj -Force

        $script:reported[$jobId] = $status
        $level = if ($status -eq 'done') { 'OK' } else { 'WARN' }
        $extra = @()
        if ($null -ne $res.PSObject.Properties['exitCode'] -and $null -ne $res.exitCode) { $extra += "exit $($res.exitCode)" }
        if ($null -ne $res.PSObject.Properties['durationSeconds']) { $extra += "$($res.durationSeconds)s" }
        if ($skipped) { $extra += "$($skipped.Count) file(s) skipped" }
        Write-Relay ("Result {0}  {1}  {2}" -f $jobId, $status.ToUpperInvariant(), ($extra -join ', ')) $level
    }
}

# --------------------------------------------------------------- heartbeat ---
$script:lastLab = ''
function Show-LabStatus {
    $sess = Join-Path $paths.Channel 'sessions'
    if (-not (Test-Path -LiteralPath $sess)) { return }
    $latest = Get-ChildItem -LiteralPath $sess -Filter '*.json' -File | ForEach-Object {
        try { $s = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json; $s } catch { }
    } | Where-Object { $_.lastSeenUtc } | Sort-Object { [datetime]$_.lastSeenUtc } -Descending | Select-Object -First 1
    if (-not $latest) { return }
    $age  = ((Get-Date).ToUniversalTime() - ([datetime]$latest.lastSeenUtc).ToUniversalTime()).TotalMinutes
    $state = if ($latest.PSObject.Properties['state'] -and $latest.state -eq 'stopped') { 'stopped' }
             elseif ($age -lt 20) { 'online' } else { 'silent' }
    $text = "Lab    $($latest.id)  $state"
    if ($text -ne $script:lastLab) {
        $script:lastLab = $text
        Write-Relay $text $(if ($state -eq 'online') { 'OK' } else { 'DIM' })
    }
}

# ----------------------------------------------------------------- compact ---
function Get-ChannelSizeMB {
    $kb = 0
    foreach ($line in Invoke-Git count-objects -v) {
        if ($line -match '^(size|size-pack):\s*(\d+)') { $kb += [int]$Matches[2] }
    }
    return [math]::Round($kb / 1024, 1)
}

function Invoke-Compact {
    param([switch]$Force)
    Sync-Channel
    $size = Get-ChannelSizeMB
    if (-not $Force -and $size -lt $cfg.CompactThresholdMB) { return }

    # Never squash while the lab is mid-job: its result commit would be lost.
    $running = Get-ChildItem -LiteralPath (Join-Path $paths.Channel 'results') -Filter result.json -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { try { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).status -eq 'running' } catch { $false } }
    if ($running) { Write-Relay 'Compact postponed - a job is running in the lab.' DIM; return }

    $cutoff = (Get-Date).ToUniversalTime().AddDays(-$cfg.CompactKeepDays).ToString('yyyyMMdd')
    $removed = 0
    foreach ($area in 'jobs', 'results') {
        $d = Join-Path $paths.Channel $area
        if (-not (Test-Path -LiteralPath $d)) { continue }
        foreach ($j in Get-ChildItem -LiteralPath $d -Directory) {
            if ($j.Name.Substring(0, [math]::Min(8, $j.Name.Length)) -lt $cutoff) { Remove-Item -LiteralPath $j.FullName -Recurse -Force; $removed++ }
        }
    }
    $s = Join-Path $paths.Channel 'sessions'
    if (Test-Path -LiteralPath $s) {
        Get-ChildItem -LiteralPath $s -File | Where-Object { $_.LastWriteTimeUtc -lt (Get-Date).ToUniversalTime().AddDays(-$cfg.CompactKeepDays) } |
            Remove-Item -Force
    }

    $base = (Invoke-Git rev-parse HEAD | Select-Object -First 1).Trim()
    Invoke-Git checkout --quiet --orphan relay-compact | Out-Null
    Invoke-Git add -A | Out-Null
    Invoke-Git commit --quiet -m ("Channel compacted {0:yyyy-MM-dd HH:mm} UTC - kept last {1} days" -f (Get-Date).ToUniversalTime(), $cfg.CompactKeepDays) | Out-Null
    # Lease on the commit we built from: if the lab pushed in the meantime, refuse.
    & git -C $paths.Channel push --quiet "--force-with-lease=$($cfg.Branch):$base" origin "HEAD:$($cfg.Branch)" 2>&1 | Out-Null
    $ok = $LASTEXITCODE -eq 0
    Invoke-Git checkout --quiet -B $cfg.Branch | Out-Null
    & git -C $paths.Channel branch -D relay-compact 2>&1 | Out-Null
    if (-not $ok) { Write-Relay 'Compact skipped - the channel changed while compacting. Will try again later.' WARN; Sync-Channel; return }
    Invoke-Git branch --quiet "--set-upstream-to=origin/$($cfg.Branch)" | Out-Null
    Sync-Channel
    Invoke-Git reflog expire --expire=now --all | Out-Null
    Invoke-Git gc --quiet --prune=now | Out-Null
    Write-Relay ("Compacted channel: {0} MB -> {1} MB, {2} old job folder(s) removed." -f $size, (Get-ChannelSizeMB), $removed) OK
}

# -------------------------------------------------------------------- main ---
$lockPath = Join-Path $paths.Logs 'watcher.lock'
try { $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
catch { Write-Relay 'Another Lab-Relay watcher is already running for this folder.' ERROR; return }

try {
    Write-Host ''
    Write-Host '  Lab-Relay watcher' -ForegroundColor Cyan
    Write-Host "  Folder : $Root" -ForegroundColor DarkGray
    Write-Host "  Channel: $ChannelUrl" -ForegroundColor DarkGray
    Write-Host "  Drop a .ps1 into outbox\ to run it in the lab. Ctrl+C to stop." -ForegroundColor DarkGray
    Write-Host ''

    Initialize-Channel
    if ($Compact) { Invoke-Compact -Force }
    Write-Relay ("Channel ready ({0} MB). Watching outbox\ - results are checked every {1}s." -f (Get-ChannelSizeMB), $cfg.PollSeconds) OK

    $nextPull = [datetime]::MinValue
    $nextCompact = (Get-Date).AddMinutes(10)
    $failures = 0
    while ($true) {
        try {
            Publish-Outbox
            if ((Get-Date) -ge $nextPull -or $Once) {
                Sync-Channel
                Receive-Results
                Show-LabStatus
                $nextPull = (Get-Date).AddSeconds($cfg.PollSeconds)
            }
            if ((Get-Date) -ge $nextCompact) { Invoke-Compact; $nextCompact = (Get-Date).AddHours(1) }
            $failures = 0
        } catch {
            $failures++
            Write-Relay "Cycle failed: $($_.Exception.Message)" ERROR
            if ($Once) { throw }
            Start-Sleep -Seconds ([math]::Min(300, 15 * $failures))
        }
        if ($Once) { break }
        Start-Sleep -Seconds $cfg.OutboxCheckSeconds
    }
} finally {
    $lock.Dispose()
}
