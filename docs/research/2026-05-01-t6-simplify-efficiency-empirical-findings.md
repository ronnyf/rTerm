# T6 Efficiency Review — Empirical Findings
# Phase 2 T6: scrollback history + attach-payload + restore
# Commit: a57dfa3  BASE: cef6d91 (parent)

**Date:** 2026-05-01
**Reviewer:** Claude Sonnet 4.6 (efficiency review)

---

## Q1: Is `history.push(_)` O(1)?

**Method:** Traced call to `CircularCollection.append` at
`TermCore/CircularCollection.swift:26–31`.

**Findings:**
```swift
@inlinable
public mutating func append(_ element: Container.Element)
    where Container: MutableCollection, Container.Index == Int {
    let newOffset = offset.advanced(by: 1) % elements.count
    elements[newOffset] = element
    offset = newOffset
}
```
Two arithmetic ops + one subscript write. The `ScrollbackHistory.push` wrapper
adds one comparison (`if validCount < capacity`). Both are constant-time.

**Conclusion:** Confirmed O(1). No allocation on push — overwrites a pre-allocated
slot in the ring.

---

## Q2: Does `scrollAndMaybeEvict` allocate a Row when `isMain` is false?

**Method:** Read `TermCore/ScreenModel.swift:734–785` (the static helper).

**Findings:**
```swift
var evicted: ScrollbackHistory.Row? = nil
if isMain {
    var top = ScrollbackHistory.Row()
    top.reserveCapacity(stride)
    for col in 0 ..< stride { top.append(buf.grid[col]) }
    evicted = top
}
```
The `Row()` allocation and `reserveCapacity` are inside `if isMain`. When
`isMain == false` (alt buffer active), the function skips directly to the
grid-shift loop and returns `nil`. No heap allocation occurs on the alt path.

**Conclusion:** Confirmed. Alt-buffer scrolls are allocation-free on this path.

---

## Q3: What is the complexity of `ScrollbackHistory.tail(_:)` and does it matter?

**Method:** Read `TermCore/ScrollbackHistory.swift:72–93`. Traced through
`CircularCollection.Sequence.Iterator` logic.

**Findings:**
The iterator always walks all `capacity` slots regardless of `take`:
```swift
for (i, row) in ring.enumerated() {   // iterates capacity elements
    if i < (capacity - validCount) { continue }   // skip placeholders
    if seen < skip { seen += 1; continue }         // skip unwanted tail
    result.append(row)
}
```
For default capacity=10K, each `tail(1000)` call makes 10K iterator
steps + up to 1K reference copies (~16 bytes/ref) into the result array.

`publishHistoryTail()` calls `tail(1000)` at most once per `apply()` batch
because `pendingHistoryPublish` is cleared after the first call within a
batch. At saturated output rates (`yes` command, ~30 scrolls/sec at 80x24),
that yields:
- 30 × 10K = 300K iterator steps/sec
- 30 × 1K × ~16B = ~480 KB/sec of reference copy traffic (rows are CoW-shared,
  not deep-copied)

Both figures are well within macOS single-thread budget (~1B ops/sec).
The O(capacity) bound is fixed regardless of `take` — the ring cannot
efficiently seek to the valid-row window without a two-pass approach.

**Conclusion:** Materially acceptable for current usage. The constant factor
is small (integer arithmetic + branch). An O(take) optimisation (seek to
the (capacity - validCount) offset via `ring[ring.count - validCount]`)
would require exposing the ring's physical index mapping, which the current
`Collection` subscript already computes. A `suffix`-from-offset approach
would be faster for large-capacity, small-tail scenarios (e.g., 10K capacity,
tail(10)). Not needed now; worth noting for Phase 3 if deep-history RPC
introduces very large capacity values.

---

## Q4: Are there hidden per-character allocations on the hot path?

**Method:** Traced `handlePrintable` and `handleC0(LF/VT/FF)` diff in
`ScreenModel.swift`.

**Findings:**
- The Row allocation (`ScrollbackHistory.Row()` + `reserveCapacity` + element
  copy loop) only fires when `isMain == true` AND the buffer did a full-screen
  scroll (not region scroll). This is per-scroll, not per-character.
- The `pendingHistoryPublish = true` flag write is per-scroll (one Bool write).
- `publishHistoryTail()` allocation (fresh `ContiguousArray<Row>` of up to 1K
  elements) fires once per `apply()` batch, not per scroll within a batch.
- No new allocations added on the non-scroll character path.

**Conclusion:** Zero per-character overhead added by T6. Hot path is clean.

---

## Q5: Memory footprint of `_latestHistoryTail` published tail

**Method:** Calculated from constants and types.

**Findings:**
- `publishedHistoryTailSize = 1000`
- Published tail: `ContiguousArray<ContiguousArray<Cell>>` with 1000 elements.
- Each element is a reference (8 bytes) pointing to a shared `ContiguousArray`
  buffer. The row buffers are CoW-shared with `history.ring` — no cell-level
  copy occurs at publish time.
- Published tail overhead: 1000 × 8 bytes = ~8 KB for the outer array's
  reference spine. The cells themselves remain in the ring.
- Renderer holding the returned ContiguousArray: same reference spine (~8 KB)
  plus the renderer's Arc on each row buffer.

**Conclusion:** Memory footprint of the published tail is ~8 KB for the
reference spine. The cell data (~2.5 MB at 80 cols × 1000 rows × 32 bytes)
is shared via CoW; it is allocated only once (in the ring) and retained until
the ring slot is overwritten.

---

## Q6: `buildAttachPayload` suffix(500) ternary

**Method:** Read `ScreenModel.swift:696–698`.

**Findings:**
```swift
let last500 = tail.count > 500 ? ContiguousArray(tail.suffix(500)) : tail
```
The ternary avoids one `ContiguousArray(...)` allocation when `tail.count <= 500`
(the tail is returned as-is). When `tail.count > 500`, `suffix(500)` returns a
`Slice` of the published tail, and `ContiguousArray(...)` allocates a new
spine of 500 references. This is called once per attach event (rare).

The unconditional `ContiguousArray(tail.suffix(500))` form would also be correct
and simpler: when `count <= 500`, `suffix(500)` returns all elements, and
wrapping in `ContiguousArray` just copies the reference spine (trivially cheap).
The ternary is a micro-optimisation that avoids one O(min(count,500)) copy on
the common pre-500-row path.

**Conclusion:** Functionally correct. The ternary is a minor optimization
that is defensible. Simplifying to `ContiguousArray(tail.suffix(500))` is a
suggestion-level change, not a requirement.

---

## Q7: `@usableFromInline` on `ring` without any `@inlinable` methods

**Method:** Checked `ScrollbackHistory.swift` for `@inlinable` annotations.

**Findings:**
`ring` is marked `@usableFromInline` but no methods on `ScrollbackHistory` carry
`@inlinable`. The annotation is therefore inert — it would only matter if `push`
or `tail` were marked `@inlinable`, which they are not. `TermCore` has
`BUILD_LIBRARY_FOR_DISTRIBUTION` enabled, so `@usableFromInline` is valid to
have but has no effect on the current ABI.

**Conclusion:** The `@usableFromInline` on `ring` is dead annotation. It does
not cause harm but should be removed if `@inlinable` is never added to
`push`/`tail`. Minor hygiene issue only.

---

## Summary

| # | Area | Finding |
|---|------|---------|
| Q1 | `push` complexity | Confirmed O(1), no allocation |
| Q2 | Alt-path allocation | Confirmed: no Row allocation when isMain==false |
| Q3 | `tail(_:)` complexity | O(capacity) per call; ~300K steps/sec at 30 scrolls/sec — acceptable |
| Q4 | Per-character overhead | Zero new overhead on non-scroll path |
| Q5 | Published tail memory | ~8 KB reference spine; cell data CoW-shared from ring |
| Q6 | `suffix(500)` ternary | Micro-optimization; correct; simplifiable to suggestion |
| Q7 | `@usableFromInline` on `ring` | Dead annotation; minor hygiene |

No blocking efficiency concerns. One suggestion: if Phase 3 introduces very large
capacity (e.g., 100K rows), `tail(n)` should be optimised to O(n) by indexing
into the ring at `(ring.offset + 1 + capacity - validCount) % capacity` to
skip the placeholder scan.
