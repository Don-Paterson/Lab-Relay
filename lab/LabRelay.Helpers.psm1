<#
    Helpers available to every script the Lab-Relay runner executes.
    Files saved with these land in $env:LABRELAY_OUT and are returned to the laptop.
#>

function Get-RelayOutDir {
    if (-not $env:LABRELAY_OUT) { throw 'LABRELAY_OUT is not set - this helper only works inside a Lab-Relay job.' }
    if (-not (Test-Path -LiteralPath $env:LABRELAY_OUT)) { New-Item -ItemType Directory -Path $env:LABRELAY_OUT -Force | Out-Null }
    return $env:LABRELAY_OUT
}

function ConvertTo-RelayFileName {
    param([string]$Name, [string]$Extension)
    $n = ($Name -replace '[^A-Za-z0-9._-]', '-') -replace '-{2,}', '-'
    $n = $n.Trim('-', '.')
    if (-not $n) { $n = 'file' }
    if ($n.Length -gt 80) { $n = $n.Substring(0, 80) }
    if ($Extension -and -not $n.EndsWith($Extension, [StringComparison]::OrdinalIgnoreCase)) { $n += $Extension }
    return $n
}

$script:dpiSet = $false
function Save-RelayScreenshot {
    <#
    .SYNOPSIS  Capture the lab desktop as a PNG and return it to the laptop.
    .PARAMETER Name         File name (".png" is added). Default: screen-HHmmss.
    .PARAMETER PrimaryOnly  Only the primary monitor (default: the whole virtual screen).
    .EXAMPLE   Save-RelayScreenshot -Name 'smartconsole-policy'
    #>
    [CmdletBinding()]
    param([string]$Name = ('screen-{0:HHmmss}' -f (Get-Date)), [switch]$PrimaryOnly)

    if (-not $IsWindows) { throw 'Save-RelayScreenshot needs a Windows desktop session.' }
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    if (-not $script:dpiSet) {
        # Without this, a scaled display is captured at the wrong size.
        try {
            Add-Type -Namespace LabRelay -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -ErrorAction Stop
            [void][LabRelay.Dpi]::SetProcessDPIAware()
        } catch { }
        $script:dpiSet = $true
    }
    $b = if ($PrimaryOnly) { [System.Windows.Forms.Screen]::PrimaryScreen.Bounds } else { [System.Windows.Forms.SystemInformation]::VirtualScreen }
    $bmp = [System.Drawing.Bitmap]::new($b.Width, $b.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $b.Size)
        $path = Join-Path (Get-RelayOutDir) (ConvertTo-RelayFileName $Name '.png')
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $g.Dispose(); $bmp.Dispose() }
    Write-Host "Screenshot saved: $(Split-Path -Leaf $path) ($($b.Width)x$($b.Height))"
    return $path
}

function Save-RelayFile {
    <#
    .SYNOPSIS  Return a file from the lab to the laptop (txt, log, json, csv, xml, png, jpg).
    .EXAMPLE   Save-RelayFile -Path C:\CCES-Automation-Logs\ftw.log
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string]$Name)
    $src = Get-Item -LiteralPath $Path -ErrorAction Stop
    if (-not $Name) { $Name = $src.Name }
    $dest = Join-Path (Get-RelayOutDir) (ConvertTo-RelayFileName ([IO.Path]::GetFileNameWithoutExtension($Name)) ([IO.Path]::GetExtension($Name)))
    Copy-Item -LiteralPath $src.FullName -Destination $dest -Force
    Write-Host "File saved for return: $(Split-Path -Leaf $dest)"
    return $dest
}

function Save-RelayText {
    <#
    .SYNOPSIS  Write text straight to a returned file, e.g. a report separate from output.txt.
    .EXAMPLE   Get-Service | Out-String | Save-RelayText -Name services.txt
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(ValueFromPipeline)][string]$InputObject)
    begin { $sb = [Text.StringBuilder]::new() }
    process { [void]$sb.AppendLine($InputObject) }
    end {
        $ext = [IO.Path]::GetExtension($Name); if (-not $ext) { $ext = '.txt' }
        $dest = Join-Path (Get-RelayOutDir) (ConvertTo-RelayFileName ([IO.Path]::GetFileNameWithoutExtension($Name)) $ext)
        [IO.File]::WriteAllText($dest, $sb.ToString(), [Text.UTF8Encoding]::new($false))
        return $dest
    }
}

Export-ModuleMember -Function Save-RelayScreenshot, Save-RelayFile, Save-RelayText
