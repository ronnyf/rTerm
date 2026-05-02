# T10 Simplify — Efficiency Pass: Empirical Findings

Commit: `10923bc` — "ui: scrollback view (wheel + PgUp/PgDn + auto-anchor) (Phase 2 T10)"
Review date: 2026-05-01

## Files examined

- `rTerm/RenderCoordinator.swift` (draw hot path)
- `rTerm/ScrollViewState.swift` (reconcile, wheel, page nav)
- `rTerm/TermView.swift` (onPageUp / onPageDown closures)
- `TermCore/ScreenModel.swift` (latestSnapshot / latestHistoryTail implementations)

---

## Finding 1: `cellAt` inlining — no issue

`@inline(__always)` on a nested local `func` is a hint, not a guarantee, but in practice the Swift compiler inlines trivial local closures/functions unconditionally at -O. The body is small (two branches, one array subscript each). The branch on `row < scrollOffset` is predictor-friendly: all rows 0..<scrollOffset take the history path; all rows scrollOffset..<rows take the live path. Once the branch crosses over (around row == scrollOffset) the predictor recovers in one misprediction. No concern here.

Verdict: **no issue**.

---

## Finding 2: `historyRow` copy per cell — genuine micro-cost, low impact

`ContiguousArray<Cell>` has a 16-byte header (pointer + count + capacity, or similar). When the history path is taken:

```swift
let historyRow = history[historyRowIdx]  // subscript on ContiguousArray<ContiguousArray<Cell>>
```

This copy happens once per cell in the history region, not once per row. The fix is straightforward: hoist `historyRow` one loop level up, outside `cellAt`, and eliminate the per-cell copy entirely:

```swift
for row in 0..<rows {
    let historyRow: ScrollbackHistory.Row? = row < scrollOffset
        ? history[historyStart + row]
        : nil
    for col in 0..<cols {
        let cell: Cell
        if let historyRow {
            cell = col < historyRow.count ? historyRow[col] : .empty
        } else {
            cell = liveCells[(row - scrollOffset) * cols + col]
        }
        // ... existing vertex code
    }
}
```

Alternatively, keep `cellAt` but change its signature to accept `historyRow: ContiguousArray<Cell>?` pre-hoisted by the outer loop.

**Actual impact:** `ContiguousArray` subscript on `ContiguousArray<ContiguousArray<Cell>>` is an indirect load through the outer array's storage pointer. On Apple Silicon (L1 hit) this is ~4 cycles per cell in the history region. For a 24x80 grid with 12 history rows visible, that is 12 × 80 = 960 redundant outer-array subscripts per frame at 60 fps = ~57,600 redundant loads/sec. Each load is cache-hot (the outer array is < 1 KB). At 60 fps this is negligible compared to Metal command encoding. Mark as **low impact, easy fix**.

Verdict: **suggestion only** — do not apply without profiling evidence that this is a visible cost.

---

## Finding 3: `reconcile` return value is always discarded at the draw call site — early-return optimization is absent

`draw(in:)` at RenderCoordinator.swift:178:

```swift
scrollState.reconcile(historyCount: history.count)
```

The `Bool` return is dropped (`@discardableResult` suppresses the warning). The renderer always rebuilds the full vertex arrays regardless of whether `reconcile` reported a change. This means:

- When the user is at offset == 0 (the common case), reconcile returns `false`, yet the renderer still builds `rows * cols * 6` vertex entries per frame.
- When offset > 0 and history did not grow, reconcile also returns `false`, yet vertices are rebuilt anyway.

The `reconcile` Bool is therefore currently **no-op for frame skipping**. This is pre-existing design (vertex buffers are rebuilt every frame regardless of content change — not introduced by T10). T10 does not make this worse; it correctly wires the Bool for future use.

If frame-skip optimization were added (`guard scrollState.reconcile(...) || vertexCacheIsStale else { return }`), it would need to account for all sources of frame invalidation (bell, cursor blink, live output). That scope is out of T10.

Verdict: **noted for future optimization; not a T10 issue**.

---

## Finding 4: Double mutex acquisition in `onPageUp` closure — wasted work, not a correctness issue

`TermView.makeNSView`, `onPageUp` closure (TermView.swift:158–166):

```swift
let snap = coordinator.screenModelForView.latestSnapshot()   // mutex acquire #1
guard snap.activeBuffer == .main else { return false }
let history = coordinator.screenModelForView.latestHistoryTail()  // mutex acquire #2
guard history.count > 0 else { return false }
return coordinator.handlePageUp(view: view)
```

Then `handlePageUp` (RenderCoordinator.swift:131–137):

```swift
let history = screenModel.latestHistoryTail()    // mutex acquire #3
let pageRows = screenModel.latestSnapshot().rows // mutex acquire #4
```

On a PgUp keypress, four mutex acquisitions occur in sequence where two of them (history for guard + history for page math) re-read the same lock-protected value within the same main-thread synchronous call. Because all four run on `@MainActor` with no `await` between them, and because `latestHistoryTail()` returns a copy of the `ContiguousArray` header (value-type snapshot), there is no correctness issue: the two history reads will see the same or a newer value, and the guard has already filtered the empty case.

The waste is: two extra `Mutex.withLock` round-trips per PgUp keypress. This is a cold path (user keypresses) not the render hot path. No fix needed.

Verdict: **no action required**.

---

## Finding 5: `onPageUp` guard `history.count > 0` is correct but redundant after `scrollOffset` cap

The `onPageUp` closure guards `history.count > 0` before calling `handlePageUp`. Inside `handlePageUp`, `scrollState.pageUp(pageRows:historyCount:)` is called with `historyCount: history.count`. If `history.count == 0`, `pageUp` would compute `target = min(0, offset + max(1, pageRows - 1))`. For any `offset >= 0` and `pageRows >= 1`, `target = 0`, so `changed = (0 != 0) = false`. The guard prevents the call entirely, which is correct behavior and avoids the (harmless) mutation. Not a bug, not a performance concern.

Verdict: **no issue**.

---

## Finding 6: `reserveCapacity` over-allocates for the scrollback case

RenderCoordinator.swift:238–243:

```swift
regularVerts.reserveCapacity(rows * cols * verticesPerCell * floatsPerCellVertex)
```

This reserves for a full `rows × cols` grid. When `scrollOffset > 0`, the history rows use the same vertex format as live cells, so the reservation is still correctly sized. The capacity is never wasted relative to what will be appended. Not an issue.

Verdict: **no issue**.

---

## Summary

| # | Location | Finding | Verdict |
|---|---|---|---|
| 1 | RenderCoordinator.swift:197–207 | `cellAt` inlining — compiler handles it | No issue |
| 2 | RenderCoordinator.swift:200 | `historyRow` header copied per cell, not per row | Suggestion — hoist per row if profiling shows cost |
| 3 | RenderCoordinator.swift:178 | `reconcile` Bool always discarded; no frame-skip optimization | Pre-existing design; noted for future |
| 4 | TermView.swift:161–165 + RC:132–133 | 4 mutex acquisitions per PgUp; 2 are redundant | Cold path; no action |
| 5 | TermView.swift:164 | `history.count > 0` guard is correct and mildly redundant | No issue |
| 6 | RenderCoordinator.swift:238–243 | `reserveCapacity` is correctly sized for scroll case | No issue |

**No blocking efficiency issues found.** The only actionable item is the `historyRow` per-cell copy (Finding 2), and only if profiler data shows it as a hotspot — which is unlikely given the small number of visible history rows and cache-hot access pattern.
