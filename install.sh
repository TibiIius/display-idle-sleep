#!/bin/sh
set -eu

label="com.local.display-idle-sleep"
bundle_id="com.local.DisplayIdleSleep"

if [ "$#" -gt 1 ]; then
    printf 'Usage: %s [timeout-seconds]\n' "$0" >&2
    exit 64
fi

if [ "$#" -eq 1 ]; then
    timeout="$1"
    case "$timeout" in
        ''|*[!0-9]*)
            printf 'Timeout must be a positive whole number of seconds.\n' >&2
            exit 64
            ;;
    esac

    if [ "$timeout" -eq 0 ]; then
        printf 'Timeout must be greater than zero.\n' >&2
        exit 64
    fi
else
    timeout=$(defaults read "$bundle_id" timeoutSeconds 2>/dev/null || printf '60')
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_dir="$script_dir/.build"
build_app="$build_dir/Display Idle Sleep.app"
app_path="$HOME/Applications/Display Idle Sleep.app"
executable_path="$app_path/Contents/MacOS/DisplayIdleSleep"
agent_path="$HOME/Library/LaunchAgents/$label.plist"
log_path="$HOME/Library/Logs/display-idle-sleep.log"
legacy_install_dir="$HOME/Library/Application Support/DisplayIdleSleep"
domain="gui/$(id -u)"
arch=$(uname -m)

mkdir -p "$build_dir" "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
rm -rf "$build_app"
mkdir -p "$build_app/Contents/MacOS"
/usr/bin/install -m 644 "$script_dir/Resources/Info.plist" "$build_app/Contents/Info.plist"

xcrun swiftc \
    -O \
    -target "$arch-apple-macos13.0" \
    -framework AppKit \
    -framework CoreGraphics \
    -framework IOKit \
    "$script_dir/Sources/main.swift" \
    -o "$build_app/Contents/MacOS/DisplayIdleSleep"

codesign --force --deep --sign - "$build_app"

launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
rm -rf "$app_path"
/usr/bin/ditto "$build_app" "$app_path"
rm -f "$legacy_install_dir/display-idle-sleep"
rmdir "$legacy_install_dir" >/dev/null 2>&1 || true

defaults write "$bundle_id" timeoutSeconds -float "$timeout"
if ! defaults read "$bundle_id" enabled >/dev/null 2>&1; then
    defaults write "$bundle_id" enabled -bool true
fi
if ! defaults read "$bundle_id" blackImageMode >/dev/null 2>&1; then
    defaults write "$bundle_id" blackImageMode -bool false
fi

plutil -create xml1 "$agent_path"
plutil -insert Label -string "$label" "$agent_path"
plutil -insert ProgramArguments -array "$agent_path"
plutil -insert ProgramArguments.0 -string "$executable_path" "$agent_path"
plutil -insert RunAtLoad -bool true "$agent_path"
plutil -insert KeepAlive -dictionary "$agent_path"
plutil -insert KeepAlive.SuccessfulExit -bool false "$agent_path"
plutil -insert ProcessType -string Interactive "$agent_path"
plutil -insert LimitLoadToSessionType -string Aqua "$agent_path"
plutil -insert ThrottleInterval -integer 10 "$agent_path"
plutil -insert StandardErrorPath -string "$log_path" "$agent_path"

launchctl bootstrap "$domain" "$agent_path"
launchctl kickstart -k "$domain/$label"

printf 'Installed %s with a %s-second AC idle timeout.\n' "$app_path" "$timeout"
printf 'Use the display icon in the menu bar to change the timeout.\n'
printf 'Log: %s\n' "$log_path"
