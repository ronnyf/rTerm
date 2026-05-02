# T4 Simplify / Reuse Review — Empirical Findings

**Commit:** `bf0f066` (`model: alt-screen modes 1049/1047/47 + saveCursor 1048 (Phase 2 T4)`)
**Date:** 2026-05-01
**Reviewer:** Claude Sonnet 4.6

---

## Q1: Does `clearGrid` duplicate `scrollUp`'s style precedent? Should they be co-located or share a doc-comment block? Is the loop reinventing a stdlib bulk-fill?

### Method

```bash
grep -n "private static func\|private func\|// MARK:" TermCore/ScreenModel.swift
grep -n "clearGrid\|scrollUp" TermCore/ScreenModel.swift
grep -n "\.empty\|ContiguousArray\|replaceSubrange\|update.repeating" TermCore/ScreenModel.swift
```

Read `ScreenModel.swift` lines 572–604 (`scrollUp`) and 710–718 (`clearGrid`).

### Raw Findings

- `scrollUp` is at line 591, inside the `// MARK: - Private helpers` section.
- `clearGrid` is at line 714, **outside** that section — it is the very last thing in the file, after `handleAltScreen` (641–708), which is itself after `handleSetMode` (611–635).
- Both are `private static func`, both take `(in buf: inout Buffer, cols: Int, rows: Int)`. Style is identical.
- `scrollUp` has a 4-line doc-comment. `clearGrid` has a 3-line doc-comment. They are not grouped.
- The loop in `clearGrid` (`for i in 0..<total { buf.grid[i] = .empty }`) is the same idiom already used in `eraseInDisplay` `.all` case (line 446) and `eraseInLine` `.all` case (line 460). No `replaceSubrange` or `withUnsafeMutableBufferPointer` is used anywhere in the file — the project uses explicit index loops throughout.
- `Buffer.init` at line 126 uses `ContiguousArray(repeating: .empty, count: rows * cols)` — the stdlib fill idiom does exist in the codebase, but only at allocation time. All in-place clears use the index loop.

### Conclusions

1. **Placement is inconsistent.** `clearGrid` should live in `// MARK: - Private helpers` next to `scrollUp`, not at the bottom of the file after the handler methods. The helpers section (572–604) is the established home for static buffer-mutating utilities.
2. **The loop is consistent with the rest of the file.** `replaceSubrange` or `update(repeating:)` would work but every other in-place clear in the file uses the same `for i in 0..<n { buf.grid[i] = .empty }` pattern. Changing `clearGrid` alone would create an inconsistency, not resolve one. If stdlib fill is ever adopted it should be done uniformly across all clear sites.
3. **No shared doc-comment block.** `scrollUp` and `clearGrid` are similar enough in role (static inout-buffer helpers parameterized on `cols`/`rows`) that a paired `// MARK:` or a shared callout in one of the doc-comments would help. Currently neither references the other.

---

## Q2: Are the 9 new alt-screen tests hand-rolling `ScreenModel(cols: X, rows: Y)` boilerplate, or using a factory?

### Method

```bash
grep -n "ScreenModel(cols" TermCoreTests/ScreenModelTests.swift | wc -l
grep -n "func make\|func default\|func factory\|func model\b" TermCoreTests/ScreenModelTests.swift
```

Listed all instantiation sites.

### Raw Findings

- **61 total** `ScreenModel(cols:` instantiation sites in the file (confirmed via count), each hand-rolling `let model = ScreenModel(cols: X, rows: Y)`.
- The 9 new `ScreenModelAltScreenTests` tests add 9 more (lines 660, 690, 720, 761, 778, 795, 834, 849, 866).
- No factory function, no `setUp`-style helper, no shared constant for the most common dimension (4×3 appears ~16 times; 5×3 appears ~8 times including all but one of the new T4 tests; 80×24 appears ~8 times).
- The prior reuse review (T3) already confirmed no factory pattern. T4 continues the same pattern.

### Conclusions

T4 is **consistent with the existing test style** — no factory existed before and none was added. The 9 new tests each inline `ScreenModel(cols: 5, rows: 3)` (or a variant), matching what every preceding struct in the file does. No divergence. The pre-existing gap (no shared factory/setUp) remains unaddressed, but T4 does not widen it.

---

## Q3: Is the idempotency-guard pattern reinventing something in `BufferKind` itself?

### Method

```bash
rg -rn "BufferKind" TermCore/
```

Read `TermCore/ScreenSnapshot.swift` (BufferKind definition) and the guard sites in `handleAltScreen`.

### Raw Findings

- `BufferKind` is defined in `TermCore/ScreenSnapshot.swift` lines 42–45:
  ```swift
  @frozen public enum BufferKind: String, Sendable, Equatable, Codable {
      case main
      case alt
  }
  ```
- It conforms to `Equatable` — `!=` and `==` are therefore available.
- There is no `toggle()` method on `BufferKind`.
- The guards in `handleAltScreen` are:
  - `guard activeKind != target else { return false }` (mode 47, line 661)
  - `guard activeKind != .alt else { return false }` (1047/1049 enter, lines 669/686)
  - `guard activeKind == .alt else { return false }` (1047/1049 exit, lines 674/693)
- All rely solely on `==`/`!=` via the `Equatable` conformance that `BufferKind` already provides.

### Conclusions

**No reinvention.** The guards use the standard `Equatable` `==`/`!=` operators that `BufferKind` inherits — exactly the right tool. A `toggle()` method would not help here because the guards aren't toggling; they're validating preconditions for directional transitions (enter vs. exit). The pattern is clean and does not warrant any change to `BufferKind`.

---

## Q4: Does the 1049 enter sequence duplicate logic in `restore(from:)`?

### Method

Read `ScreenModel.swift` lines 481–517 (`restore(from:)`) and lines 683–703 (`alternateScreen1049` handler).

### Raw Findings

**1049 enter** (lines 685–691):
```swift
main.savedCursor = main.cursor
activeKind = .alt
Self.clearGrid(in: &alt, cols: cols, rows: rows)
alt.cursor = Cursor(row: 0, col: 0)
```

**`restore(from:)`** (lines 495–516):
```swift
var seeded = Buffer(rows: rows, cols: cols)
seeded.grid = snapshot.activeCells
seeded.cursor = snapshot.cursor
switch snapshot.activeBuffer {
case .main: self.main = seeded; self.alt = Buffer(rows: rows, cols: cols)
case .alt:  self.alt = seeded;  self.main = Buffer(rows: rows, cols: cols)
}
self.activeKind = snapshot.activeBuffer
self.windowTitle = ...
self.modes = ...
self.bellCount = ...
self.version = ...
publishSnapshot()
```

**Differences:**
- `restore(from:)` does a **full actor-level reset** (all fields, both buffers, modes, title, version, plus `publishSnapshot()`). It reconstructs state from a serialized snapshot over the wire — a completely different operation.
- 1049 enter does an **in-session buffer swap**: it saves one cursor field, flips `activeKind`, and clears a grid. It does not touch `modes`, `windowTitle`, `pen`, `bellCount`, `version`, or the inactive buffer's grid.
- Both touch `activeKind` and a buffer's cursor, but the similarity is surface-level — they operate at different abstraction levels (deserialization vs. runtime mode-switch).

### Conclusions

**No meaningful duplication.** `restore(from:)` and `handleAltScreen(1049, enabled: true)` solve orthogonal problems. `restore` is a wholesale state rebuild from a `Codable` snapshot; 1049 enter is a targeted cursor-save + buffer-switch. Attempting to share code between them would create wrong coupling.

---

## Q5: Does the `if let saved = main.savedCursor` restore pattern in 1049 exit duplicate `restoreCursor` CSI handler logic?

### Method

Read `ScreenModel.swift` lines 369–380 (`.restoreCursor` CSI case) and lines 692–701 (1049 exit).

### Raw Findings

**`.restoreCursor` CSI handler** (lines 374–380), inside `mutateActive`:
```swift
case .restoreCursor:
    return mutateActive { buf in
        guard let saved = buf.savedCursor else { return false }
        buf.cursor = saved
        clampCursor(in: &buf)
        return true
    }
```

**1048 disable handler** (lines 649–655), also inside `mutateActive`:
```swift
} else {
    return mutateActive { buf in
        guard let saved = buf.savedCursor else { return false }
        buf.cursor = saved
        clampCursor(in: &buf)
        return true
    }
}
```

**1049 exit** (lines 697–701), direct field access (not via `mutateActive`):
```swift
if let saved = main.savedCursor {
    main.cursor = saved
    clampCursor(in: &main)
}
```

**Pattern comparison:**

| Site | How accessed | Guard style | Returns |
|---|---|---|---|
| `.restoreCursor` CSI | `mutateActive` closure | `guard let … else { return false }` | `Bool` |
| 1048 disable | `mutateActive` closure | `guard let … else { return false }` | `Bool` |
| 1049 exit | Direct `main.` field | `if let` (no early-return on nil) | `true` unconditionally (outer) |

Three sites implement the same restore-saved-cursor logic. `.restoreCursor` and `1048 disable` are **byte-for-byte identical** bodies inside `mutateActive`. The 1049 exit variant uses `if let` instead of `guard let` (different nil behavior: 1049 exit returns `true` regardless of whether a saved cursor existed) and accesses `main` directly instead of routing through `mutateActive` (necessary because 1049 exit has already switched `activeKind` to `.main` at line 696 — `mutateActive` would work but direct access is clearer).

### Conclusions

**Real duplication exists between `.restoreCursor` and `1048 disable`:** the `mutateActive` body is identical. This could be extracted to a `private func restoreActiveCursor() -> Bool` helper (3 lines: guard, assign, clamp, return true). The 1049 exit site is **not** a candidate for that same helper because (a) it must return `true` even when `savedCursor == nil` (the buffer switch already happened), and (b) it operates on the named `main` buffer, not the active one.

The `restoreCursor`/`1048 disable` duplication was present before T4 (`.restoreCursor` predates T4; `1048 disable` was added in T4). T4 introduced the second duplicate site.

---

## Summary Table

| Question | Finding | Action |
|---|---|---|
| `clearGrid` vs `scrollUp` placement | `clearGrid` is misplaced: after the handler methods, not in `// MARK: - Private helpers` beside `scrollUp` | Move `clearGrid` up to the helpers section |
| `clearGrid` loop vs stdlib fill | Consistent with all other clear sites in the file; no action needed in isolation | Clean-iff done uniformly |
| 9 new tests: factory vs inline | Consistent with the 52 pre-existing inline instantiations; no factory existed | No change needed (pre-existing gap) |
| Idempotency guard vs `BufferKind` | Uses `Equatable ==`/`!=` correctly; no `toggle()` needed | Clean |
| 1049 enter vs `restore(from:)` | Different abstraction levels; no meaningful overlap | Clean |
| 1049 exit restore vs `restoreCursor`/1048 | `.restoreCursor` and `1048 disable` have byte-for-byte identical `mutateActive` bodies; 1049 exit is structurally different | Extract shared `restoreActiveCursor() -> Bool` helper to eliminate the `.restoreCursor`/`1048 disable` duplicate |
