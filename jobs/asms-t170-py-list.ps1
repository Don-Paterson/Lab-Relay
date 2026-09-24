# relay: timeout=900 progress=30
# relay: watch=C:\CCES-Automation-Logs\CPUSE_*.log
# Step 1 of 2: fetch CCES main, install Python/paramiko if needed, show the numbered list. Installs nothing.
$u = 'https://raw.githubusercontent.com/Don-Paterson/CCES-R8120-Automation/main/bootstrap.ps1'
& ([scriptblock]::Create((irm $u))) -Action DownloadOnly
& (Join-Path ([Environment]::GetFolderPath('Desktop')) 'CCES-Automation\scripts\Invoke-CPUSEInstall.ps1') -Target A-SMS -ExpectedTake 170 -ListOnly
