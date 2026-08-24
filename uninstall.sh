#!/bin/sh
set -eu

label="com.local.display-idle-sleep"
bundle_id="com.local.DisplayIdleSleep"
domain="gui/$(id -u)"
agent_path="$HOME/Library/LaunchAgents/$label.plist"
app_path="$HOME/Applications/Display Idle Sleep.app"
legacy_install_dir="$HOME/Library/Application Support/DisplayIdleSleep"

launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
rm -f "$agent_path" "$legacy_install_dir/display-idle-sleep"
rm -rf "$app_path"
rmdir "$legacy_install_dir" >/dev/null 2>&1 || true
defaults delete "$bundle_id" >/dev/null 2>&1 || true

printf 'Uninstalled Display Idle Sleep. The MDM profile was not changed.\n'
