# relay: timeout=120
# First end-to-end check of Lab-Relay from A-GUI: identity, network, a screenshot.

"=== Lab-Relay hello from $env:COMPUTERNAME at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')"
"User      : $env:USERDOMAIN\$env:USERNAME"
"PowerShell: $($PSVersionTable.PSVersion)"
"OS        : $([Environment]::OSVersion.VersionString)"
"Job       : $env:LABRELAY_JOB"
""
"=== IPv4 addresses"
Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -ne '127.0.0.1' |
    Select-Object InterfaceAlias, IPAddress, PrefixLength | Format-Table -AutoSize
"=== Reachability of lab hosts (TCP 22 / 443)"
foreach ($h in '10.1.1.101', '10.1.1.102', '10.1.1.103') {
    foreach ($p in 22, 443) {
        $ok = (Test-NetConnection -ComputerName $h -Port $p -WarningAction SilentlyContinue -InformationLevel Quiet)
        "{0,-12} {1,-4} {2}" -f $h, $p, $(if ($ok) { 'open' } else { '-' })
    }
}
""
Save-RelayScreenshot -Name 'a-gui-desktop' | Out-Null
Get-ComputerInfo -Property CsName, OsName, OsTotalVisibleMemorySize, CsNumberOfLogicalProcessors |
    Format-List | Out-String | Save-RelayText -Name 'computer-info.txt' | Out-Null
"=== done"
