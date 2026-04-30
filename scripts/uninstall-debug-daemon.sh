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
LABEL="${PLIST_NAME%.plist}"
SERVICE_TARGET="gui/$(id -u)/${LABEL}"

# bootout takes the bare label as the service-target, not a path.
launchctl bootout "$SERVICE_TARGET" 2>/dev/null || true

if [ -f "$DEST" ]; then
    rm -f "$DEST"
    echo "Uninstalled debug daemon: ${DEST}"
fi
