# relay: timeout=300
# READ-ONLY diagnostic on A-SMS: how CPUSE lists the downloaded Take 170. Installs nothing.
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


$null = cmd.exe /c "echo y | `"$plink`" -ssh -pw `"$Pass`" $User@$HostIp exit" 2>&1
foreach ($c in 'show installer packages', 'show installer packages downloaded', 'show installer packages imported', 'show installer packages available-for-download') {
    "=================== $c"; Invoke-Exec $c
}
# Tab completion is what shows the numbered table at the keyboard. Ctrl+U then clears the
# half-typed line so nothing is executed.
"=================== interactive: installer install <TAB>"
Invoke-Pty @("installer install `t`t", [string][char]21) 60
"=================== interactive: installer install ?"
Invoke-Pty @('installer install ?', [string][char]21) 60
