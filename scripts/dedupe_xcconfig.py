#!/usr/bin/env python3
"""Remove settings from a target xcconfig that are already defined (same key, same value)
in one of the parent xcconfig files.

Usage: dedupe_xcconfig.py <target-xcconfig> <parent1> [parent2...]

- Parses each parent for KEY = VALUE lines (strips `#include`, comments, blanks).
- For each KEY = VALUE in the target file:
  * If KEY is defined in any parent with the SAME value → drop that line.
  * If KEY is defined in a parent with a DIFFERENT value → keep (override).
  * If KEY is not in any parent → keep.
- Non-setting lines (comments, blanks, #include) are preserved verbatim.
- Parents are NOT modified. Operates in-place on the target file.
"""
import re, sys

def parse_settings(path):
    """Return {key: value} for the xcconfig at `path`. Later lines override earlier."""
    settings = {}
    for raw in open(path):
        line = raw.rstrip("\n")
        stripped = line.strip()
        if not stripped or stripped.startswith("//") or stripped.startswith("#include"):
            continue
        # Strip trailing comment
        m = re.match(r'^([A-Z_][A-Z0-9_]*(?:\[[^\]]+\])?)\s*=\s*(.*?)\s*(?://.*)?$', stripped)
        if not m:
            continue
        settings[m.group(1)] = m.group(2).strip()
    return settings

if len(sys.argv) < 3:
    print(f"Usage: {sys.argv[0]} <target-xcconfig> <parent1> [parent2...]", file=sys.stderr)
    sys.exit(2)

target_path, *parent_paths = sys.argv[1:]

parent_values = {}
for p in parent_paths:
    parent_values.update(parse_settings(p))   # later parents override earlier

# Now filter the target file line-by-line, preserving structure.
out_lines = []
removed = []
for raw in open(target_path):
    line = raw.rstrip("\n")
    stripped = line.strip()
    if not stripped or stripped.startswith("//") or stripped.startswith("#include"):
        out_lines.append(line); continue
    m = re.match(r'^([A-Z_][A-Z0-9_]*(?:\[[^\]]+\])?)\s*=\s*(.*?)\s*(?://.*)?$', stripped)
    if not m:
        out_lines.append(line); continue
    key, val = m.group(1), m.group(2).strip()
    if key in parent_values and parent_values[key] == val:
        removed.append(f"{key} = {val}")
        continue   # drop the line
    out_lines.append(line)

# Collapse runs of >=3 blank lines to a single blank line (cosmetic)
clean = []
prev_blank = False
for ln in out_lines:
    is_blank = not ln.strip()
    if is_blank and prev_blank:
        continue
    clean.append(ln)
    prev_blank = is_blank

open(target_path, "w").write("\n".join(clean) + "\n")

if removed:
    print(f"Removed {len(removed)} inherited settings from {target_path}:", file=sys.stderr)
    for r in removed:
        print(f"  - {r}", file=sys.stderr)
else:
    print(f"No duplicates found in {target_path}.", file=sys.stderr)
