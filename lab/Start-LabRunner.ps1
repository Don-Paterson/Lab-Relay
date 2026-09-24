<#
.SYNOPSIS
    Lab-Relay runner for A-GUI: runs jobs from the private channel repo and returns results.

.DESCRIPTION
    Normally started by bootstrap.ps1. It:
      1. checks that every GitHub host presents a genuine public certificate (refuses to
         authenticate if the upstream TLS inspection has started decrypting GitHub)
      2. signs in with the Lab-Relay GitHub App using device flow - you type the code it
         shows at github.com/login/device on the laptop or phone
      3. polls the channel every PollSeconds, runs each new job in a child pwsh with a
         timeout, and uploads output.txt, result.json and any saved files as one commit

    The token lives in this process only. It is never written to disk or printed. Close
    the window and it is gone; run the bootstrap again to start a new session.

.PARAMETER TestApiBase
    Testing only: API root of a mock server. Skips the TLS check and device flow.

.PARAMETER TestToken
    Testing only: bearer token for the mock server.
#>
[CmdletBinding()]
param(
    [string]$Root,
    [int]$PollSeconds,
    [string]$TestApiBase,
    [string]$TestToken
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$RunnerVersion = '0.2.0'

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$cfg = Import-PowerShellDataFile -LiteralPath (Join-Path $Root 'config/relay.psd1')
if (-not $PollSeconds) { $PollSeconds = $cfg.PollSeconds }

$Repo      = "$($cfg.Owner)/$($cfg.ChannelRepo)"
$ApiBase   = if ($TestApiBase) { $TestApiBase.TrimEnd('/') } else { 'https://api.github.com' }
$WorkRoot  = if ($IsWindows) { 'C:\LabRelay' } else { Join-Path ([IO.Path]::GetTempPath()) 'LabRelay' }
$Helpers   = Join-Path $PSScriptRoot 'LabRelay.Helpers.psm1'
$JobIdPattern  = '^\d{8}-\d{6}-[A-Za-z0-9._-]{1,60}-[0-9a-f]{6}$'
$FileNameRegex = '^[A-Za-z0-9][A-Za-z0-9._ -]{0,100}$'
$HeartbeatMinutes = 10

$hostName  = [Environment]::MachineName
$SessionId = '{0}-{1:yyyyMMdd-HHmm}-{2}' -f $hostName, (Get-Date).ToUniversalTime(), ([guid]::NewGuid().ToString('N').Substring(0, 4))
$SessionStart = (Get-Date).ToUniversalTime()

# ------------------------------------------------------------------ output ---
function Write-Run {
    param([string]$Text, [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'DIM')][string]$Level = 'INFO')
    $colour = @{ INFO = 'White'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red'; DIM = 'DarkGray' }[$Level]
    Write-Host ('{0:HH:mm:ss}  {1}' -f (Get-Date), $Text) -ForegroundColor $colour
}
function Get-UtcNow { (Get-Date).ToUniversalTime().ToString('o') }

# ------------------------------------------------------------- TLS guard ---
function Test-GitHubTls {
    $bad = @()
    foreach ($h in $cfg.TlsHosts) {
        $issuer = $null; $policy = $null
        try {
            $tcp = [Net.Sockets.TcpClient]::new($h, 443)
            $cb = [Net.Security.RemoteCertificateValidationCallback] { param($s, $c, $ch, $e) $script:tlsErr = $e; $true }
            $ssl = [Net.Security.SslStream]::new($tcp.GetStream(), $false, $cb)
            $ssl.AuthenticateAsClient($h)
            $issuer = $ssl.RemoteCertificate.Issuer
            $policy = $script:tlsErr
            $ssl.Dispose(); $tcp.Dispose()
        } catch { $bad += "$h - connection failed: $($_.Exception.Message)"; continue }
        $trusted = $false
        foreach ($org in $cfg.TrustedIssuerOrgs) { if ($issuer -match ('(^|,\s*)O="?' + [regex]::Escape($org) + '"?(,|$)')) { $trusted = $true } }
        if ("$policy" -ne 'None') { $bad += "$h - certificate not valid ($policy), issuer: $issuer" }
        elseif (-not $trusted)    { $bad += "$h - unexpected issuer: $issuer" }
        else { Write-Run "TLS    $h  ok ($(($issuer -split ',')[0..1] -join ','))" DIM }
    }
    if ($bad) {
        Write-Run 'Refusing to sign in - GitHub traffic does not look end-to-end encrypted:' ERROR
        $bad | ForEach-Object { Write-Run "  $_" ERROR }
        Write-Run '  If the issuer is Fortinet, the upstream firewall has started inspecting GitHub.' ERROR
        Write-Run '  A token sent now would be readable by whoever runs that firewall.' ERROR
        throw 'TLS check failed.'
    }
}

# ------------------------------------------------------------ device flow ---
$script:Tok = $null   # @{ Access; Expires; Refresh }

function Set-Token {
    param($r)
    $script:Tok = @{
        Access  = $r.access_token
        Expires = (Get-Date).AddSeconds([int]($r.PSObject.Properties['expires_in'] ? $r.expires_in : 28800))
        Refresh = ($r.PSObject.Properties['refresh_token'] ? $r.refresh_token : $null)
    }
}

function Request-DeviceToken {
    while ($true) {
        $dc = Invoke-RestMethod -Method Post -Uri 'https://github.com/login/device/code' `
            -Headers @{ Accept = 'application/json' } -Body @{ client_id = $cfg.AppClientId }
        Write-Host ''
        Write-Host '  ------------------------------------------------------------' -ForegroundColor Cyan
        Write-Host "   On the laptop or phone, open   $($dc.verification_uri)" -ForegroundColor White
        Write-Host '   and enter this code:' -ForegroundColor White
        Write-Host ''
        Write-Host "          $($dc.user_code)" -ForegroundColor Yellow
        Write-Host ''
        Write-Host "   (valid for $([int]($dc.expires_in / 60)) minutes - approve access for Lab-Relay-app)" -ForegroundColor DarkGray
        Write-Host '  ------------------------------------------------------------' -ForegroundColor Cyan
        Write-Host ''

        $interval = [int]$dc.interval
        $deadline = (Get-Date).AddSeconds([int]$dc.expires_in)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds $interval
            $t = Invoke-RestMethod -Method Post -Uri 'https://github.com/login/oauth/access_token' `
                -Headers @{ Accept = 'application/json' } -Body @{
                    client_id   = $cfg.AppClientId
                    device_code = $dc.device_code
                    grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                }
            if ($t.PSObject.Properties['access_token'] -and $t.access_token) { Set-Token $t; return }
            switch ($t.error) {
                'authorization_pending' { }
                'slow_down'             { $interval += 5 }
                'expired_token'         { $deadline = Get-Date }
                'access_denied'         { throw 'Sign-in was declined on github.com.' }
                default                 { throw "Device flow error: $($t.error) $($t.error_description)" }
            }
        }
        Write-Run 'The code expired before it was approved - here is a new one.' WARN
    }
}

function Update-Token {
    param([switch]$Force)
    if ($TestToken) { return }
    if (-not $Force -and $script:Tok -and (Get-Date) -lt $script:Tok.Expires.AddMinutes(-10)) { return }
    if ($script:Tok -and $script:Tok.Refresh) {
        try {
            # Device-flow tokens refresh without a client secret.
            $t = Invoke-RestMethod -Method Post -Uri 'https://github.com/login/oauth/access_token' `
                -Headers @{ Accept = 'application/json' } -Body @{
                    client_id = $cfg.AppClientId; grant_type = 'refresh_token'; refresh_token = $script:Tok.Refresh }
            if ($t.PSObject.Properties['access_token'] -and $t.access_token) {
                Set-Token $t
                Write-Run "Token refreshed (valid until $($script:Tok.Expires.ToString('HH:mm')))." DIM
                return
            }
            Write-Run "Token refresh refused: $($t.error)" WARN
        } catch { Write-Run "Token refresh failed: $($_.Exception.Message)" WARN }
    }
    Write-Run 'Signing in again.' WARN
    Request-DeviceToken
}

# -------------------------------------------------------------------- API ---
function Invoke-GH {
    param([string]$Method = 'GET', [Parameter(Mandatory)][string]$Path, $Body, [string]$ETag)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Update-Token
        $tok = if ($TestToken) { $TestToken } else { $script:Tok.Access }
        $h = @{
            Authorization          = "Bearer $tok"
            Accept                 = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
            'User-Agent'           = "Lab-Relay-runner/$RunnerVersion"
        }
        if ($ETag) { $h['If-None-Match'] = $ETag }
        $p = @{ Uri = "$ApiBase$Path"; Method = $Method; Headers = $h; SkipHttpErrorCheck = $true; TimeoutSec = 120 }
        if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 10 -Compress); $p.ContentType = 'application/json' }
        $r = Invoke-WebRequest @p
        $status = [int]$r.StatusCode
        if ($status -eq 401 -and $attempt -eq 1 -and -not $TestToken) { Update-Token -Force; continue }
        if ($status -in 403, 429 -and $r.Headers['Retry-After']) {
            $wait = [int]("$($r.Headers['Retry-After'])")
            Write-Run "GitHub asked us to wait $wait s." WARN; Start-Sleep -Seconds $wait; continue
        }
        if ($status -ge 500 -and $attempt -lt 3) { Start-Sleep -Seconds (5 * $attempt); continue }
        $data = $null
        if ($r.Content -and $status -ne 304) { try { $data = $r.Content | ConvertFrom-Json } catch { } }
        $et = $r.Headers['ETag']; if ($et -is [array]) { $et = $et[0] }
        return [pscustomobject]@{ Status = $status; ETag = "$et"; Data = $data }
    }
}

function Assert-OK {
    param($Response, [string]$What, [int[]]$Ok = @(200, 201))
    if ($Response.Status -notin $Ok) {
        $msg = if ($Response.Data -and $Response.Data.PSObject.Properties['message']) { $Response.Data.message } else { '' }
        throw "$What failed: HTTP $($Response.Status) $msg"
    }
    return $Response.Data
}

function Get-Head {
    (Assert-OK (Invoke-GH -Path "/repos/$Repo/git/ref/heads/$($cfg.Branch)") 'Read branch').object.sha
}

function Get-Tree {
    param([string]$CommitSha)
    $t = Assert-OK (Invoke-GH -Path "/repos/$Repo/git/trees/$($CommitSha)?recursive=1") 'Read tree'
    $map = @{}
    foreach ($e in $t.tree) { if ($e.type -eq 'blob') { $map[$e.path] = $e.sha } }
    return $map
}

function Get-BlobBytes {
    param([string]$Sha)
    $b = Assert-OK (Invoke-GH -Path "/repos/$Repo/git/blobs/$Sha") 'Read blob'
    return [Convert]::FromBase64String(($b.content -replace '\s', ''))
}

function Get-BlobJson {
    param([string]$Sha)
    [Text.Encoding]::UTF8.GetString((Get-BlobBytes $Sha)) | ConvertFrom-Json
}

function New-ChannelCommit {
    <# Files: ordered hashtable of repo path -> byte[]. One atomic commit; retries on a race. #>
    param([Parameter(Mandatory)][Collections.IDictionary]$Files, [Parameter(Mandatory)][string]$Message)
    $entries = foreach ($k in $Files.Keys) {
        $blob = Assert-OK (Invoke-GH -Method POST -Path "/repos/$Repo/git/blobs" -Body @{
                content = [Convert]::ToBase64String([byte[]]$Files[$k]); encoding = 'base64' }) "Upload $k"
        @{ path = $k; mode = '100644'; type = 'blob'; sha = $blob.sha }
    }
    for ($i = 1; $i -le 6; $i++) {
        $head   = Get-Head
        $commit = Assert-OK (Invoke-GH -Path "/repos/$Repo/git/commits/$head") 'Read commit'
        $tree   = Assert-OK (Invoke-GH -Method POST -Path "/repos/$Repo/git/trees" -Body @{
                base_tree = $commit.tree.sha; tree = @($entries) }) 'Create tree'
        $new    = Assert-OK (Invoke-GH -Method POST -Path "/repos/$Repo/git/commits" -Body @{
                message = $Message; tree = $tree.sha; parents = @($head)
                author  = @{ name = "Lab-Relay ($hostName)"; email = "$($cfg.Owner)@users.noreply.github.com"; date = (Get-UtcNow) } }) 'Create commit'
        $upd    = Invoke-GH -Method PATCH -Path "/repos/$Repo/git/refs/heads/$($cfg.Branch)" -Body @{ sha = $new.sha; force = $false }
        if ($upd.Status -eq 200) { return $new.sha }
        if ($upd.Status -in 409, 422) { Start-Sleep -Milliseconds (Get-Random -Minimum 500 -Maximum (1500 * $i)); continue }
        Assert-OK $upd 'Update branch' | Out-Null
    }
    throw 'Could not commit to the channel after 6 attempts (it kept changing underneath).'
}

function ConvertTo-JsonBytes { param($Object) [Text.Encoding]::UTF8.GetBytes(($Object | ConvertTo-Json -Depth 6)) }

# --------------------------------------------------------------- session ---
$script:lastBeat = [datetime]::MinValue
$script:currentJob = $null
function Send-Heartbeat {
    param([string]$State = 'running', [switch]$Force)
    if (-not $Force -and ((Get-Date) - $script:lastBeat).TotalMinutes -lt $HeartbeatMinutes) { return }
    $s = [ordered]@{
        id = $SessionId; host = $hostName; startedUtc = $SessionStart.ToString('o'); lastSeenUtc = (Get-UtcNow)
        state = $State; currentJob = $script:currentJob; runnerVersion = $RunnerVersion
        tokenExpires = if ($script:Tok) { $script:Tok.Expires.ToUniversalTime().ToString('o') } else { $null }
    }
    $files = [ordered]@{ "sessions/$SessionId.json" = (ConvertTo-JsonBytes $s) }
    New-ChannelCommit -Files $files -Message "session $SessionId $State" | Out-Null
    $script:lastBeat = Get-Date
}

function Resolve-Orphans {
    <# Results left 'running' by a session that is no longer here become 'abandoned'. #>
    $tree = Get-Tree (Get-Head)
    $cut = (Get-Date).ToUniversalTime().AddDays(-2).ToString('yyyyMMdd')
    $fix = [ordered]@{}
    foreach ($p in $tree.Keys) {
        if ($p -notmatch '^results/([^/]+)/result\.json$') { continue }
        $id = $Matches[1]
        if ($id -notmatch $JobIdPattern -or $id.Substring(0, 8) -lt $cut) { continue }
        $r = Get-BlobJson $tree[$p]
        if ($r.status -eq 'running' -and $r.session -ne $SessionId) {
            $r.status = 'abandoned'
            $r | Add-Member -NotePropertyName note -NotePropertyValue "Runner session $($r.session) stopped before the job finished." -Force
            $fix[$p] = ConvertTo-JsonBytes $r
            Write-Run "Marked $id abandoned (left running by $($r.session))." WARN
        }
    }
    if ($fix.Count) { New-ChannelCommit -Files $fix -Message 'mark abandoned jobs' | Out-Null }
}

# -------------------------------------------------------------------- jobs ---
$script:handled = [Collections.Generic.HashSet[string]]::new()

function Get-PendingJobs {
    param([hashtable]$Tree)
    $ids = foreach ($p in $Tree.Keys) { if ($p -match '^jobs/([^/]+)/job\.json$') { $Matches[1] } }
    foreach ($id in ($ids | Sort-Object)) {
        if ($id -notmatch $JobIdPattern) { continue }
        if ($script:handled.Contains($id)) { continue }
        if ($Tree.ContainsKey("results/$id/result.json")) { [void]$script:handled.Add($id); continue }
        $id
    }
}

function Limit-Output {
    param([byte[]]$Bytes)
    $max = [int64]$cfg.MaxOutputBytes
    if ($Bytes.Length -le $max) { return @{ Bytes = $Bytes; Truncated = $false } }
    $half = [int]($max / 2)
    $note = [Text.Encoding]::UTF8.GetBytes("`n`n===== Lab-Relay: output truncated - $($Bytes.Length) bytes, showing the first and last $half =====`n`n")
    $out = [byte[]]::new($half * 2 + $note.Length)
    [Array]::Copy($Bytes, 0, $out, 0, $half)
    [Array]::Copy($note, 0, $out, $half, $note.Length)
    [Array]::Copy($Bytes, $Bytes.Length - $half, $out, $half + $note.Length, $half)
    return @{ Bytes = $out; Truncated = $true }
}

function Read-Shared {
    <# Read a file another process may still be writing (the job's own output, a live log). #>
    param([string]$Path)
    # The leading comma returns the byte[] as one object instead of unrolling it into the pipeline.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return , [byte[]]::new(0) }
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
    try { $ms = [IO.MemoryStream]::new(); $fs.CopyTo($ms); return , $ms.ToArray() } finally { $fs.Dispose() }
}

function Get-JobOptions {
    <#  # relay: timeout=5400 progress=60
        # relay: watch=C:\CCES-Automation-Logs\*.log      (one path or wildcard per line; %VARS% expanded) #>
    param([byte[]]$Bytes)
    $o = @{ progress = 0; watch = @() }
    $text = [Text.Encoding]::UTF8.GetString($Bytes)
    foreach ($m in [regex]::Matches($text, '(?im)^\s*#\s*relay:\s*(.+?)\s*$')) {
        $v = $m.Groups[1].Value
        if ($v -match '^watch=(.+)$') {
            $o.watch += [Environment]::ExpandEnvironmentVariables($Matches[1].Trim().Trim('"', "'"))
            continue
        }
        foreach ($t in $v -split '\s+') {
            if ($t -match '^progress=(\d+)$') {
                $n = [int]$Matches[1]
                $o.progress = if ($n -eq 0) { 0 } else { [math]::Max(30, [math]::Min(600, $n)) }
            }
        }
    }
    return $o
}

function Get-JobSnapshot {
    <# Everything a job has produced so far: output.txt, LABRELAY_OUT files, watched files. #>
    param([string]$JobId, [string]$Stdout, [string]$Stderr, [string]$Out, [string[]]$Watch, [string]$Tail)
    $text = [IO.MemoryStream]::new()
    $b = Read-Shared $Stdout; $text.Write($b, 0, $b.Length)
    $e = Read-Shared $Stderr
    if ($e.Length) {
        $h = [Text.Encoding]::UTF8.GetBytes("`n===== stderr =====`n"); $text.Write($h, 0, $h.Length); $text.Write($e, 0, $e.Length)
    }
    if ($Tail) { $h = [Text.Encoding]::UTF8.GetBytes($Tail); $text.Write($h, 0, $h.Length) }
    $lim = Limit-Output $text.ToArray()

    $files = [ordered]@{ "results/$JobId/output.txt" = $lim.Bytes }
    $returned = @(); $skipped = @()
    $cands = @(Get-ChildItem -LiteralPath $Out -Force -ErrorAction SilentlyContinue | ForEach-Object { @{ F = $_; Watched = $false } })
    foreach ($w in $Watch) {
        $cands += @(Get-ChildItem -Path $w -File -Force -ErrorAction SilentlyContinue | ForEach-Object { @{ F = $_; Watched = $true } })
    }
    foreach ($c in $cands) {
        $f = $c.F; $why = $null; $key = "results/$JobId/$($f.Name)"
        if ($f.PSIsContainer) { $why = 'folder' }
        elseif ($f.Name -notmatch $FileNameRegex -or $f.Name -in 'output.txt', 'result.json') { $why = 'name' }
        elseif ($files.Contains($key)) { $why = 'duplicate name' }
        elseif ($f.Extension.ToLowerInvariant() -notin $cfg.ResultExtensions) { $why = "extension $($f.Extension)" }
        elseif (-not $c.Watched -and $f.Length -gt $cfg.MaxFileBytes) { $why = "over $([int]($cfg.MaxFileBytes / 1MB)) MB" }
        if ($why) { if ($skipped -notcontains "$($f.Name) ($why)") { $skipped += "$($f.Name) ($why)" }; continue }
        try { $bytes = Read-Shared $f.FullName } catch { $skipped += "$($f.Name) (unreadable)"; continue }
        if ($c.Watched) { $bytes = (Limit-Output $bytes).Bytes }      # live logs: head + tail if huge
        $files[$key] = $bytes
        $returned += $f.Name
    }
    return @{ Files = $files; Returned = $returned; Skipped = $skipped; OutputBytes = $text.Length; Truncated = $lim.Truncated }
}

function Get-SnapshotHash {
    param([Collections.IDictionary]$Files)
    $sha = [Security.Cryptography.IncrementalHash]::CreateHash('SHA256')
    foreach ($k in $Files.Keys) { $sha.AppendData([Text.Encoding]::UTF8.GetBytes($k)); $sha.AppendData([byte[]]$Files[$k]) }
    return [Convert]::ToHexString($sha.GetHashAndReset())
}

function Invoke-Job {
    param([string]$JobId, [hashtable]$Tree)
    [void]$script:handled.Add($JobId)
    $job = Get-BlobJson $Tree["jobs/$JobId/job.json"]
    $base = [ordered]@{ id = $JobId; session = $SessionId; host = $hostName; runnerVersion = $RunnerVersion; script = $job.script }

    # Stale-job rule: do not run old unclaimed work in a brand-new lab.
    # PowerShell 7.4 ConvertFrom-Json already turns ISO strings into DateTime (Utc/Local kind).
    $queued = if ($job.queuedUtc -is [datetime]) { $job.queuedUtc.ToUniversalTime() }
              else { [datetime]::Parse("$($job.queuedUtc)", $null, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }
    if ($queued -lt $SessionStart.AddMinutes(-$cfg.StaleJobMinutes)) {
        $r = $base + [ordered]@{ status = 'expired'; finishedUtc = (Get-UtcNow)
            note = "Queued $($queued.ToString('u')), more than $($cfg.StaleJobMinutes) min before this lab session started - not run." }
        New-ChannelCommit -Files ([ordered]@{ "results/$JobId/result.json" = (ConvertTo-JsonBytes $r) }) -Message "expired $JobId" | Out-Null
        Write-Run "Expired $JobId (queued $([int]($SessionStart - $queued).TotalMinutes) min before this session)." WARN
        return
    }

    $scriptPath = "jobs/$JobId/$($job.script)"
    $bytes = Get-BlobBytes $Tree[$scriptPath]
    $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    if ($sha -ne $job.sha256 -or $job.script -notmatch '^[A-Za-z0-9._-]+\.ps1$') {
        $r = $base + [ordered]@{ status = 'rejected'; finishedUtc = (Get-UtcNow); note = 'Script failed the integrity or name check - not run.' }
        New-ChannelCommit -Files ([ordered]@{ "results/$JobId/result.json" = (ConvertTo-JsonBytes $r) }) -Message "rejected $JobId" | Out-Null
        Write-Run "Rejected $JobId - integrity check failed." ERROR
        return
    }

    $timeout = [math]::Min([int]$job.timeout, [int]$cfg.MaxTimeoutSeconds)
    $opt = Get-JobOptions $bytes
    $started = (Get-Date).ToUniversalTime()
    $run = $base + [ordered]@{ status = 'running'; startedUtc = $started.ToString('o'); timeout = $timeout
                               progress = $opt.progress; watch = @($opt.watch) }
    New-ChannelCommit -Files ([ordered]@{ "results/$JobId/result.json" = (ConvertTo-JsonBytes $run) }) -Message "running $JobId" | Out-Null
    $script:currentJob = $JobId
    $live = if ($opt.progress) { ", live every $($opt.progress)s" } else { '' }
    Write-Run "Run    $JobId  (timeout ${timeout}s$live)" INFO

    # --- stage and launch --------------------------------------------------------
    $dir = Join-Path $WorkRoot "jobs/$JobId"
    $out = Join-Path $dir 'out'
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    $scriptFile = Join-Path $dir $job.script
    [IO.File]::WriteAllBytes($scriptFile, $bytes)
    $wrapper = Join-Path $dir '_run.ps1'
    $q = { param($s) "'" + ($s -replace "'", "''") + "'" }
    @"
`$ErrorActionPreference = 'Continue'
`$PSStyle.OutputRendering = 'PlainText'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new(`$false)
Import-Module $(& $q $Helpers) -DisableNameChecking
Set-Location -LiteralPath $(& $q $dir)
`$global:LASTEXITCODE = 0
`$failed = `$false
try {
    & $(& $q $scriptFile) *>&1 | Out-String -Stream -Width 300
} catch {
    "*** Terminating error: `$(`$_.Exception.Message)"
    "`$(`$_.ScriptStackTrace)"
    `$failed = `$true
}
if (`$failed) { exit 1 }
exit `$global:LASTEXITCODE
"@ | Set-Content -LiteralPath $wrapper -Encoding utf8NoBOM

    $stdout = Join-Path $dir '_stdout.txt'; $stderr = Join-Path $dir '_stderr.txt'
    $env:LABRELAY_OUT = $out; $env:LABRELAY_JOB = $JobId; $env:LABRELAY_SESSION = $SessionId
    $pwsh = (Get-Process -Id $PID).Path
    $proc = Start-Process -FilePath $pwsh -PassThru -NoNewWindow -WorkingDirectory $dir `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $wrapper) `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $null = $proc.Handle   # keep the handle so ExitCode is readable later

    $status = 'done'
    $deadline = (Get-Date).AddSeconds($timeout)
    $nextProgress = if ($opt.progress) { (Get-Date).AddSeconds($opt.progress) } else { [datetime]::MaxValue }
    $lastHash = $null; $progressCount = 0
    while ($true) {
        $wake = if ($nextProgress -lt $deadline) { $nextProgress } else { $deadline }
        $ms = [int][math]::Max(250, [math]::Min(15000, ($wake - (Get-Date)).TotalMilliseconds))
        if ($proc.WaitForExit($ms)) { break }
        if ((Get-Date) -ge $deadline) {
            try { $proc.Kill($true) } catch { }
            $proc.WaitForExit(10000) | Out-Null
            $status = 'timeout'
            break
        }
        if ((Get-Date) -ge $nextProgress) {
            # Live progress: output so far + watched logs, only when something changed.
            try {
                $snap = Get-JobSnapshot -JobId $JobId -Stdout $stdout -Stderr $stderr -Out $out -Watch $opt.watch
                $hash = Get-SnapshotHash $snap.Files
                if ($hash -ne $lastHash) {
                    $progressCount++
                    $pr = $run + [ordered]@{ progressUtc = (Get-UtcNow); progressCount = $progressCount
                        elapsedSeconds = [int]((Get-Date).ToUniversalTime() - $started).TotalSeconds
                        outputBytes = $snap.OutputBytes; files = $snap.Returned; skipped = $snap.Skipped }
                    $snap.Files["results/$JobId/result.json"] = ConvertTo-JsonBytes $pr
                    New-ChannelCommit -Files $snap.Files -Message "progress $JobId #$progressCount" | Out-Null
                    $lastHash = $hash
                    Write-Run ("Live   {0}  update {1}  ({2}s, {3} KB)" -f $JobId, $progressCount, $pr.elapsedSeconds, [int]($snap.OutputBytes / 1KB)) DIM
                }
            } catch { Write-Run "Progress upload failed: $($_.Exception.Message)" DIM }
            $nextProgress = (Get-Date).AddSeconds($opt.progress)
        }
        try { Send-Heartbeat } catch { Write-Run "Heartbeat failed: $($_.Exception.Message)" DIM }
    }
    $finished = (Get-Date).ToUniversalTime()
    $exit = if ($status -eq 'timeout') { $null } else { $proc.ExitCode }
    if ($status -eq 'done' -and $exit -ne 0) { $status = 'failed' }
    Remove-Item Env:LABRELAY_OUT, Env:LABRELAY_JOB, Env:LABRELAY_SESSION -ErrorAction SilentlyContinue

    # --- collect -----------------------------------------------------------------
    $tail = if ($status -eq 'timeout') { "`n===== Lab-Relay: killed after $timeout s (timeout) =====`n" } else { $null }
    $snap = Get-JobSnapshot -JobId $JobId -Stdout $stdout -Stderr $stderr -Out $out -Watch $opt.watch -Tail $tail
    $files = $snap.Files; $returned = $snap.Returned; $skipped = $snap.Skipped
    $result = $base + [ordered]@{
        status = $status; exitCode = $exit
        startedUtc = $started.ToString('o'); finishedUtc = $finished.ToString('o')
        durationSeconds = [math]::Round(($finished - $started).TotalSeconds, 1); timeout = $timeout
        outputBytes = $snap.OutputBytes; outputTruncated = $snap.Truncated
        files = $returned; skipped = $skipped; progressUpdates = $progressCount
    }
    $files["results/$JobId/result.json"] = ConvertTo-JsonBytes $result   # last entry; same commit
    New-ChannelCommit -Files $files -Message "$status $JobId" | Out-Null
    $script:currentJob = $null

    $lvl = if ($status -eq 'done') { 'OK' } else { 'WARN' }
    $extra = @("$($result.durationSeconds)s"); if ($null -ne $exit) { $extra += "exit $exit" }
    if ($returned) { $extra += "$($returned.Count) file(s)" }; if ($skipped) { $extra += "$($skipped.Count) skipped" }
    Write-Run ("Done   {0}  {1}  {2}" -f $JobId, $status.ToUpperInvariant(), ($extra -join ', ')) $lvl
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

# -------------------------------------------------------------------- main ---
if ($MyInvocation.InvocationName -eq '.') { return }   # dot-sourced for testing

Write-Host ''
Write-Host "  Lab-Relay runner $RunnerVersion" -ForegroundColor Cyan
Write-Host "  Session: $SessionId" -ForegroundColor DarkGray
Write-Host "  Channel: $Repo" -ForegroundColor DarkGray
Write-Host ''

if (-not $TestApiBase) {
    Test-GitHubTls
    Request-DeviceToken
    Write-Run "Signed in. Token valid until $($script:Tok.Expires.ToString('HH:mm')) and refreshed automatically." OK
}
$probe = Invoke-GH -Path "/repos/$Repo"
if ($probe.Status -ne 200) {
    throw "Cannot see $Repo (HTTP $($probe.Status)). Is Lab-Relay-app installed on that repository?"
}
New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null

$state = 'stopped'
try {
    Send-Heartbeat -Force
    Resolve-Orphans
    Write-Run "Ready - polling every ${PollSeconds}s. Ctrl+C to stop." OK

    $etag = $null; $failures = 0
    while ($true) {
        try {
            Update-Token
            $ref = Invoke-GH -Path "/repos/$Repo/git/ref/heads/$($cfg.Branch)" -ETag $etag
            if ($ref.Status -eq 200) {
                $etag = $ref.ETag
                $tree = Get-Tree $ref.Data.object.sha
                $pending = @(Get-PendingJobs $tree)
                foreach ($id in $pending) {
                    try { Invoke-Job -JobId $id -Tree $tree }
                    catch {
                        Write-Run "Job $id failed in the runner: $($_.Exception.Message)" ERROR
                        try {
                            $r = [ordered]@{ id = $id; session = $SessionId; status = 'error'; finishedUtc = (Get-UtcNow); note = "Runner error: $($_.Exception.Message)" }
                            New-ChannelCommit -Files ([ordered]@{ "results/$id/result.json" = (ConvertTo-JsonBytes $r) }) -Message "error $id" | Out-Null
                        } catch { }
                        $script:currentJob = $null
                    }
                    $tree = Get-Tree (Get-Head)   # our own commits moved the head
                }
                if ($pending) { $etag = $null }      # our commits moved the head - look once more
            } elseif ($ref.Status -ne 304) {
                Assert-OK $ref 'Poll' | Out-Null
            }
            Send-Heartbeat
            $failures = 0
        } catch {
            $failures++
            Write-Run "Poll failed: $($_.Exception.Message)" ERROR
            Start-Sleep -Seconds ([math]::Min(300, 15 * $failures))
            continue
        }
        Start-Sleep -Seconds $PollSeconds
    }
} finally {
    try { Send-Heartbeat -State $state -Force; Write-Run 'Stopped. Session marked stopped on the channel.' DIM } catch { }
    $script:Tok = $null
}
