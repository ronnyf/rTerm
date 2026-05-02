# T5 Efficiency Review — Empirical Findings

**Date:** 2026-05-01
**Reviewer:** Claude Sonnet 4.6 (swift-engineering, efficiency focus)
**Commit:** f7c4509 (T5: DECSTBM scroll region)

---

## Q1: Does `Buffer.shouldScroll(rows:)` introduce per-character allocation or hot-path overhead?

**Method:** Read `shouldScroll` implementation (ScreenModel.swift:137-141). Trace call sites at lines 274 and 319.

**Findings:**

```swift
func shouldScroll(rows: Int) -> Bool {
    if cursor.row >= rows { return true }
    if let region = scrollRegion { return cursor.row > region.bottom }
    return false
}
```

`shouldScroll` is a value-type method on `Buffer` (a struct). No heap allocation. `if let region = scrollRegion` uses optional binding on a 24-byte `ScrollRegion?` stored inline in the struct — no allocation. Two integer comparisons in the common case (no region: one branch; with region: two branches). Called on the hot path (every `handlePrintable` wrap + every LF/VT/FF). Cost: 2 comparisons + 1 optional binding. Negligible.

**Conclusion:** No allocation, no measurable overhead. Consistent with T4 review of `shouldScroll` from the prior quality review.

---

## Q2: Is `scrollWithinActiveBounds` called more frequently than the prior `scrollUp`?

**Method:** Trace the trigger conditions before and after T5. Before T5: `if buf.cursor.row >= rows`. After T5: `if buf.shouldScroll(rows: rows)`, which returns `true` in two cases: (a) `cursor.row >= rows` (same as before), or (b) `cursor.row > region.bottom` (new region-internal case).

**Findings:**

Case (a) is identical frequency to the old trigger. Case (b) is new: it fires when the cursor steps past the region bottom. This is only possible when a scroll region is active — which itself only happens when a shell app (vim, less, htop) has issued a `CSI r`. In the full-screen default (no region), `shouldScroll` returns `false` via case (a) only when at screen edge, exactly as before. Frequency change is zero for the common case; the new trigger only fires during region-constrained scroll, which is the feature being added.

**Conclusion:** No regression in scroll-call frequency for the default (no-region) case. Region-internal scrolls fire at appropriate frequency (once per region-bottom LF, same event rate as before but dispatched to `scrollRegionUp` instead of `scrollUp`).

---

## Q3: Is `scrollRegionUp` cheaper, equal, or more expensive than `scrollUp`?

**Method:** Count the cell copies per call for a representative configuration (80 cols, 24 rows, region rows 1–22 as vim-style bottom status line).

**Findings:**

- `scrollUp`: copies `(rows-1) * cols` cells = 23 × 80 = 1840 cells.
- `scrollRegionUp` with region top=1, bottom=22: copies `(22-1) * 80` = 21 × 80 = 1680 cells; clears 1 × 80 = 80 cells; total = 1760 cells touched.

Both use the same nested loop pattern over `ContiguousArray<Cell>`. For a narrower region (e.g., top=5, bottom=20, 15 rows): 14 × 80 = 1120 copies + 80 clears = 1200 cells. Region scrolls are equal to or cheaper than full-screen scrolls for any region smaller than the full screen.

**Conclusion:** `scrollRegionUp` is never more expensive than `scrollUp` for any valid region. Cost scales linearly with region height × cols, bounded above by the full-screen case.

---

## Q4: Does removing the `let stride = cols` local variable (plan had it, implementation drops it) have any effect?

**Method:** Compare plan's `scrollRegionUp` (uses `let stride = cols` as alias) with implementation (uses `cols` directly inline).

**Findings:**

`cols` is a `let` constant captured from the enclosing actor's lexical scope. Removing the `stride` alias eliminates one trivial `let` binding per call. The Swift compiler will produce identical code in optimized builds (O2); the binding is just a name alias for the same value. No behavioral or performance difference.

**Conclusion:** Cosmetic simplification with no effect on generated code.

---

## Q5: Does `handleSetScrollRegion` returning `false` consistently cause any snapshot publication inefficiency?

**Method:** Read `apply(_:)` (lines 213-234). Check the `changed || result` short-circuit chain.

**Findings:**

`apply` uses `changed = handleX(...) || changed` (OR with short-circuit). `handleSetScrollRegion` always returns `false`, so it contributes nothing to `changed`. If `setScrollRegion` is the only event in a batch, no `publishSnapshot()` call occurs — correct, since no visible state changes. If subsequent events return `true` (e.g., a following LF), the version bumps once for the whole batch — also correct.

No wasted snapshot builds. The nil/nil early-exit (lines 721-725) avoids even the `mutateActive` call when `scrollRegion` is already nil and the reset is a no-op — though there is no explicit guard against re-writing the same non-nil region value. Since `handleSetScrollRegion` returns `false` regardless, this does not affect snapshot publication frequency. The only "waste" is calling `mutateActive { $0.scrollRegion = nil }` even when `scrollRegion` is already nil; this is a trivial struct write with no observable cost.

**Conclusion:** No efficiency issue. The pattern is consistent with how other `false`-returning handlers (SGR, saveCursor) work.

---

## Q6: Does the `scrollWithinActiveBounds` dispatcher introduce a net instruction increase on the non-region hot path?

**Method:** Compare the pre-T5 hot path with post-T5 hot path for a screen with no scroll region.

**Pre-T5 hot path (handleC0 LF):**
```
cursor.col = 0
cursor.row += 1
if cursor.row >= rows → scrollUp(...)
```

**Post-T5 hot path (handleC0 LF, no region):**
```
cursor.col = 0
cursor.row += 1
if shouldScroll(rows:) → scrollWithinActiveBounds(...)
  shouldScroll: 1 comparison (cursor.row >= rows) → returns true/false
  scrollWithinActiveBounds: if let region = buf.scrollRegion → nil → else → scrollUp(...)
```

**Findings:**

No-region path adds: one `shouldScroll` call (2 comparisons, 0 allocations, likely inlined by compiler), one `scrollWithinActiveBounds` call (one `if let` on a nil optional → immediately falls to `else scrollUp`). These are inlined function calls on a struct method and a static function — the compiler will inline both in optimized builds. Net instruction cost in the not-scrolling case (cursor < rows) is one extra comparison vs. before. In the scrolling case, two extra comparisons plus one `if let` nil check before reaching `scrollUp`.

**Conclusion:** Negligible overhead. One to two additional comparisons on the LF hot path is not measurable in profiling for a terminal. Consistent with the T4 review's conclusion on similar dispatch indirection.

---

## Q7: Memory overhead — is the 48-byte increase from `scrollRegion` on both buffers acceptable?

**Method:** `ScrollRegion` = 2 × `Int` (8 bytes each) = 16 bytes. `ScrollRegion?` = 17 bytes rounded to 24 bytes (8-byte alignment). Two `Buffer` instances: 2 × 24 = 48 bytes.

**Findings:**

`Buffer.grid` = `ContiguousArray<Cell>` for a typical 80 × 24 screen. `Cell` must be at minimum 2 bytes (character + style); actual size requires reading `Cell.swift` but is O(tens of bytes). Grid alone is ~80 × 24 × ~(size of Cell) = several KB. 48 bytes for two optional `ScrollRegion` fields is less than 1% of buffer memory.

**Conclusion:** Memory overhead is negligible.

---

## Summary

- Hot path (`shouldScroll`) adds 1–2 comparisons per LF/wrap event, no allocations. Negligible.
- `scrollWithinActiveBounds` adds one `if let` nil check on the dispatch path, likely inlined. Negligible.
- `scrollRegionUp` is bounded by `scrollUp` cost; narrower regions are cheaper.
- `handleSetScrollRegion` returning `false` is correct and causes no snapshot publication waste.
- `stride` alias removal: cosmetic, no code-gen difference.
- 48-byte memory overhead: negligible relative to buffer grid size.
- No hot-path bloat, no hidden allocations, no memory growth concern.
