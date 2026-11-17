#!/bin/sh
launchctl bootout "gui/$(id -u)/local.statsdesk" 2>/dev/null
pkill StatsDesk 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/local.statsdesk.plist" "$HOME/.local/bin/StatsDesk"
exit 0
