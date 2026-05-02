# T5 Simplify-Pass Quality Review — Empirical Findings

**Date:** 2026-05-01
**Reviewer:** Claude Sonnet 4.6 (swift-engineering / simplify pass)
**Commit reviewed:** f7c4509 (model: DECSTBM scroll region — Phase 2 T5)
**Base commit:** cd72ffd (prior T5 quality review head — force-unwrap + duplication already addressed)

---

## Q1: `handleSetScrollRegion` validation — is the guard correct? Should `top == bottom` (single-row region) be accepted?

**Method:** Read `handleSetScrollRegion` at ScreenModel.swift:720–734. Trace the guard conditions. Cross-reference DECSTBM spec note in the plan doc.

**Findings:**

```swift
guard topZero >= 0, botZero < rows, topZero < botZero else { return false }
```

Three conditions:
1. `topZero >= 0` — rejects negative top after 1-index shift. Since `top` comes from the parser as a positive integer (or nil → 1), `topZero` can only be negative if the parser emitted `top: 0`. In practice parsers emit 0 for omitted params → defaults to 1 in code → `topZero = 0`, which passes. So the `>= 0` guard is defensive but harmless.
2. `botZero < rows` — correct upper-bound check.
3. `topZero < botZero` — strict less-than, meaning `top == bottom` is rejected.

**Single-row region question:** VT220 spec (DEC STD 070) says the top margin must be less than the bottom margin (`Pt < Pb`). Strict `<` is correct per spec. A single-row region (`top == bottom`) is invalid and must be silently rejected. The implementation matches spec.

**Partial-nil case (one nil, one non-nil):** The code first checks `if top == nil && bottom == nil`, which fast-paths the reset. If only one is nil, execution falls through to the conversion lines:
- `top: nil, bottom: 4` → `topZero = (nil ?? 1) - 1 = 0`, `botZero = 3`. Accepted as region (0, 3). This is the correct default-edge expansion behavior.
- `top: 2, bottom: nil` → `topZero = 1`, `botZero = (nil ?? rows) - 1 = rows - 1`. Accepted as region (1, rows-1). Also correct.

These partial-nil paths are valid per spec (omitted param = use screen edge) and work correctly. No test covers them, but neither does the spec mandate special handling — the defaults are self-consistent.

**Conclusion:** Validation is correct. Single-row rejection is per-spec. Partial-nil works correctly.

---

## Q2: `scrollWithinActiveBounds` — is `cursor.row == region.bottom + 1` safe against multi-row jumps?

**Method:** Trace the entry conditions. `shouldScroll(rows:)` fires when `cursor.row > region.bottom` (for region case) or `cursor.row >= rows` (for full-screen case). So `scrollWithinActiveBounds` can be entered with `cursor.row = region.bottom + 1`, `region.bottom + 2`, etc.

**Findings:**

```swift
if buf.cursor.row == region.bottom + 1 {
    scrollRegionUp(in: &buf, cols: cols, region: region)
    buf.cursor.row = region.bottom
} else {
    scrollUp(in: &buf, cols: cols, rows: rows)
}
```

The `==` check specifically catches the one-past-bottom case. When `cursor.row` is `region.bottom + 2` or higher (possible if `cursorPosition` moved the cursor multiple rows past region.bottom and then an LF fires), the `else` branch fires full-screen scroll instead of region scroll.

This is NOT a bug in the context of T5. The only callers of `scrollWithinActiveBounds` are:
1. `handlePrintable` — cursor increments by exactly 1 row before calling `shouldScroll`.
2. `handleC0(.lineFeed)` — cursor increments by exactly 1 row before calling `shouldScroll`.

Neither path can produce `cursor.row > region.bottom + 1` at the point of entry to `scrollWithinActiveBounds` when the cursor was at `region.bottom` before the LF. However, if the cursor was placed at `region.bottom + 2` via `cursorPosition` (a CSI H outside the region) and then LF fires, `shouldScroll` returns `true` (because `cursor.row > region.bottom`) and `scrollWithinActiveBounds` is called with `cursor.row = region.bottom + 3` (after the +1 increment). The `else` branch fires full-screen scroll — which matches xterm behavior for cursors outside the region.

The only edge case would be: cursor at `region.bottom + 1` via `cursorPosition`, then LF. The `shouldScroll` check fires (cursor.row becomes `region.bottom + 2` after increment), hits the `else` branch, does full-screen scroll. This is correct — the cursor was outside the region.

**Conclusion:** `==` is intentionally tight. The comment in `scrollWithinActiveBounds` documents this correctly. The `shouldScroll` + `==` combination means: "only region-scroll when the LF that triggered us was issued while the cursor was exactly at region.bottom." This matches xterm behavior. The concern about multi-row jumps is valid as a theoretical question but does not represent a real bug.

---

## Q3: `scrollRegionUp` does not reset cursor — dispatcher does. Is the split clean?

**Method:** Read `scrollRegionUp` (lines 648–660) and `scrollWithinActiveBounds` (lines 628–643).

**Findings:**

`scrollRegionUp` is a pure grid operation — it only moves rows and clears the bottom. Cursor reset is the dispatcher's job (`buf.cursor.row = region.bottom` at line 634). `scrollUp` (full-screen) does set `buf.cursor.row = rows - 1` inside itself (line 615). So the two helpers are inconsistent: `scrollUp` owns cursor positioning, `scrollRegionUp` does not.

This is a deliberate design trade-off: `scrollRegionUp` is narrower (only moves cells, takes no `rows` parameter, doesn't know about overall dimensions), and the dispatcher is the place that knows both the region and the target cursor row. The inconsistency is minor but a future caller of `scrollRegionUp` directly might be surprised to find cursor not moved.

**Conclusion:** The split is clean enough for this codebase, but the asymmetry between `scrollUp` (moves cursor) and `scrollRegionUp` (does not) is a minor leaky abstraction. No action required in T5; could be noted as a future cleanup if `scrollRegionUp` gets a new caller.

---

## Q4: Is `Buffer.shouldScroll(rows:)` the right owner?

**Method:** Inspect what `shouldScroll` needs: `cursor.row`, `scrollRegion`, and `rows` (passed as parameter). Compare to alternatives: free function, method on `ScreenModel`.

**Findings:**

`shouldScroll` accesses `cursor` and `scrollRegion` — both are `Buffer` fields. The only external input is `rows`, which is a screen dimension (not buffer-local state). Making it a `Buffer` method with a parameter is idiomatic Swift: the method encapsulates the predicate close to the data it inspects, and the caller supplies the one piece of context the buffer doesn't own.

The alternative (free `static func shouldScroll(_ buf: Buffer, rows: Int)`) would be equivalent but less readable at the call site. A method on `ScreenModel` would break the `mutateActive` closure pattern since `self` is not available inside those closures.

**Conclusion:** `Buffer` is the right owner. No action required.

---

## Q5: Two call sites for `shouldScroll` — extract or leave?

**Method:** Read both call sites (lines 274–276 and 319–321). Count.

**Findings:**

```swift
// handlePrintable (line 274):
if buf.shouldScroll(rows: rows) {
    Self.scrollWithinActiveBounds(in: &buf, cols: cols, rows: rows)
}

// handleC0 (line 319):
if buf.shouldScroll(rows: rows) {
    Self.scrollWithinActiveBounds(in: &buf, cols: cols, rows: rows)
}
```

Identical three-line block at two sites. Each is a different event handler. Given the prior simplify pass already extracted `shouldScroll` to remove the inline force-unwrap, this residual duplication (3 lines × 2 sites) is shallow. A further extraction to `static func scrollIfNeeded(in buf: inout Buffer, cols: Int, rows: Int)` is possible but adds a named wrapper that does nothing beyond call two existing named functions — marginal value.

**Conclusion:** The 2-site pattern is fine. Extracting further would create indirection without clarity gain.

---

## Q6: `scrollRegionUp` and `scrollUp` near-duplication — worth unifying?

**Method:** Read both static helpers (lines 603–616 and 648–660). Compare structure.

**Findings:**

`scrollUp`:
```swift
for dstRow in 0 ..< (rows - 1) { /* copy rows */ }
// clear last row
buf.cursor.row = rows - 1
```

`scrollRegionUp`:
```swift
for dstRow in region.top ..< region.bottom { /* copy rows */ }
// clear region.bottom row
// (no cursor move)
```

The row-copy loop is structurally identical; the difference is the range and whether cursor is moved. A unifying `private static func scrollRange(in buf: inout Buffer, cols: Int, top: Int, bottom: Int)` could absorb the grid work. But `scrollUp` would then call `scrollRange(top: 0, bottom: rows - 1)` and set cursor separately, and `scrollRegionUp` would call `scrollRange(top: region.top, bottom: region.bottom)`. The cursor placement would remain in the callers.

The duplication is 12 lines total. Unifying saves ~6 lines but adds a new private helper that is less self-documenting than the named pair. The named pair (`scrollUp` vs `scrollRegionUp`) is clearer: T6's history-feed hook will need to add logic only to `scrollUp`, which is easy to find by name.

**Conclusion:** Not worth unifying for T5. The T6 note ("T6 will hook full-screen scrolls for the main buffer only") is precisely why keeping them separate is better.

---

## Q7: Test coverage gaps — `test_decstbm_invalid_range` only tests `top > bottom`. What about `top == bottom`, `top < 0`, `bottom >= rows`?

**Method:** Read `test_decstbm_invalid_range` (ScreenModelTests.swift:980–993). Enumerate uncovered boundary conditions.

**Findings:**

The test covers:
- `CSI 4;2 r` → `top=4, bottom=2` → `topZero=3, botZero=1` → rejected (topZero >= botZero).

Not covered:
1. `top == bottom` (e.g., `CSI 3;3 r`) — rejected by `topZero < botZero` guard.
2. `bottom >= rows` (e.g., `CSI 1;10 r` on a 5-row screen) — rejected by `botZero < rows` guard.
3. `top < 0` — only possible if parser emits `top: 0`; `topZero` becomes -1, rejected by `topZero >= 0`. The parser likely never emits 0 for this param (0 is the VT omitted-param sentinel, defaulted to 1 before the guard).

These are separate code paths through the guard clause. A missing test for `top == bottom` is a real gap: that clause (`topZero < botZero` fails when `topZero == botZero`) is exercised by a different condition than the existing test (`topZero >= botZero` due to `top > bottom`).

**Conclusion:** Genuine test gap for `top == bottom`. The `bottom >= rows` case is also not tested but is less risky (a clearly out-of-bounds value). Both are Important-level gaps.

---

## Q8: Plan-file edit — is it clear and does it warn future readers?

**Method:** Read the plan-file diff for T5.

**Findings:**

The plan correction block is clearly marked with `> **Plan correction (2026-05-01).**` in a blockquote. It explains both original contradictions, states the corrected behavior, and notes which tests confirm it. The corrected code snippets that follow are consistent with the implementation.

One weakness: the correction explains what was wrong but does not explicitly say "do not revert to the original step 4 code — the original trigger condition was incorrect." A single sentence like "The original trigger (`>= rows` only) was incorrect and must not be reinstated" would make the note more defensive for future readers.

**Conclusion:** Clear and sufficient as-is. A one-sentence "do not revert" warning would improve it but is optional.

---

## Q9: Comments — any narrating WHAT instead of WHY?

**Method:** Scan new comments in ScreenModel.swift diff.

**Findings:**

Line 630: `// Did the LF/wrap happen at region.bottom specifically?` — narrates what the condition checks. Acceptable because the `== region.bottom + 1` condition is subtle; without this comment a reader might expect `>= region.bottom + 1`.

Line 637: `// Cursor stepped past the last screen row while outside the region` — describes a state precondition rather than narrating code, which is useful.

All docstring-level comments in the new functions explain the design intent, not the mechanics.

**Conclusion:** Comment quality is good. Line 630 is borderline "what" but justified by the subtlety of the `==` guard.

---

## Q10: `scrollRegion` not persisted in `ScreenSnapshot` — consequence at reattach?

**Method:** Read `ScreenSnapshot` fields. Check `restore(from:)` path.

**Findings:**

`ScreenSnapshot` has no `scrollRegion` field. `restore(from:)` seeds a `Buffer` with `grid` and `cursor` from the snapshot; `scrollRegion` defaults to `nil` (full-screen). This means reattach resets the scroll region.

For most sessions this is harmless — vim/htop/less re-issue `CSI r` on every redraw. However, if a program sets a scroll region and then sits idle (no output), a reattach would start with `scrollRegion = nil` and subsequent LFs would full-screen scroll until the app re-issues `CSI r`.

This is a known Phase 2 limitation (ScreenSnapshot does not yet carry per-buffer mode state beyond grid+cursor). It is out of scope for T5 but should be noted as a gap for T6 or a later snapshot evolution task.

**Conclusion:** Known limitation, not a T5 regression. Worth flagging in a future task.

---

## Summary Table

| Question | Finding | Severity |
|---|---|---|
| Q1: Validation correctness | Correct per spec. `top < bottom` strict is required. Partial-nil works. | None |
| Q2: `==` check off-by-one | Intentional. LF/wrap only increments by 1; `==` is the right gate. | None |
| Q3: Cursor split between `scrollRegionUp` and dispatcher | Minor asymmetry vs `scrollUp`. Acceptable. | Suggestion |
| Q4: `Buffer.shouldScroll` ownership | Correct owner. | None |
| Q5: 2-site `shouldScroll` pattern | Fine as-is. | None |
| Q6: `scrollUp`/`scrollRegionUp` near-duplication | Keep separate for T6 hook clarity. | None |
| Q7: Test gaps — `top==bottom`, `bottom>=rows` | Real gap. | Important |
| Q8: Plan-file edit | Clear. Optional "do not revert" sentence missing. | Suggestion |
| Q9: Comment quality | Good. | None |
| Q10: `scrollRegion` not in snapshot | Known Phase 2 gap. Not a T5 regression. | Important (future) |
