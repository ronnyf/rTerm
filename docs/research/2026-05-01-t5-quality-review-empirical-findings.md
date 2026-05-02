# T5 Quality Review — Empirical Findings

**Date:** 2026-05-01
**Reviewer:** Claude Sonnet 4.6 (code-reviewer role)
**Commit:** cd72ffd (T5: DECSTBM scroll region)
**Base:** 7c6e895 (T4 head)

---

## Q1: Does the force-unwrap on `buf.scrollRegion!` introduce any real risk?

**Method:** Read ScreenModel.swift lines 263 and 308. Inspect the surrounding boolean short-circuit.

**Findings:**

Line 263:
```swift
if buf.cursor.row >= rows || (buf.scrollRegion != nil && buf.cursor.row > buf.scrollRegion!.bottom) {
```

Line 308 (identical pattern):
```swift
if buf.cursor.row >= rows || (buf.scrollRegion != nil && buf.cursor.row > buf.scrollRegion!.bottom) {
```

Swift evaluates `&&` with left-to-right short-circuit semantics. The `buf.scrollRegion!` is only reached when `buf.scrollRegion != nil` is `true`, making the force-unwrap safe by construction in both current call sites.

**Conclusion:** The force-unwrap is safe. However, the idiomatic rewrite `if let region = buf.scrollRegion, buf.cursor.row > region.bottom` is cleaner, eliminates the dual-read of the property (read for nil check, then force-read for `.bottom`), and removes the visual noise of `!`. It is a style/readability improvement, not a correctness fix.

---

## Q2: Is the trigger condition duplicated between handlePrintable and handleC0?

**Method:** `rg -n "buf.cursor.row >= rows"` in ScreenModel.swift.

**Findings:** The two-part condition (`>= rows || (scrollRegion != nil && > scrollRegion!.bottom)`) appears verbatim at lines 263 and 308. These are the only two call sites that decide whether to invoke `scrollWithinActiveBounds`.

**Conclusion:** The duplication is real but shallow — two lines in two related handlers, both inside `mutateActive` closures. Extracting `Buffer.shouldScroll(rows:) -> Bool` would eliminate the duplication and the force-unwrap simultaneously. This is a readability/maintenance concern, not a correctness issue.

---

## Q3: Is `handleSetScrollRegion` returning `false` correct given that subsequent LFs in the same `apply` batch may now scroll differently?

**Method:** Read `apply(_:)` (lines 202-223), `ScreenSnapshot` fields (ScreenSnapshot.swift), and `makeSnapshot(from:)` (lines 236-251).

**Findings:**

- `apply(_:)` processes all events in order before bumping `version` and calling `publishSnapshot()`.
- `ScreenSnapshot` does NOT include `scrollRegion` as a field — it carries only `activeCells`, `cursor`, `cursorVisible`, `activeBuffer`, `windowTitle`, `cursorKeyApplication`, `bracketedPaste`, `bellCount`, `autoWrap`, and `version`.
- `scrollRegion` is internal `Buffer` state, not part of the render contract.
- If a `setScrollRegion` event is followed by a `lineFeed` in the same batch, `handleSetScrollRegion` returns `false` but the LF's handler returns `true`, so `changed` becomes `true` and the version bumps correctly from the LF.
- The only scenario where `false` could be wrong is if `setScrollRegion` is the *last* event in a batch with no subsequent visible change. In that case no version bump occurs — but no rendering differs either, since the renderer only reads cell content and cursor from the snapshot.

**Conclusion:** Returning `false` is correct. The `scrollRegion` field deliberately does not appear in `ScreenSnapshot` and the renderer never needs to know about it. The concern raised in the review prompt does not constitute a bug.

---

## Q4: Is the `scrollWithinActiveBounds` dispatcher logic correct for all trigger cases?

**Method:** Read lines 617-632 and trace the two trigger conditions from the callers.

**Findings:**

Callers increment `buf.cursor.row` by exactly 1 before calling the dispatcher. So the dispatcher receives `buf.cursor.row` as either:
- `rows` (one past the last row, full-screen case), or
- `region.bottom + 1` (one past the region bottom, region-scroll case).

Dispatcher branch 1: region is non-nil, `cursor.row == region.bottom + 1` → `scrollRegionUp`, cursor clamped to `region.bottom`. Correct.

Dispatcher branch 2: region is non-nil, `cursor.row != region.bottom + 1` → by the trigger condition in the callers, this case is only reached when `cursor.row >= rows` (the second `||` arm in the trigger). So cursor must be at `rows`. `scrollUp` is called. Correct.

Dispatcher branch 3: no region → `scrollUp`. Correct.

**Conclusion:** The logic is sound. The "below-region LF triggers full-screen scroll" behavior matches xterm and is correctly gated by the trigger condition in the callers combined with the dispatch logic.

---

## Q5: Does `scrollRegionUp` need to reset the cursor?

**Method:** Read `scrollRegionUp` (lines 637-649) and its only caller in `scrollWithinActiveBounds` (lines 622-623).

**Findings:** `scrollRegionUp` moves cell data only. The cursor reset (`buf.cursor.row = region.bottom`) is performed by `scrollWithinActiveBounds` immediately after. `scrollRegionUp` has no call sites other than `scrollWithinActiveBounds`.

**Conclusion:** The split is clean and intentional. The cursor responsibility belongs at the dispatcher level, not inside the pure cell-shift helper. This is consistent with how `scrollUp` also sets `buf.cursor.row = rows - 1` at its own level rather than delegating to a caller. No issue.

---

## Q6: Does `handleSetScrollRegion` handle the mixed-nil case (one param nil, other non-nil)?

**Method:** Read lines 709-722. Trace the nil/nil check and the `?? 1` / `?? rows` defaults.

**Findings:**

```swift
if top == nil && bottom == nil {
    mutateActive { $0.scrollRegion = nil }
    return false
}
let topZero = (top ?? 1) - 1
let botZero = (bottom ?? rows) - 1
```

If `top == nil, bottom = 4` (non-nil bottom only): `topZero = 0`, `botZero = 3`. Treated as "from row 0 to row 4-1=3". Guard passes if `botZero < rows` and `topZero < botZero`.

If `top = 2, bottom == nil`: `topZero = 1`, `botZero = rows - 1`. Treated as "from row 2 to last row".

The VT spec says `CSI ; Pb r` with a missing top param should default to 1 (first row) and missing bottom should default to the last row. The `?? 1` and `?? rows` defaults match this.

**Conclusion:** Mixed-nil cases are handled correctly via the defaults. No issue.

---

## Q7: Coverage gaps — are verticalTab and formFeed scroll-with-region tested?

**Method:** `rg -n "verticalTab|formFeed"` in TermCoreTests/ScreenModelTests.swift.

**Findings:** Lines 282-295 have `verticalTab_behaves_as_lineFeed` and `formFeed_behaves_as_lineFeed` tests. Both test only simple non-scroll scenarios (single LF motion on a small grid). Neither exercises a region or a scroll trigger with `verticalTab`/`formFeed` specifically.

The new T5 tests all use `.c0(.lineFeed)`. The code path for `verticalTab` and `formFeed` is identical (`case .lineFeed, .verticalTab, .formFeed:` in the same switch arm at line 304), so any bug introduced there would need an identically structured trigger. The region-scroll path is therefore not directly tested for VT/FF.

**Conclusion:** Coverage gap — not a correctness bug given the shared code path, but a test gap that could silently regress if the switch arm is ever refactored to split the cases. Worth a comment, not a blocker.

---

## Q8: Are there any `nonisolated(unsafe)`, unchecked Sendable, or actor isolation boundary issues in the new code?

**Method:** `rg -n "nonisolated.unsafe\|@unchecked Sendable\|Task {" TermCore/ScreenModel.swift`.

**Findings:** None found. All new methods (`handleSetScrollRegion`, `scrollWithinActiveBounds`, `scrollRegionUp`) are either actor-isolated instance methods or static functions operating on `inout Buffer` — both patterns are safe. `ScrollRegion` conforms to `Sendable` (line 29) via a struct of two `Int`s, which is trivially correct.

**Conclusion:** No concurrency issues.

---

## Q9: Does `test_decstbm_lf_below_region_does_full_screen_scroll` actually test the right cursor post-scroll position?

**Method:** Trace: rows=5, cursor at row 4, LF fires. `cursor.row` becomes 5. Trigger condition: `5 >= 5 (rows)` is true. `scrollWithinActiveBounds` called. Region is `{top:1, bottom:3}`. `cursor.row (5) != region.bottom + 1 (4)` → takes the `else` branch → `scrollUp`. `scrollUp` sets `cursor.row = rows - 1 = 4`. Test asserts `snap.cursor.row == 4`.

**Findings:** Assertion is correct. The cursor-position check is valid.

**Conclusion:** Test logic is sound.

---

## Q10: Plan deviation — `handleSetScrollRegion` nil/nil check order

**Method:** Compare plan Step 3 code with implementation at lines 709-722.

**Plan code:**
```swift
let topZero  = (top ?? 1) - 1
let botZero  = (bottom ?? rows) - 1
if top == nil && bottom == nil {
    mutateActive { $0.scrollRegion = nil }
    return false
}
```
(Computes `topZero`/`botZero` before the nil/nil check — redundant computation.)

**Implementation code:**
```swift
if top == nil && bottom == nil {
    mutateActive { $0.scrollRegion = nil }
    return false
}
let topZero = (top ?? 1) - 1
let botZero = (bottom ?? rows) - 1
```
(Early-exit first, then compute — no redundant work.)

**Conclusion:** Implementation improves on the plan. The reordering is a clean early-exit refactor with no behavioral difference.
