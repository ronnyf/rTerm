#!/usr/bin/env python3
"""Extract build settings for a given XCBuildConfiguration UUID into xcconfig form.

Usage: extract_build_settings.py <pbxproj-path> <config-uuid>
Output: xcconfig-formatted KEY = VALUE lines on stdout, sorted alphabetically.
Arrays are flattened to space-separated single lines.
"""
import subprocess, sys, re

if len(sys.argv) != 3:
    print(f"Usage: {sys.argv[0]} <pbxproj> <uuid>", file=sys.stderr)
    sys.exit(2)

pbxproj, uuid = sys.argv[1], sys.argv[2]

result = subprocess.run(
    ["/usr/libexec/PlistBuddy",
     "-c", f"Print :objects:{uuid}:buildSettings",
     pbxproj],
    capture_output=True, text=True, check=True,
)
lines = result.stdout.split("\n")

# Drop the leading "Dict {" and final "}"
if lines and lines[0].strip() == "Dict {":
    lines = lines[1:]
if lines and lines[-1].strip() == "}":
    lines = lines[:-1]
if lines and lines[-1] == "":
    lines = lines[:-1]

entries = {}
i = 0
while i < len(lines):
    raw = lines[i]
    stripped = raw.strip()
    if not stripped:
        i += 1; continue
    m = re.match(r'^(\S+)\s*=\s*(.*)$', stripped)
    if not m:
        i += 1; continue
    key, val = m.group(1), m.group(2)

    if val == "Array {":
        # Collect until matching closing brace at same indent level
        items = []
        i += 1
        while i < len(lines) and lines[i].strip() != "}":
            items.append(lines[i].strip())
            i += 1
        entries[key] = " ".join(items)
        i += 1
    else:
        entries[key] = val
        i += 1

for k in sorted(entries):
    print(f"{k} = {entries[k]}")
