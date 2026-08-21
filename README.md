# Keep laptop awake while a VM is running

Keeps system **and display** awake for as long as a VMware VM is powered on, and
releases the lock again as soon as the last VM is shut down.

Verified against **VMware Workstation Pro 25.0.0 (25H2)**.

## Install

Double-click **`Install.cmd`**. That is all — it

1. copies the watcher to `%LOCALAPPDATA%\Programs\VMware-KeepAwake`,
2. compiles `KeepAwakeLauncher.exe` there (see *No console window* below),
3. registers the scheduled task **"Keep Awake While VMware"** to run at logon,
4. starts it right away.

No admin rights needed — everything runs in the current user's context.

To remove it again: double-click **`Uninstall.cmd`** (stops the watcher, deletes the task
and the install directory).

Re-running `Install.cmd` upgrades an existing installation in place: it stops the running
instance first, then replaces the files and re-registers the task.

## Files

| File | Purpose |
| --- | --- |
| `Install.cmd` / `Uninstall.cmd` | One-click entry points. |
| `Install-KeepAwake.ps1` | Does the actual install/uninstall work. |
| `Keep-AwakeWhileVMware.ps1` | The watcher itself. |

## Indicator

A tray icon shows the state at a glance:

| Icon | Meaning |
| --- | --- |
| grey dot | Script running, no VM powered on — sleep allowed |
| green dot | VM running — sleep and display-off suppressed |

- **Hover** over the icon for details (including the number of running VMs).
- **Double-click** for a status balloon.
- **Right-click → Exit** to stop the watcher.

A balloon notification also pops up on each state change. State changes are appended to
`%LOCALAPPDATA%\vmware-keepawake.log` (rotated to `.old` at 1 MB).

> Windows hides new tray icons by default. If you do not see it, open the overflow
> area (`^`) and drag the icon onto the taskbar.

## What counts as "a VM is running"

Only `vmware-vmx.exe` — Workstation starts exactly one of these per powered-on VM.

An open Workstation Pro window (`vmware.exe`) without a running VM does **not** keep the
machine awake, and neither do the permanently running services (`vmware-authd`,
`vmware-tray`, `vmware-usbarbitrator64`) — those run from boot to shutdown and would
otherwise keep the laptop awake forever.

## No console window

`powershell.exe -WindowStyle Hidden` is **not** reliable: PowerShell hides the window only
*after* the host has created it, and on Windows 11 machines where **Windows Terminal** is
the default terminal application the hint is ignored altogether — a console window stays
on screen. This is why the same task can be silent on one laptop and show a window on
another.

The installer therefore compiles `KeepAwakeLauncher.exe`, a tiny GUI-subsystem stub (PE
subsystem 2, so it can never own a console) that starts PowerShell with
`CREATE_NO_WINDOW`. A headless conhost is used and the hand-off to Windows Terminal never
happens, so no window appears on any machine. The launcher waits for the watcher, so the
scheduled task's lifetime matches the watcher's.

If compilation ever fails, the installer falls back to `powershell.exe -WindowStyle Hidden`
and says so.

## How it works

`SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)` — the
same mechanism media players use. No power plan is modified, nothing is left behind: the
request lives only as long as the script's thread, so even a hard kill of the process
releases it. The VM list is polled every 15 seconds.

Check the active request (needs an **elevated** prompt):

```bash
powercfg /requests
```

While a VM runs you will see `powershell.exe` under both `SYSTEM:` and `DISPLAY:`.

The scheduled task is created with `AllowStartIfOnBatteries` / `DontStopIfGoingOnBatteries`
— the Task Scheduler defaults would kill it on battery, which is exactly the case that
matters on a laptop.

## What is and isn't suppressed

Both "sleep after" (`STANDBYIDLE`) and "hibernate after" (`HIBERNATEIDLE`) are **idle**
timers. `ES_SYSTEM_REQUIRED` resets the system idle timer, so neither countdown ever
reaches zero — **idle hibernation is suppressed as well**, even with hibernate enabled.

On a Modern Standby machine (`powercfg /a`: S0 low-power idle, no S3) hibernation is
reached *through* standby. `ES_DISPLAY_REQUIRED` keeps the screen on, and screen-off is
what gates entry into standby — so while a VM runs the machine stays in S0 and cannot
reach hibernate by that path either.

Not blocked, by design — none of these go through the idle timer:

- Closing the lid, the power button, or Sleep/Hibernate from the Start menu. On a Modern
  Standby system this enters standby, and the hibernate timer then runs from there
  → hibernates. This is the intended behaviour.
- The critical-battery action.
- Anything forced by policy, e.g. a restart for Windows updates.

## Notes

- Keeping the display on also suppresses the screensaver and the idle lock while a VM runs.
- The debug/stats builds `vmware-vmx-debug.exe` / `vmware-vmx-stats.exe` are not watched.
