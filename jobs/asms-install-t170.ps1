# relay: timeout=5400 progress=60
# Install R81.20 Jumbo HFA Take 170 on A-SMS (10.1.1.101) - already downloaded by CPUSE.
# Drives Clish the way it is done by hand: the numbered package list only exists in an
# interactive session, and a cloud-downloaded package's display name has spaces, which
# 'installer install' cannot take non-interactively.

# Credentials are NOT in this file. They are read on A-GUI from the CCES lab settings,
# where the lab build already keeps them (Desktop\CCES-Automation, or the public repo copy).
$HostIp = '10.1.1.101'
$settings = Join-Path ([Environment]::GetFolderPath('Desktop')) 'CCES-Automation\config\lab-settings.psd1'
if (-not (Test-Path -LiteralPath $settings)) {
    $settings = Join-Path $env:TEMP 'cces-lab-settings.psd1'
    Invoke-WebRequest 'https://raw.githubusercontent.com/Don-Paterson/CCES-R8120-Automation/main/config/lab-settings.psd1' -OutFile $settings -UseBasicParsing
}
$lab = Import-PowerShellDataFile -LiteralPath $settings
$User = $lab.GaiaUser; $Pass = $lab.GaiaPassword
$Want   = 'T170'                                  # matches ..._Bundle_T170_FULL.tgz
$plink  = @((Get-Command plink.exe -ErrorAction SilentlyContinue).Source, 'C:\Program Files\PuTTY\plink.exe',
            'C:\Program Files (x86)\PuTTY\plink.exe') | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $plink) { throw 'plink.exe not found on A-GUI.' }
function Log($t) { "{0:HH:mm:ss}  {1}" -f (Get-Date), $t }

function Invoke-Exec([string]$Cmd, [int]$TimeoutSec = 120) {
    # One command over the exec channel; the admin shell is Clish, so Clish commands run directly.
    $o = & $plink -ssh -batch -pw $Pass "$User@$HostIp" $Cmd 2>&1 | Out-String
    return ($o -replace "`r", '').Trim()
}

function Invoke-Pty([string[]]$Lines, [int]$TimeoutSec = 180) {
    # An interactive Clish session (pty) fed line by line - what a person typing sees.
    $in = New-TemporaryFile; $out = New-TemporaryFile; $err = New-TemporaryFile
    try {
        Set-Content -LiteralPath $in -Value (($Lines + 'exit') -join "`n") -Encoding ASCII
        $p = Start-Process -FilePath $plink -ArgumentList @('-ssh', '-t', '-batch', '-pw', $Pass, "$User@$HostIp") `
             -RedirectStandardInput $in -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -PassThru
        if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch { }; Start-Sleep 2 }
        $t = (Get-Content -LiteralPath $out -Raw) + (Get-Content -LiteralPath $err -Raw)
        return (($t -replace "`r", '') -replace "\x1b\[[0-9;?]*[A-Za-z]", '')
    } finally { Remove-Item $in, $out, $err -Force -ErrorAction SilentlyContinue }
}

function Get-Installed { Invoke-Exec 'show installer packages installed' }

# --- 0. host key + reachability ------------------------------------------------
$null = cmd.exe /c "echo y | `"$plink`" -ssh -pw `"$Pass`" $User@$HostIp exit" 2>&1
Log "Connected to A-SMS $HostIp with $plink"
"--- show version all"; Invoke-Exec 'show version all'
$before = Get-Installed
"--- installed packages before"; $before
if ($before -match '(?i)Take\s*170|T170') { Log 'Take 170 is already installed - nothing to do.'; exit 0 }

# --- 1. numbered list: Tab completion shows it (Enter only says "Incomplete command") ---
Log 'Reading the numbered install list (installer install <TAB>)...'
$list = Invoke-Pty @("installer install `t`t", [string][char]21) 90
"--- installer install <TAB>"; $list
$num = $null
foreach ($l in $list -split "`n") { if ($l -match '^\s*(\d+)\s+(.*Take\s*170\b.*?)\s{2,}') { $num = $Matches[1]; $pkg = $Matches[2].Trim(); break } }
if (-not $num) { Log 'No numbered entry for Take 170 in the install list - stopping, nothing installed.'; exit 3 }
Log "Take 170 is entry $num ($pkg)."

# --- 1b. evidence for the CCES fix: does the FILE NAME work as an identifier? (read-only)
$file = 'Check_Point_R81_20_jumbo_hf_main_Bundle_T170_FULL.tgz'
Log "Read-only check: installer verify $file"
"--- installer verify <file name>"; Invoke-Pty @("installer verify $file") 240

# --- 2. install ------------------------------------------------------------------
Log "Starting: lock database override; installer install $num not-interactive"
$start = Invoke-Pty @('lock database override', "installer install $num not-interactive", 'y') 180
"--- install session transcript"; $start
if ($start -match '(?i)Initiating install of (.+?)\.\.\.') { Log "CPUSE: installing $($Matches[1])" }
if ($start -notmatch '(?i)T170|Take 170') { Log 'WARNING: the transcript does not name Take 170 - check it above.' }

# --- 3. watch it through the reboot ---------------------------------------------
$t0 = Get-Date; $deadline = $t0.AddMinutes(80); $down = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 60
    $m = [int]((Get-Date) - $t0).TotalMinutes
    $up = Test-NetConnection $HostIp -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue
    if (-not $up) { if (-not $down) { Log "${m}m  SSH down - A-SMS is rebooting." }; $down = $true; continue }
    if ($down) { Log "${m}m  SSH is back after the reboot."; $down = $false
                 $null = cmd.exe /c "echo y | `"$plink`" -ssh -pw `"$Pass`" $User@$HostIp exit" 2>&1 }
    $inst = Get-Installed
    if ($inst -match '(?i)Take\s*170|T170') {
        Log "${m}m  Take 170 is INSTALLED."
        "--- installed packages after"; $inst
        "--- total time: $m minutes from starting the install"
        exit 0
    }
    $st = Invoke-Exec 'show installer status all'
    $last = ($st -split "`n" | Where-Object { $_ -match '170|Jumbo|Install|%' } | Select-Object -Last 2) -join ' | '
    Log "${m}m  installing... $last"
}
Log 'Gave up after 80 minutes without seeing Take 170 installed.'
"--- installer status"; Invoke-Exec 'show installer status all'
exit 4
