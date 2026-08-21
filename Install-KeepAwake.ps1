<#
.SYNOPSIS
    One-click installer for the VMware keep-awake watcher.

.DESCRIPTION
    Installs everything into %LOCALAPPDATA%\Programs\VMware-KeepAwake:
      1. copies Keep-AwakeWhileVMware.ps1 there,
      2. compiles KeepAwakeLauncher.exe (a windowless GUI-subsystem stub that starts
         PowerShell with CREATE_NO_WINDOW - this is what keeps a console window from
         appearing, also on machines where Windows Terminal is the default terminal
         and -WindowStyle Hidden is ignored),
      3. registers the scheduled task 'Keep Awake While VMware' to run it at logon,
      4. starts it immediately.

    No admin rights required - everything happens in the current user's context.

.PARAMETER Uninstall
    Stop the watcher, remove the scheduled task and delete the install directory.

.EXAMPLE
    .\Install-KeepAwake.ps1

.EXAMPLE
    .\Install-KeepAwake.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch] $Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TaskName     = 'Keep Awake While VMware'
$InstallDir   = Join-Path $env:LOCALAPPDATA 'Programs\VMware-KeepAwake'
$ScriptName   = 'Keep-AwakeWhileVMware.ps1'
$LauncherName = 'KeepAwakeLauncher.exe'

$targetScript   = Join-Path $InstallDir $ScriptName
$targetLauncher = Join-Path $InstallDir $LauncherName

function Stop-Watcher {
    # The launcher and the PowerShell child it started - kill both, otherwise the
    # files stay locked and a second instance would run alongside the new one.
    $stopped = 0

    Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($LauncherName)) -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue; $stopped++ }

    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*$ScriptName*" -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; $stopped++ }

    if ($stopped -gt 0) {
        Write-Host "Stopped $stopped running instance(s)."
        Start-Sleep -Milliseconds 500   # let the file handles go
    }
}

# --- Uninstall ---------------------------------------------------------------
if ($Uninstall) {
    Stop-Watcher

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Scheduled task '$TaskName' removed."
    }
    else {
        Write-Host "Scheduled task '$TaskName' was not registered."
    }

    if (Test-Path -LiteralPath $InstallDir) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
        Write-Host "Removed $InstallDir"
    }

    Write-Host ''
    Write-Host 'Uninstalled. The log file in %LOCALAPPDATA% was kept.'
    return
}

# --- Install -----------------------------------------------------------------
$sourceScript = Join-Path $PSScriptRoot $ScriptName
if (-not (Test-Path -LiteralPath $sourceScript)) {
    throw "$ScriptName not found next to this installer ($sourceScript)."
}

Stop-Watcher

if (-not (Test-Path -LiteralPath $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
Copy-Item -LiteralPath $sourceScript -Destination $targetScript -Force
Write-Host "Installed to $InstallDir"

# --- Windowless launcher -----------------------------------------------------
# Compiled as a GUI-subsystem exe, so it never owns a console itself, and it starts
# PowerShell with CreateNoWindow. It waits for the child so the scheduled task's
# lifetime matches the watcher's.
$launcherCode = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

public static class KeepAwakeLauncher
{
    public static int Main(string[] args)
    {
        string dir    = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string script = Path.Combine(dir, "Keep-AwakeWhileVMware.ps1");

        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName         = "powershell.exe";
        psi.Arguments        = "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"";
        psi.UseShellExecute  = false;
        psi.CreateNoWindow   = true;
        psi.WindowStyle      = ProcessWindowStyle.Hidden;
        psi.WorkingDirectory = dir;

        using (Process p = Process.Start(psi))
        {
            p.WaitForExit();
            return p.ExitCode;
        }
    }
}
'@

$useLauncher = $true
try {
    Add-Type -TypeDefinition $launcherCode -OutputAssembly $targetLauncher -OutputType WindowsApplication
    Write-Host "Compiled $LauncherName"
}
catch {
    $useLauncher = $false
    Write-Warning "Could not compile the launcher ($($_.Exception.Message))."
    Write-Warning 'Falling back to powershell.exe -WindowStyle Hidden - a console window may briefly flash.'
}

if ($useLauncher) {
    $action = New-ScheduledTaskAction -Execute $targetLauncher -WorkingDirectory $InstallDir
}
else {
    $argument = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $targetScript
    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument
}

# --- Scheduled task ----------------------------------------------------------
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

# Defaults would stop the task on battery - exactly the case we care about on a laptop.
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -DontStopOnIdleEnd `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName `
                       -Action $action `
                       -Trigger $trigger `
                       -Settings $settings `
                       -Principal $principal `
                       -Description 'Keeps the laptop awake while a VMware VM is powered on.' `
                       -Force | Out-Null

Write-Host "Registered scheduled task '$TaskName' (runs at logon)."

# --- Start now ---------------------------------------------------------------
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 2

$running = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
             Where-Object { $_.CommandLine -and $_.CommandLine -like "*$ScriptName*" -and $_.ProcessId -ne $PID })

Write-Host ''
if ($running.Count -gt 0) {
    Write-Host 'Running. Look for the tray icon:' -ForegroundColor Green
    Write-Host '    grey dot  = no VM powered on'
    Write-Host '    green dot = VM running, laptop stays awake'
    Write-Host ''
    Write-Host 'Windows hides new tray icons by default - if you do not see it, open the'
    Write-Host 'overflow area (^) and drag it onto the taskbar.'
}
else {
    Write-Warning 'The watcher does not seem to be running. Check the log:'
    Write-Warning "    $(Join-Path $env:LOCALAPPDATA 'vmware-keepawake.log')"
}

Write-Host ''
Write-Host "Log:       $(Join-Path $env:LOCALAPPDATA 'vmware-keepawake.log')"
Write-Host 'Uninstall: run Uninstall.cmd'
