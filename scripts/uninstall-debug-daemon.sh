#!/bin/bash
#
# uninstall-debug-daemon.sh
# Unloads and removes the rtermd LaunchAgent plist.
# Runs on clean action only.
#

set -euo pipefail

if [ "$CONFIGURATION" != "Debug" ] || [ "$ACTION" != "clean" ]; then
    exit 0
fi

PLIST_NAME="com.ronnyf.rterm.rtermd.plist"
DEST="${HOME}/Library/LaunchAgents/${PLIST_NAME}"

if [ -f "$DEST" ]; then
    launchctl unload "$DEST" 2>/dev/null || true
    rm -f "$DEST"
    echo "Uninstalled debug daemon: ${DEST}"
fi
