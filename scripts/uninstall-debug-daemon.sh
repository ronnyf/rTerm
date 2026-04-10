#!/bin/bash
#
# uninstall-debug-daemon.sh
# Unloads and removes the rtermd LaunchAgent plist for Debug builds.
#
# Called from the rTerm app target's Run Script build phase (clean action).
#

set -euo pipefail

if [ "$CONFIGURATION" != "Debug" ]; then
    exit 0
fi

PLIST_NAME="com.ronnyf.rterm.rtermd.plist"
DEST="${HOME}/Library/LaunchAgents/${PLIST_NAME}"

if [ -f "$DEST" ]; then
    launchctl unload "$DEST" 2>/dev/null || true
    rm -f "$DEST"
    echo "Uninstalled debug daemon: ${DEST}"
fi
