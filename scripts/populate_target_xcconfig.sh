#!/bin/bash
# Usage: populate_target_xcconfig.sh <TARGET_NAME> <DEBUG_UUID> <RELEASE_UUID>
# Runs steps 2-4: append Debug settings → dedupe against Base/Base_debug
#                → process Release, dedupe against Base/Base_release/target, append with [config=Release].
set -euo pipefail

TARGET=$1
DEBUG_UUID=$2
RELEASE_UUID=$3

cd "$(dirname "$0")/.."
XC="Config/$TARGET.xcconfig"
PBXPROJ="rTerm.xcodeproj/project.pbxproj"

# Step 2: Append Debug settings
{
    echo "// MARK: - Debug + Release (target)"
    echo ""
    scripts/extract_build_settings.py "$PBXPROJ" "$DEBUG_UUID"
} >> "$XC"

# Step 3: Dedupe Debug against Base + Base_debug
echo "--- Step 3 (Debug dedupe) for $TARGET ---"
scripts/dedupe_xcconfig.py "$XC" Config/Base.xcconfig Config/Base_debug.xcconfig 2>&1

# Step 4: Release
echo ""
echo "--- Step 4 (Release dedupe + [config=Release] suffix) for $TARGET ---"
tmp=$(mktemp "/tmp/${TARGET}_release.XXXXXX.xcconfig")
scripts/extract_build_settings.py "$PBXPROJ" "$RELEASE_UUID" > "$tmp"
scripts/dedupe_xcconfig.py "$tmp" Config/Base.xcconfig Config/Base_release.xcconfig "$XC" 2>&1

release_only=$(rg '^[A-Z_][A-Z0-9_]*[[:space:]]*=' "$tmp" | \
    sed -E 's/^([A-Z_][A-Z0-9_]*)([[:space:]]*=[[:space:]]*)(.*)$/\1[config=Release]\2\3/' || true)
rm -f "$tmp"

if [ -n "$release_only" ]; then
    {
        echo ""
        echo "// MARK: - Release-only overrides"
        echo ""
        printf '%s\n' "$release_only"
    } >> "$XC"
fi

echo ""
echo "=== Final $XC ==="
cat "$XC"
