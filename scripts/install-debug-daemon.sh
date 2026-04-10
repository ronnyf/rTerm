#!/bin/bash
#
# install-debug-daemon.sh
# Installs the rtermd LaunchAgent plist for Debug builds.
#
# Called from the rTerm app target's Run Script build phase.
# The source plist uses BundleProgram (for SMAppService in Release);
# this script rewrites it to use Program with the DerivedData binary path.
#

set -euo pipefail

if [ "$CONFIGURATION" != "Debug" ]; then
    echo "Skipping debug daemon install for $CONFIGURATION"
    exit 0
fi

PLIST_NAME="group.com.ronnyf.rterm.rtermd.plist"
SOURCE="${BUILT_PRODUCTS_DIR}/rTerm.app/Contents/Library/LaunchAgents/${PLIST_NAME}"
DEST="${HOME}/Library/LaunchAgents/${PLIST_NAME}"
RTERMD_BIN="${BUILT_PRODUCTS_DIR}/rtermd"

if [ ! -f "$SOURCE" ]; then
    echo "error: LaunchAgent plist not found at $SOURCE" >&2
    exit 1
fi

if [ ! -f "$RTERMD_BIN" ]; then
    echo "error: rtermd binary not found at $RTERMD_BIN" >&2
    exit 1
fi

# Copy plist and rewrite BundleProgram → Program for direct launchd loading
cp "$SOURCE" "$DEST"
/usr/libexec/PlistBuddy -c "Delete :BundleProgram" "$DEST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :Program string ${RTERMD_BIN}" "$DEST"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$DEST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :ProgramArguments" "$DEST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$DEST"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments: string ${RTERMD_BIN}" "$DEST"

# Reload the daemon
DOMAIN="gui/$(id -u)"
launchctl bootout "${DOMAIN}/${PLIST_NAME}" 2>/dev/null || true
launchctl bootstrap "${DOMAIN}" "$DEST"

echo "Installed debug daemon: ${RTERMD_BIN}"
echo "Plist: ${DEST}"
