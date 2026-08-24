# Display Idle Sleep

## Disclaimer

Fully vibe-coded, I did not look at the code one bit.
This includes even the rest of this readme.
I needed this for my work laptop and shared for others who might need it too.
Works for me, use at your own risk.

## Description

A native macOS menu-bar app that turns the displays off after a configurable
period of keyboard and mouse inactivity while connected to AC power.

It is intended for a Mac whose MDM profile enforces `Display Sleep Timer = 0`.
The app does not remove or edit that profile and does not change any `pmset`
preference. It requests display-only sleep with Apple's
`pmset displaysleepnow` command when the idle timeout is reached.

The app honors macOS `PreventUserIdleDisplaySleep` assertions. Caffeine, video
playback, presentations, and `caffeinate -d` therefore pause automatic display
sleep. The menu shows when another app is preventing it. The explicit
**Turn Display Off Now** command remains available.

## Menu

Use the display icon in the menu bar to:

- Enable or disable automatic display sleep.
- Select a preset timeout or enter a custom number of minutes.
- See whether Caffeine or another app is currently preventing display sleep.
- Turn the displays off immediately.
- Open the activity log.

Settings persist between launches.

## Install

```sh
./install.sh 60
```

The argument is the initial timeout in seconds. It may be omitted to preserve
the existing setting or default to 60 seconds on the first install.

The installer builds `~/Applications/Display Idle Sleep.app` and registers a
per-user LaunchAgent so it starts at login. No administrator privileges or
additional macOS permissions are required.

## Check

```sh
"$HOME/Applications/Display Idle Sleep.app/Contents/MacOS/DisplayIdleSleep" --status
launchctl print "gui/$(id -u)/com.local.display-idle-sleep"
```

Runtime events are written to `~/Library/Logs/display-idle-sleep.log`.

## Uninstall

```sh
./uninstall.sh
```

Uninstalling removes only this user app, its preferences, and its LaunchAgent.
It does not touch the MDM profile or system power-management preferences.
