# Phase 2 Branch-Wide Efficiency: Empirical Findings
Date: 2026-05-01
Scope: All 10 Phase 2 commits on `phase-2-control-chars`, cross-task hot-path patterns
Method: Static analysis of diff (`git diff main..phase-2-control-chars -- TermCore TermCoreTests rTerm rTermTests`), LSP navigation, source reading, quantitative estimates via Python arithmetic.

---

## 1. Per-Byte Parser Path (T1 — appendCSIEvents dispatcher)

**Question:** Does `appendCSIEvents` add per-byte cost vs Phase 1's direct `mapCSI` call?

**Method:** Read diff to find the 3 call sites that changed from `events.append(.csi(Self.mapCSI(...)))` to `Self.appendCSIEvents(...)`. Examined the function body and the guard it adds.

**Findings:**
- Phase 1 called `mapCSI` directly at 3 CSI-completion sites.
- Phase 2 wraps those in `appendCSIEvents` which checks `intermediates.count == 1 && intermediates[0] == 0x3F && (final == 0x68 || 0x6C)` before falling through to `mapCSI`.
- The guard is 2 integer comparisons + 2 equality checks per CSI sequence completion — not per byte. CSI sequences complete rarely compared to printable ASCII.
- `appendCSIEvents` is `private static` with no captures. It is a candidate for inlining by the optimizer.
- No heap allocations introduced by the dispatcher.

**Conclusions:** Negligible per-byte cost. The extra function call is at CSI-final-byte frequency (very low), not ground-byte frequency. No regression.

---

## 2. Per-Event Path — mutateActive Closure Dispatch (T2)

**Question:** Does routing all event handlers through `mutateActive<R>(_:)` add measurable per-event overhead vs Phase 1's direct struct mutation?

**Method:** Counted `mutateActive` call sites (25 total in ScreenModel.swift). Analyzed function signature: `private func mutateActive<R>(_ body: (inout Buffer) -> R) -> R` — non-escaping closure, generic over R.

**Findings:**
- Non-escaping closures in Swift are stack-allocated; no heap allocation per call.
- With `-O`, the Swift compiler specializes generic functions at each unique `R` type. All 25 call sites use `R = Bool`, so the function body should be specialized.
- Whether the compiler inlines the 25 call sites depends on code size heuristics, but even without inlining the overhead is a single direct call (~1–3 ns) plus the indirect function call inside.
- Phase 1 accessed the single buffer directly. Phase 2 has a 2-element struct + selector, but `mutateActive` resolves the branch once per call, not once per field access.

**Conclusions:** No per-event heap allocation. Function-call overhead is ~1–3 ns per event handler invocation. This is not measurable against terminal emulator workloads. No regression.

---

## 3. Per-Event Path — pendingHistoryPublish Flag + publishHistoryTail (T6)

**Question:** What is the true allocation cost of the history publish path per LF on the main buffer?

**Method:** Traced `handleC0(.lineFeed)` → `scrollAndMaybeEvict` → `history.push(row)` → `pendingHistoryPublish = true` → (end of apply batch) → `publishHistoryTail()` → `history.tail(1000)` → `_latestHistoryTail.withLock { $0 = HistoryBox(tail) }`.

**Findings — scrollAndMaybeEvict (once per LF on main buffer):**
- Creates `var top = ScrollbackHistory.Row()` then appends 80 `Cell` values from `buf.grid[0..<cols]`.
- `ScrollbackHistory.Row = ContiguousArray<Cell>`. Capacity is pre-reserved via `top.reserveCapacity(stride)`.
- Allocation size: 1 heap alloc for 80 × ~40 bytes ≈ 3.1 KB per scrolling LF.
- At 1,000 LF/s (fast `cat`): ~3.1 MB/s from Row allocations.
- Phase 1 had **zero** per-LF allocations. This is a genuine new regression.

**Findings — publishHistoryTail() (once per apply() batch, not once per LF):**
- `history.tail(1000)` allocates a `ContiguousArray<ContiguousArray<Cell>>` of up to 1,000 elements.
- Each element is a `ContiguousArray<Cell>` header (pointer + count + capacity = 24 bytes); the underlying cell buffers are **not** copied — CoW is preserved.
- Outer array: ~24 KB heap allocation per call.
- `HistoryBox(tail)`: 1 small class-instance heap alloc to wrap the pointer.
- `pendingHistoryPublish` batches this to once per `apply()` call regardless of how many LFs are in the batch. At large-output batch sizes (512–4096 bytes), multiple LFs share one `tail()` call.
- `_latestHistoryTail.withLock { ... }`: 1 `Mutex` acquisition per apply batch. ~10 ns.

**Net per-scrolling-LF cost:**
- 1 Row alloc (~3.1 KB) — unavoidable for history correctness.
- 1 publishHistoryTail call per apply batch (amortized across LFs in the batch) — ~24 KB outer array + 1 HistoryBox.

**Conclusions:** The Row-per-LF allocation (~3.1 KB) is a genuine new cost introduced by Phase 2. At interactive speeds it is negligible; at 10,000+ LF/s (binary-output bursts, `yes`) the allocator pressure could be noticeable. The `publishHistoryTail` alloc is batched and not per-LF. For Phase 3, consider pre-allocating Row storage in a ring and copying into fixed slots rather than allocating a new array per scroll.

---

## 4. Per-Frame Renderer Path — Vertex Array Heap Regression (T9)

**Question:** How much does Phase 2 increase per-frame heap traffic from vertex arrays?

**Method:** Counted `var xVerts = [Float](); xVerts.reserveCapacity(...)` declarations in `RenderCoordinator.draw(in:)`. Compared Phase 1 and Phase 2 baselines by reading Phase 1 source via `git show main:`.

**Findings:**
- Phase 1: 3 arrays — `regularVerts`, `boldVerts`, `underlineVerts` (from Phase 1 branch).
  - Reserved: 2 × (1920 × 6 × 12 × 4) + 1 × (1920 × 6 × 8 × 4) = ~1,440 KB per frame.
- Phase 2: 6 arrays — adds `italicVerts`, `boldItalicVerts`, `strikethroughVerts`.
  - Reserved: 4 × (1920 × 6 × 12 × 4) + 2 × (1920 × 6 × 8 × 4) = ~2,880 KB per frame.
- **Delta: +3 arrays, +1,440 KB reserved (then freed) every frame.**
- At 60 fps: Phase 1 ~84 MB/s, Phase 2 ~169 MB/s reserved-then-freed heap traffic.
- `reserveCapacity` on an empty `[Float]()` does allocate heap storage immediately (not lazy).
- `device.makeBuffer` is guarded by `if !isEmpty`, so typical text (all-regular) triggers only 1 makeBuffer per frame — same as Phase 1.

**Key observation:** The heap-traffic regression is in Swift Array allocation/deallocation, not in Metal buffer creation. For all-regular text, Metal calls are identical to Phase 1.

**Conclusions:** +1,440 KB/frame of Swift heap traffic. Noticeable at 60 fps (84 MB/s → 169 MB/s). Not a correctness issue. Phase 3 mitigation: reuse the 6 arrays as `var` instance properties on `RenderCoordinator`, reset counts via `removeAll(keepingCapacity: true)` at the top of each frame. This eliminates the per-frame alloc/free entirely.

---

## 5. Per-Frame Renderer Path — Metal makeBuffer Calls (T9)

**Question:** How many `device.makeBuffer` calls happen per frame in Phase 2 vs Phase 1?

**Method:** Grep for `makeBuffer` and `setVertexBytes` in both phase versions of RenderCoordinator.

**Findings:**
- Phase 1: up to 3 `makeBuffer` (regular, bold, underline — each guarded by `!isEmpty`) + 1 `makeBuffer` for cursor.
- Phase 2: up to 4 glyph `makeBuffer` (regular, bold, italic, boldItalic — guarded) + 2 overlay `makeBuffer` in `drawOverlayPass` (guarded) + cursor uses `setVertexBytes` (no makeBuffer).
- **Phase 2 cursor improvement:** cursor was `makeBuffer` in Phase 1, is now `setVertexBytes` in Phase 2. This saves 1 Metal allocation per frame when the cursor is visible.
- Typical text (all-regular, no decorations): 1 glyph makeBuffer + 0 overlay + setVertexBytes cursor = same as Phase 1 minus the saved cursor makeBuffer = net improvement.
- Worst case (bold+italic+underline+strikethrough): 4 + 2 = 6 makeBuffers vs Phase 1's max of 3.

**Conclusions:** Metal allocation count regresses only in the mixed-attributes worst case (unlikely for normal terminal use). Typical case is neutral or better (cursor improvement). The flag in Phase 3 notes is confirmed: 7 buffer allocations is worst-case, not typical. No action needed before Phase 3.

---

## 6. Per-Frame Renderer Path — Mutex Acquisitions (T6, T10)

**Question:** How many `Mutex.withLock` calls happen on the renderer thread per `draw(in:)`?

**Method:** Grep for `latestSnapshot()` and `latestHistoryTail()` in `draw(in:)`, tracing to their `_latestSnapshot.withLock` and `_latestHistoryTail.withLock` implementations.

**Findings:**
- Phase 1 `draw(in:)`: 1 mutex (latestSnapshot).
- Phase 2 `draw(in:)`: 2 mutexes (latestSnapshot + latestHistoryTail).
- Each mutex acquisition: ~10 ns (uncontended `OSAllocatedUnfairLock` / `Mutex`).
- Total added cost per frame: ~10 ns.

**For scroll handlers (not per-frame, per-interaction):**
- `handlePageUp`: 2 mutexes via `screenModelForView.latestHistoryTail()` + `latestSnapshot()` in the closure, plus `handlePageUp` itself calls another 2 → up to 4 total.
- `handleScrollWheel`: 1 mutex (latestHistoryTail).
- These are interaction-rate (not frame-rate), so the cost is not significant.

**Conclusions:** +10 ns per frame from the second mutex. Negligible. The snapshot + history tail reads are not combined into one lock, which means a brief window exists where a renderer can see a newer history tail with a slightly older snapshot (documented in ScreenModel comments as the "lesser evil"). This is not a correctness bug but is worth noting.

---

## 7. Per-Event Path — SnapshotBox Allocation (T3)

**Question:** Does SnapshotBox grow materially between Phase 1 and Phase 2?

**Method:** Counted new fields added to ScreenSnapshot by Phase 2 (T3): `cursorKeyApplication: Bool`, `bracketedPaste: Bool`, `bellCount: UInt64`, `autoWrap: Bool`.

**Findings:**
- New fields: 3 Bool (1 byte each) + 1 UInt64 (8 bytes) = 11 bytes extra, padded to ~16 bytes.
- SnapshotBox is a class wrapping ScreenSnapshot inline. Class instance overhead ~32 bytes on top of struct content.
- Phase 2 SnapshotBox: ~144 bytes vs Phase 1's ~128 bytes.
- Allocated once per `publishSnapshot()` call = once per `apply()` batch with mutations.

**Conclusions:** Negligible size increase. No change to allocation frequency. No regression.

---

## 8. Per-Keystroke Path — cursorKeyModeProvider Mutex (T7)

**Question:** Does the `cursorKeyModeProvider` closure add a mutex acquire on every keyDown?

**Method:** Traced `keyDown` → `cursorKeyModeProvider?()` → closure body `model.latestSnapshot().cursorKeyApplication`.

**Findings:**
- One `latestSnapshot()` call per keyDown = 1 Mutex acquisition (~10 ns).
- Phase 1 had no cursor-mode check (T7 is a new feature).
- New cost per keyDown: ~10 ns.

**Conclusions:** Acceptable. Keystroke processing was not previously on a hot path (human typing speed). The mutex call adds no allocation.

---

## 9. Per-Event Path — cellAt Branch Check (T10)

**Question:** Does the `cellAt` abstraction add overhead to the render loop in the normal live-output case?

**Method:** Read `cellAt` implementation in `draw(in:)`. Analyzed branch structure for `scrollOffset == 0` (live view) and `scrollOffset > 0` (scrolled back).

**Findings — Live view (scrollOffset == 0, most common):**
- `if row < scrollOffset` is always false → else branch always taken.
- 1 comparison per cell = 1,920 comparisons per frame at 24×80.
- ~2 µs per frame. Negligible against 16.7 ms budget.

**Findings — Scrolled view (scrollOffset > 0):**
- History path: `let historyRow = history[historyRowIdx]` called once per (row, col) pair, not once per row (the function is inlined but `historyRowIdx` is recomputed per call with `row` changing per outer loop iteration only).
- `history[historyRowIdx]` copies a `ContiguousArray<Cell>` header (24 bytes) per call.
- For scrollOffset=24, cols=80: 1,920 header copies × 24 bytes = 46 KB per frame.
- At 60 fps while scrolled: ~2.6 MB/s of header copies. Acceptable for an interaction state (user is reading, not watching live output).
- The `@inline(__always)` annotation does not guarantee hoisting of the row load out of the col loop; optimizer MAY do so but it is not guaranteed.

**Conclusions:** No meaningful regression in live-output mode. The scrolled-back render path could be improved in Phase 3 by restructuring the loop to read `history[row]` once per row (outer loop), not once per (row, col) pair.

---

## 10. Accumulated Closure Dispatch — [weak self] Allocation Check

**Question:** Do any Phase 2 closures on hot paths allocate heap via `[weak self]` captures?

**Method:** Grep for `[weak self]`, `[weak coordinator]`, `[weak view]` in TermView.swift and ContentView.swift.

**Findings:**
- `onScrollWheel`, `onPageUp`, `onPageDown`, `onActiveInput` closures use `[weak view, weak coordinator]` or `[weak coordinator]`.
- These are stored closures invoked at interaction rate (scroll, page navigation, input events), not at frame rate or byte rate.
- The weak captures are allocated once when `makeNSView` is called, not on each invocation.
- On each invocation: 1–2 optional unwraps (`guard let view, let coordinator`). No heap allocation per invocation.

**Conclusions:** No per-event heap allocations from weak captures. The closures are correctly constructed with weak captures to break retain cycles between TerminalMTKView and RenderCoordinator.

---

## Summary Table

| Hot Path | Phase 1 Baseline | Phase 2 Cost | Regression? |
|---|---|---|---|
| Per-byte parser (CSI completion) | direct `mapCSI` | 1 extra static call + 4 comparisons | None (negligible) |
| Per-event `mutateActive` | direct struct access | 1 non-escaping closure call | None (~1–3 ns) |
| Per-LF scroll Row alloc | 0 | 1 × ~3.1 KB ContiguousArray<Cell> | **Yes — new ~3.1 MB/s at 1K LF/s** |
| Per-apply `publishHistoryTail` | 0 | ~24 KB outer array (batched) | Acceptable (batched) |
| Per-apply `SnapshotBox` | ~128 B class alloc | ~144 B class alloc | None (same frequency) |
| Per-frame vertex array allocs | 3 arrays, ~1,440 KB | 6 arrays, ~2,880 KB | **Yes — doubles Swift heap traffic** |
| Per-frame Metal makeBuffer | up to 3 + cursor | up to 6; cursor uses setVertexBytes | Neutral typical; worse worst-case |
| Per-frame mutex acquires | 1 | 2 | None (~10 ns delta) |
| Per-keystroke mutex | 0 | 1 (DECCKM check) | Acceptable (new feature) |
| cellAt branch in render loop | no branch | 1 compare per cell | None (negligible) |
| cellAt history row load when scrolled | N/A | 24 B × scrollOffset × cols per frame | Acceptable (interaction state only) |

**Actionable Phase 3 items:**
1. **Reuse vertex arrays in RenderCoordinator** — make the 6 `[Float]` arrays `var` instance properties and call `removeAll(keepingCapacity: true)` at the top of `draw(in:)`. Eliminates ~1,440 KB/frame of new heap traffic from Phase 2.
2. **Pre-allocated Row storage for history** — in `scrollAndMaybeEvict`, consider reusing a scratch buffer instead of allocating a new `ContiguousArray<Cell>` per scroll. The ring-buffer structure already owns the slots; the allocation is in capturing a snapshot for the exterior push.
3. **cellAt loop restructuring when scrolled** — hoist `history[row]` out of the column loop in `draw(in:)` to avoid redundant row-header loads when `scrollOffset > 0`.
4. **Combined snapshot+history lock** — if the brief-incoherence window between the two mutex reads ever becomes observable, consider a combined SnapshotBundle type held in a single Mutex.
