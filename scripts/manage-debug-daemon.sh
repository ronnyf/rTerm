#!/bin/bash
#
# manage-debug-daemon.sh
# Installs or uninstalls the rtermd LaunchAgent plist for Debug builds.
#
# Called from the rTerm app target's Run Script build phase.
# Pass "clean" as $1 (via ACTION) to uninstall, otherwise installs.
#
# The source plist uses BundleProgram (for SMAppService in Release);
# this script rewrites it to use Program with the DerivedData binary path.
#

set -euo pipefail

if [ "$CONFIGURATION" != "Debug" ]; then
    echo "Skipping debug daemon management for $CONFIGURATION"
    exit 0
fi

PLIST_NAME="com.ronnyf.rterm.rtermd.plist"
DEST="${HOME}/Library/LaunchAgents/${PLIST_NAME}"

# Unload existing daemon (common to both install and clean)
if [ -f "$DEST" ]; then
    launchctl unload "$DEST" 2>/dev/null || true
fi

# Clean: just remove and exit
if [ "$ACTION" = "clean" ]; then
    rm -f "$DEST"
    echo "Uninstalled debug daemon: ${DEST}"
    exit 0
fi

# Install
SOURCE="${SRCROOT}/rtermd/${PLIST_NAME}"
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
/usr/libexec/PlistBuddy -c "Delete :ProgramArguments" "$DEST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$DEST"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments: string ${RTERMD_BIN}" "$DEST"

# Load the daemon
launchctl load "$DEST"

echo "Installed debug daemon: ${RTERMD_BIN}"
echo "Plist: ${DEST}"
