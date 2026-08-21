# vmware-keep-awake

Keeps a Windows laptop awake while a VMware VM is running, and lets it sleep again as
soon as the last VM shuts down. Tested with VMware Workstation Pro 25.0.0 (25H2).

## Install

Double-click **`Install.cmd`**. It copies the watcher to
`%LOCALAPPDATA%\Programs\VMware-KeepAwake`, registers the logon task
*Keep Awake While VMware*, and starts it. No admin rights required.

**`Uninstall.cmd`** removes task and files. Re-running `Install.cmd` upgrades in place.

| File | Purpose |
| --- | --- |
| `Install.cmd` / `Uninstall.cmd` | One-click entry points |
| `Install-KeepAwake.ps1` | Install/uninstall logic |
| `Keep-AwakeWhileVMware.ps1` | The watcher |

## Indicator

A tray icon shows the state — **grey** = no VM running, **green** = VM running, laptop
stays awake. Hover for the VM count, double-click for a status balloon, right-click to
exit. Windows hides new tray icons, so drag it out of the overflow area (`^`) once.

State changes are logged to `%LOCALAPPDATA%\vmware-keepawake.log`.

## What counts as a running VM

Only `vmware-vmx.exe` — Workstation starts one per powered-on VM.

An open Workstation window (`vmware.exe`) without a running VM does not count, and neither
do the always-on services `vmware-authd`, `vmware-tray` and `vmware-usbarbitrator64` —
watching those would keep the laptop awake permanently.

## What is and isn't suppressed

Suppressed while a VM runs: idle sleep, **idle hibernation** (both are driven by the same
idle timer), display-off, screensaver and the idle lock.

Not suppressed, by design: closing the lid, the power button, sleeping from the Start menu,
the critical-battery action, and policy-forced restarts. None of these go through the idle
timer.

## How it works

`SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)`, with
the VM list polled every 15 s. No power plan is modified and nothing is left behind — the
request lives only as long as the process. Verify it from an elevated prompt:

```bash
powercfg /requests
```

The installer compiles `KeepAwakeLauncher.exe`, a GUI-subsystem stub that starts PowerShell
with `CREATE_NO_WINDOW`, so no console window ever appears.

The task is registered with `AllowStartIfOnBatteries` / `DontStopIfGoingOnBatteries`; the
Task Scheduler defaults would kill it on battery, which is the case that matters on a laptop.
