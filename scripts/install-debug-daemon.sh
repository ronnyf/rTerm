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
# Use the embedded binary inside the app bundle. rtermd's @rpath resolves
# @loader_path/../Frameworks to rTerm.app/Contents/Frameworks, where the
# Embed Frameworks phase has placed Apple-Engineer-signed TermCore/TermUI.
# Loading from $BUILT_PRODUCTS_DIR/rtermd directly would hit the build-time
# framework copies and, since rtermd is now an AMFI-trusted platform binary,
# dyld would refuse to load them for platform/non-platform mismatch.
RTERMD_BIN="${BUILT_PRODUCTS_DIR}/rTerm.app/Contents/MacOS/rtermd"

if [ ! -f "$SOURCE" ]; then
    echo "error: LaunchAgent plist not found at $SOURCE" >&2
    exit 1
fi

if [ ! -f "$RTERMD_BIN" ]; then
    echo "error: rtermd binary not found at $RTERMD_BIN" >&2
    exit 1
fi

# Unload existing daemon before replacing. launchctl wants the bare label
# (without the .plist extension) as the service-target.
DOMAIN="gui/$(id -u)"
LABEL="${PLIST_NAME%.plist}"
SERVICE_TARGET="${DOMAIN}/${LABEL}"
launchctl bootout "$SERVICE_TARGET" 2>/dev/null || true

# Copy plist and rewrite BundleProgram → Program for direct launchd loading.
# With Apple Engineer code signing + AMFI Trusted Keys, LWCR validation passes
# so AssociatedBundleIdentifiers can stay. (If the signing identity is missing
# and builds fall back to adhoc, the LWCR check fails with the generic
# "Input/output error" during bootstrap -- strip the key as a workaround then.)
cp "$SOURCE" "$DEST"
/usr/libexec/PlistBuddy -c "Delete :BundleProgram" "$DEST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :Program string ${RTERMD_BIN}" "$DEST"
/usr/libexec/PlistBuddy -c "Delete :ProgramArguments" "$DEST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$DEST"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments: string ${RTERMD_BIN}" "$DEST"

# Load the daemon, then kickstart out of any pre-existing penalty box so
# subsequent XPC connections spawn the fresh binary immediately.
launchctl bootstrap "$DOMAIN" "$DEST"
launchctl kickstart -k "$SERVICE_TARGET" 2>/dev/null || true

echo "Installed debug daemon: ${RTERMD_BIN}"
echo "Plist: ${DEST}"
