#!/bin/sh
set -e
cd "$(dirname "$0")"
sh build.sh
P="$HOME/Library/LaunchAgents/local.statsdesk.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$P" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>local.statsdesk</string>
<key>ProgramArguments</key><array><string>$HOME/.local/bin/StatsDesk</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/local.statsdesk" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$P"
