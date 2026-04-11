#!/bin/bash
#
# install-debug-daemon.sh
# Installs the rtermd LaunchAgent plist for Debug builds.
# Runs on build action only.
#
# The source plist uses BundleProgram (for SMAppService in Release);
# this script rewrites it to use Program with the DerivedData binary path.
#

set -euo pipefail

if [ "$CONFIGURATION" != "Debug" ] || [ "$ACTION" != "build" ]; then
    exit 0
fi

PLIST_NAME="com.ronnyf.rterm.rtermd.plist"
SOURCE="${SRCROOT}/rtermd/${PLIST_NAME}"
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

# Unload existing daemon before replacing
DOMAIN="gui/$(id -u)"
SERVICE_TARGET="${DOMAIN}/${PLIST_NAME}"
launchctl bootout "$SERVICE_TARGET" 2>/dev/null || true

# Copy plist and rewrite BundleProgram → Program for direct launchd loading
cp "$SOURCE" "$DEST"
/usr/libexec/PlistBuddy -c "Delete :BundleProgram" "$DEST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :Program string ${RTERMD_BIN}" "$DEST"
/usr/libexec/PlistBuddy -c "Delete :ProgramArguments" "$DEST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$DEST"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments: string ${RTERMD_BIN}" "$DEST"

# Load the daemon
launchctl bootstrap "$DOMAIN" "$DEST"

echo "Installed debug daemon: ${RTERMD_BIN}"
echo "Plist: ${DEST}"
