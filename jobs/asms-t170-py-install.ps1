# relay: timeout=6000 progress=60
# relay: watch=C:\CCES-Automation-Logs\CPUSE_*.log
# Step 2 of 2: install Jumbo Take 170 on A-SMS through the interactive Python driver.
$u = 'https://raw.githubusercontent.com/Don-Paterson/CCES-R8120-Automation/main/bootstrap.ps1'
& ([scriptblock]::Create((irm $u))) -Action DownloadOnly
& (Join-Path ([Environment]::GetFolderPath('Desktop')) 'CCES-Automation\scripts\Invoke-CPUSEInstall.ps1') -Target A-SMS -ExpectedTake 170 -TimeoutMin 90
