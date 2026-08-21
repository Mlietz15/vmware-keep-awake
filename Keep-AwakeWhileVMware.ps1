<#
.SYNOPSIS
    Keeps the laptop (system + display) awake while a VMware VM is powered on.

.DESCRIPTION
    Watches for vmware-vmx.exe - one instance exists per powered-on VM - and
    asserts a Windows power request via SetThreadExecutionState for as long as
    at least one VM is running. When the last VM is shut down the request is
    released and normal power management takes over again.

    Only a running VM counts. An open Workstation Pro window without a powered-on
    VM does not keep the machine awake, and neither do the permanently running
    services (vmware-authd, vmware-tray, vmware-usbarbitrator64).

    Indicator: a tray icon shows the current state.
        grey dot   - script running, no VM powered on (sleep allowed)
        green dot  - VM running, sleep and display-off suppressed
    Hover over the icon for details, double-click for a status balloon, or use
    the right-click menu to exit.

    Closing the lid still sleeps the machine - that is a hardware policy that no
    power request can override.

.EXAMPLE
    .\Keep-AwakeWhileVMware.ps1

.NOTES
    Log:    %LOCALAPPDATA%\vmware-keepawake.log
    Verify: powercfg /requests   (needs an elevated prompt)
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProcessName     = 'vmware-vmx'
$IntervalSeconds = 15
$LogPath         = Join-Path $env:LOCALAPPDATA 'vmware-keepawake.log'
$MaxLogBytes     = 1MB

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Win32 power request API -------------------------------------------------
if (-not ('Native.Power' -as [type])) {
    Add-Type -Namespace Native -Name Power -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@
}

if (-not ('Native.Icons' -as [type])) {
    Add-Type -Namespace Native -Name Icons -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true)]
public static extern bool DestroyIcon(IntPtr hIcon);
'@
}

$ES_CONTINUOUS       = [uint32]'0x80000000'
$ES_SYSTEM_REQUIRED  = [uint32]'0x00000001'
$ES_DISPLAY_REQUIRED = [uint32]'0x00000002'

function Write-Log {
    param([string] $Message)

    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    try {
        $existing = Get-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue
        if ($existing -and $existing.Length -gt $MaxLogBytes) {
            Move-Item -LiteralPath $LogPath -Destination "$LogPath.old" -Force
        }
        Add-Content -Path $LogPath -Value $line -Encoding utf8
    }
    catch {
        Write-Warning "Could not write to log file '$LogPath': $($_.Exception.Message)"
    }
}

function Set-KeepAwake {
    param([bool] $Enabled)

    $flags = if ($Enabled) { $ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED -bor $ES_DISPLAY_REQUIRED }
             else          { $ES_CONTINUOUS }   # ES_CONTINUOUS alone clears the request

    if ([Native.Power]::SetThreadExecutionState($flags) -eq 0) {
        throw "SetThreadExecutionState failed (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
    }
}

function New-DotIcon {
    param([System.Drawing.Color] $Color)

    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)

        $brush = New-Object System.Drawing.SolidBrush -ArgumentList $Color
        $pen   = New-Object System.Drawing.Pen -ArgumentList @([System.Drawing.Color]::FromArgb(160, 0, 0, 0), 1)
        try {
            $g.FillEllipse($brush, 2, 2, 12, 12)
            $g.DrawEllipse($pen,   2, 2, 12, 12)
        }
        finally { $brush.Dispose(); $pen.Dispose() }
    }
    finally { $g.Dispose() }

    # Clone so the icon survives destroying the temporary GDI handle.
    $handle = $bmp.GetHicon()
    $icon   = ([System.Drawing.Icon]::FromHandle($handle)).Clone()
    [Native.Icons]::DestroyIcon($handle) | Out-Null
    $bmp.Dispose()
    return $icon
}

# --- Tray indicator ----------------------------------------------------------
$iconIdle  = New-DotIcon ([System.Drawing.Color]::FromArgb(150, 150, 150))
$iconAwake = New-DotIcon ([System.Drawing.Color]::FromArgb(40, 190, 80))

$script:Running = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$exitItem = $menu.Items.Add('Exit')
$exitItem.add_Click({ $script:Running = $false })

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon             = $iconIdle
$tray.Text             = 'VMware keep-awake: no VM running'
$tray.ContextMenuStrip = $menu
$tray.Visible          = $true

$tray.add_DoubleClick({
    $tray.ShowBalloonTip(3000, 'VMware keep-awake', $tray.Text,
                         [System.Windows.Forms.ToolTipIcon]::Info)
})

function Update-Tray {
    param([bool] $Awake, [int] $VmCount)

    if ($Awake) {
        $tray.Icon = $iconAwake
        $tray.Text = if ($VmCount -eq 1) { 'VMware keep-awake: 1 VM running - sleep suppressed' }
                     else                { "VMware keep-awake: $VmCount VMs running - sleep suppressed" }
    }
    else {
        $tray.Icon = $iconIdle
        $tray.Text = 'VMware keep-awake: no VM running'
    }
}

function Start-Wait {
    # Sleep in small slices so the tray menu stays responsive.
    param([int] $Seconds)

    $deadline = (Get-Date).AddSeconds($Seconds)
    while ($script:Running -and (Get-Date) -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 150
    }
}

# --- Main loop ---------------------------------------------------------------
Write-Log "Started - watching $ProcessName.exe every ${IntervalSeconds}s (keeps system + display awake)."

$awake = $false

try {
    while ($script:Running) {
        $vms = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
        $shouldBeAwake = $vms.Count -gt 0

        if ($shouldBeAwake -ne $awake) {
            Set-KeepAwake -Enabled $shouldBeAwake
            $awake = $shouldBeAwake
            Update-Tray -Awake $awake -VmCount $vms.Count

            if ($awake) {
                Write-Log "$($vms.Count) VM(s) running - sleep and display-off suppressed."
                $tray.ShowBalloonTip(4000, 'VMware keep-awake', 'VM running - laptop stays awake.',
                                     [System.Windows.Forms.ToolTipIcon]::Info)
            }
            else {
                Write-Log 'No VM running - sleep allowed again.'
                $tray.ShowBalloonTip(4000, 'VMware keep-awake', 'No VM running - sleep allowed again.',
                                     [System.Windows.Forms.ToolTipIcon]::Info)
            }
        }
        elseif ($awake) {
            # Re-assert periodically so the request survives e.g. a power-policy change,
            # and keep the VM count in the tooltip current.
            Set-KeepAwake -Enabled $true
            Update-Tray -Awake $true -VmCount $vms.Count
        }

        Start-Wait -Seconds $IntervalSeconds
    }
}
finally {
    # The power request dies with the thread anyway, but release it explicitly.
    try { Set-KeepAwake -Enabled $false } catch { }

    $tray.Visible = $false
    $tray.Dispose()
    $menu.Dispose()
    $iconIdle.Dispose()
    $iconAwake.Dispose()

    Write-Log 'Stopped - power request released.'
}
