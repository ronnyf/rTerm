# T5 Simplify/Reuse — Empirical Findings

Date: 2026-05-01
Commit reviewed: f7c4509 (model: DECSTBM scroll region — Phase 2 T5)
Prior reviews already addressed: extracted `Buffer.shouldScroll`, corrected else branch in dispatcher.

---

## Q1: Does `scrollRegionUp` reuse logic from `scrollUp`?

**Method:** Read both functions in `TermCore/ScreenModel.swift` (lines 603–660).

**Findings:**

`scrollUp` (full-screen):
```swift
private static func scrollUp(in buf: inout Buffer, cols: Int, rows: Int) {
    for dstRow in 0 ..< (rows - 1) {
        let srcStart = (dstRow + 1) * cols
        let dstStart = dstRow * cols
        for col in 0 ..< cols { buf.grid[dstStart + col] = buf.grid[srcStart + col] }
    }
    let lastRowStart = (rows - 1) * cols
    for col in 0 ..< cols { buf.grid[lastRowStart + col] = .empty }
    buf.cursor.row = rows - 1
}
```

`scrollRegionUp` (region-bounded):
```swift
private static func scrollRegionUp(in buf: inout Buffer, cols: Int, region: ScrollRegion) {
    for dstRow in region.top ..< region.bottom {
        let srcStart = (dstRow + 1) * cols
        let dstStart = dstRow * cols
        for col in 0 ..< cols { buf.grid[dstStart + col] = buf.grid[srcStart + col] }
    }
    let bottomStart = region.bottom * cols
    for col in 0 ..< cols { buf.grid[bottomStart + col] = .empty }
}
```

The inner loops are structurally identical — both shift rows in a range `[start, end)` upward and clear the bottom. The only structural differences are: (a) `scrollUp` starts at 0, `scrollRegionUp` starts at `region.top`; (b) `scrollUp` cursor-clamps, `scrollRegionUp` does not (caller does it). `scrollUp` does NOT call `scrollRegionUp` even though it could be expressed as `scrollRegionUp(region: ScrollRegion(top: 0, bottom: rows-1))` plus a cursor-clamp.

**Conclusions:** Consolidation is possible but has a deliberate split: T6 will add history-feed to `scrollUp` (main buffer only). Merging now would complicate that T6 hook. The comment "T6 will hook full-screen scrolls for the main buffer only" in the `scrollRegionUp` doc is explicit that the split is intentional. No action needed before T6; after T6 lands a shared inner kernel (raw row-shift) could be extracted if desired.

---

## Q2: Is `Buffer.shouldScroll(rows:)` reinventing a `Cursor`-level helper?

**Method:** Searched `TermCore/ScreenSnapshot.swift` for `Cursor` definition; searched `TermCore/ScreenModel.swift` for all `clamp`/`isOutOfBounds` references; searched entire `TermCore/` for any `isOutOfBounds`/`inBounds` helpers.

**Findings:**

`Cursor` (`TermCore/ScreenSnapshot.swift` line 27) is a plain `struct { var row: Int; var col: Int }` with no methods. It has no bounds-checking API.

`clampCursor(in:)` is a private method on `ScreenModel` (line 333) — it knows `rows`/`cols`, not Cursor's own domain.

`Buffer.shouldScroll(rows:)` (line 128–135 in the diff, within the `Buffer` struct) reads:
```swift
func shouldScroll(rows: Int) -> Bool {
    if cursor.row >= rows { return true }
    if let region = scrollRegion { return cursor.row > region.bottom }
    return false
}
```

The second condition (`cursor.row > region.bottom`) is inherently region-aware — it references `scrollRegion`, which lives on `Buffer`, not on `Cursor`. A `Cursor.isOutOfBounds(rows:)` helper could cover only the first condition; the region-aware part could never live on `Cursor` without `Cursor` also carrying the scroll region (which it does not and should not — scroll region is a buffer attribute, not a cursor attribute).

**Conclusions:** `Buffer.shouldScroll` is the correct home. The combined predicate cannot be decomposed to a `Cursor` method without coupling `Cursor` to `ScrollRegion`. Clean as-is.

---

## Q3: Do the 5 new tests have a fixture/extension for "model with cursor at (r,c)"?

**Method:** Searched `TermCoreTests/ScreenModelTests.swift` for `extension`, helper functions, and recurring setup patterns; counted `let model = ScreenModel(` instantiations.

**Findings:**

There are no test helper extensions, no shared fixture structs, and no `setUp`-equivalent. Every test body starts with `let model = ScreenModel(cols: N, rows: M)` and uses `await model.apply([.csi(.cursorPosition(row: r, col: 0)), ...])` inline to position the cursor. This 2-event apply is the de-facto idiom throughout the whole file — it appears in prior test suites (ScreenModelScrollTests, ScreenModelAltScreenTests) as well as the new T5 suite.

`cursorPosition` is the pre-normalized 0-indexed event produced by the parser; using it directly in tests is correct and idiomatic. The "3-line boilerplate" is actually a 1-event array `[.csi(.cursorPosition(row: r, col: c))]` — not expensive to read.

**Conclusions:** No fixture extraction is warranted. The pattern is consistent with the rest of the file. A helper like `func moveTo(model:row:col:)` would save ~40 chars per call site but would obscure which event is being tested. The current style is appropriate for a unit test file where clarity of intent matters more than brevity.

---

## Q4: Does the `(top ?? 1) - 1` VT 1-indexed conversion pattern appear elsewhere?

**Method:** Searched `TermCore/TerminalParser.swift` and `TermCore/ScreenModel.swift` for all VT conversion sites; read the parser's `r` (DECSTBM) handling at line 649–657 of `TerminalParser.swift`.

**Findings:**

There are three distinct conversion strategies across the codebase:

1. **At-parse-time (CSI H / f — cursorPosition):** `TerminalParser.swift` line 640–642 converts immediately: `let row = p(0, default: 1) - 1`. The `CSICommand.cursorPosition` case carries 0-indexed values.

2. **At-consume-time with inline subtraction (CHA / VPA):** `CSICommand.cursorHorizontalAbsolute` and `CSICommand.verticalPositionAbsolute` are documented (in `CSICommand.swift` lines 41–43) as deliberately carrying the VT nexed value; `ScreenModel.handleCSI` does `max(0, n - 1)` inline.

3. **At-consume-time with local `let` (DECSTBM — this commit):** `handleSetScrollRegion` introduces `let topZero = (top ?? 1) - 1` / `let botZero = (bottom ?? rows) - 1`. This is the only site where the `nil`-default form (`?? 1`) is needed because the DECSTBM parameter is `Int?` (nil = "use screen edge").

The `?? 1` / `?? rows` pattern is unique to DECSTBM. The two CHA/VPA sites use plain `n - 1`. A shared helper (e.g., `func vtIndex(_ n: Int?) -> Int`) would unify pattern 3 with patterns 1 and 2, but the nil-default behavior is different for top vs. bottom (`?? 1` vs. `?? rows`), so a single helper would still require two call sites with different arguments. The current two-liner is readable and self-documenting with its inline comment.

**Conclusions:** No helper extraction needed. The nil form is unique to DECSTBM. The conversion is a 2-liner with a comment — below the extraction threshold.

---

## Q5: Is `ScrollRegion` general-purpose or usable elsewhere?

**Method:** Searched entire `TermCore/`, `rtermd/`, and `rTerm/` directories for `ScrollRegion` usage; read the struct definition at `TermCore/ScreenModel.swift` line 29.

**Findings:**

`ScrollRegion` is `private struct ScrollRegion: Sendable, Equatable` defined at file scope in `ScreenModel.swift`. All references are within that same file:
- `Buffer.scrollRegion: ScrollRegion?` stored property
- `Buffer.shouldScroll(rows:)` reads it
- `scrollWithinActiveBounds` reads `buf.scrollRegion`
- `scrollRegionUp(in:cols:region:)` parameter type
- `handleSetScrollRegion` creates instances

It is not referenced in `rtermd/`, `rTerm/`, `TermCoreTests/`, or any other file. `ScreenSnapshot` does not expose the active scroll region (by design — it is not needed by the renderer).

The struct is minimal: two `Int` fields (`top`, `bottom`), no methods. Its semantics (0-indexed inclusive row range) are terminal-specific. There is no other bounded-range concept in the codebase that would benefit from reusing it (no column-bounded regions, no selection ranges, no viewport concepts yet).

**Conclusions:** `private` scope is correct. No generalization or re-exposure is warranted at this stage. If T10 (scrollback UI) introduces a viewport row range, one could consider a shared `RowRange` abstraction, but that's speculative.

---

## Overall verdict

All five questions find the T5 implementation clean with respect to reuse:
- The `scrollUp` / `scrollRegionUp` split is intentional (T6 hook point).
- `Buffer.shouldScroll` is the correct owner of the region-aware predicate.
- Test cursor setup is idiomatic and consistent with the file's existing style.
- The `(top ?? 1) - 1` conversion is unique to DECSTBM and does not warrant a helper.
- `ScrollRegion` is appropriately scoped; no generalization needed.

No changes recommended from this review.
