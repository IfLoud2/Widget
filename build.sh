#!/bin/sh
set -e
cd "$(dirname "$0")"
mkdir -p "$HOME/.local/bin"
swiftc -O -o "$HOME/.local/bin/StatsDesk" main.swift -framework IOKit -framework CoreWLAN
