<#
.SYNOPSIS
    Lab-Relay bootstrap. Run this on A-GUI at the start of every lab session.

.DESCRIPTION
    Downloads the Lab-Relay code to the desktop, clears mark-of-the-web, and starts the
    runner, which checks TLS, asks you to approve a device code on github.com, and then
    runs jobs sent from the laptop.

        irm https://raw.githubusercontent.com/Don-Paterson/Lab-Relay/main/bootstrap.ps1 | iex

    With parameters (scriptblock form):
        & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Don-Paterson/Lab-Relay/main/bootstrap.ps1))) -Branch dev

.PARAMETER Branch
    Branch of the code repo to use. Default: main.

.PARAMETER InstallPath
    Where to put the code. Default: Desktop\Lab-Relay.

.PARAMETER DownloadOnly
    Fetch the code but do not start the runner.
#>
[CmdletBinding()]
param(
    [string]$Branch = 'main',
    [string]$InstallPath,
    [switch]$DownloadOnly
)

$ErrorActionPreference = 'Stop'
$repo = 'Don-Paterson/Lab-Relay'

Write-Host ''
Write-Host '  Lab-Relay bootstrap' -ForegroundColor Cyan
Write-Host '  laptop <-> lab file relay - run on A-GUI' -ForegroundColor DarkGray
Write-Host ''

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host '  PowerShell 7 is required. Start "pwsh" and run the command again.' -ForegroundColor Red
    return
}
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force } catch { }

if (-not $InstallPath) { $InstallPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Lab-Relay' }
$zip = Join-Path ([IO.Path]::GetTempPath()) "lab-relay-$Branch.zip"
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("lab-relay-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

Write-Host "  Downloading $repo ($Branch)..." -ForegroundColor Cyan
Invoke-WebRequest -Uri "https://github.com/$repo/archive/refs/heads/$Branch.zip" -OutFile $zip -UseBasicParsing
Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
$src = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
if (-not (Test-Path -LiteralPath $InstallPath)) { New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null }
Copy-Item -Path (Join-Path $src.FullName '*') -Destination $InstallPath -Recurse -Force
Get-ChildItem -LiteralPath $InstallPath -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "    Ready at $InstallPath" -ForegroundColor Gray

if ($DownloadOnly) { return }
& (Join-Path $InstallPath 'lab/Start-LabRunner.ps1') -Root $InstallPath
