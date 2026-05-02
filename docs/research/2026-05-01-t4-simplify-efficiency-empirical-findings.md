# T4 Efficiency Review: Empirical Findings

Date: 2026-05-01

## 1. Is `clearGrid` on the hot path?

**Question:** Does adding `clearGrid` introduce any per-byte or per-event overhead on the `apply(_:)` hot path?

**Method:** Traced the call chain from `apply(_:)` through `handleCSI` → `handleSetMode` → `handleAltScreen` → `clearGrid`. Read `ScreenModel.swift` lines 202–223 (apply), 323–395 (handleCSI), 611–635 (handleSetMode), 641–708 (handleAltScreen), 714–717 (clearGrid).

**Findings:**

The routing chain is: `apply` → `handleCSI` only for `.csi` events → `handleSetMode` only for `.setMode` case → `handleAltScreen` only for the four alt-screen mode cases → `clearGrid` only on the specific enter/exit branches that require it. All of the alt-screen code is behind two switch dispatches. The only event type that reaches `clearGrid` is a parsed `CSI ? Pm h/l` for modes 47/1047/1049.

These events are emitted once per application startup (vim, htop, less, tmux) or on explicit user action (new app). They are not emitted per byte of output. There is zero added overhead on the printable-character path, the C0 control path, or any other event type.

**Conclusions:** `clearGrid` is strictly off the per-byte hot path. The dispatch overhead (two switch arms before `clearGrid` is reached) is sub-nanosecond and irrelevant.

---

## 2. `clearGrid` loop vs. `ContiguousArray(repeating:)` vs. `update(repeating:)`

**Question:** Is `for i in 0..<total { buf.grid[i] = .empty }` meaningfully slower than reassigning `buf.grid = ContiguousArray(repeating: .empty, count: total)` or using `buf.grid.withUnsafeMutableBufferPointer { $0.update(repeating: .empty) }`?

**Method:** Examined `Cell` and `TerminalColor` type layouts. `Cell` is a struct with a `Character` field and a `CellStyle` field. `Character` is a Swift stdlib type backed by a `_StringGuts` inline/heap hybrid. `CellStyle` contains two `TerminalColor` enums with associated values (`rgb` has three `UInt8` payloads; default case carries no data). `Cell.empty` is a static let (`Cell(character: " ")`). The grid is `ContiguousArray<Cell>`. For `Cell.empty`, the `Character` is a single-scalar ASCII space (inline storage, no heap). The loop `buf.grid[i] = .empty` copies one static let value per iteration. For 80×24 = 1920 iterations that is 1920 copy operations.

The two candidate alternatives:

- `ContiguousArray(repeating: .empty, count: total)`: allocates a new backing buffer (heap allocation), copies `.empty` `total` times, then assigns to `buf.grid`, releasing the old buffer. Net result: one more heap allocation + one deallocation compared to the bare loop. Slower in the common case.

- `buf.grid.withUnsafeMutableBufferPointer { $0.update(repeating: .empty) }`: `MutableCollection.update(repeating:)` fills in-place. Avoids heap allocation. May emit a memset-like sequence when the optimizer can prove all copies are bitwise identical and the type is trivially copyable. `Cell` is NOT trivially copyable in Swift's sense — `Character` contains a reference-typed `_StringGuts`. The optimizer is unlikely to reduce this to a `memset`. Expected cost is similar to the bare loop, possibly slightly faster due to potentially better vectorization hints from the UnsafeMutableBufferPointer form, but immeasurable at this event frequency.

`scrollUp` (T2) uses the same bare loop pattern and it was not changed; the codebase has no `withUnsafeMutableBufferPointer` precedent for grid operations.

**Conclusions:** Neither alternative offers a measurable win given the event frequency (at most a handful of calls per terminal session). The bare loop is consistent with `eraseInDisplay`/`eraseInLine` (lines 441, 443, 446, 460) and `scrollUp` (lines 592–603), which all use the same pattern. Changing convention here without measurement evidence and without simultaneously updating the other sites would introduce inconsistency for no gain. The prompt's own note on `@inlinable`/`@inline(__always)` applies equally here: no recommendation without measurement. Defer to a profile-driven pass that touches all sites together.

---

## 3. `Cursor(row: 0, col: 0)` construction in `handleAltScreen`

**Question:** Does `alt.cursor = Cursor(row: 0, col: 0)` on 1049 enter cause a hidden allocation?

**Method:** Read `ScreenSnapshot.swift` lines 27–37. `Cursor` is a plain struct with two `Int` fields (`row` and `col`). It has no stored reference types. Swift allocates small structs on the stack. `Cursor(row: 0, col: 0)` is a value-type construction with two constant integer arguments — inlineable to a pair of register writes. There is no heap allocation.

**Findings:** No heap allocation. The construction is O(1) and costs two integer stores to `alt.cursor.row` and `alt.cursor.col` after inlining. `Cursor` is used at three other sites in ScreenModel with the same pattern (lines 127, 581–582) — consistent with the codebase.

**Conclusions:** Not an issue.

---

## 4. Memory growth: does `alt` grow unboundedly?

**Question:** Could repeated alt-screen enter/exit cycles cause unbounded memory growth?

**Method:** Traced `alt` allocation in `init` (line 167: `Buffer(rows:cols:)`) and all mutations in `handleAltScreen`. `Buffer.grid` is a `ContiguousArray<Cell>` allocated once at init with `rows * cols` capacity. `clearGrid` writes to existing elements (`buf.grid[i] = .empty`) — it does not append, grow, or reallocate. `alt.cursor` is a value-type struct field. No new allocation occurs per enter/exit cycle.

**Findings:** The `alt` buffer holds exactly `rows * cols * MemoryLayout<Cell>.stride` bytes from initialization to deallocation of the `ScreenModel` actor. `clearGrid` performs in-place writes. Memory is constant.

**Conclusions:** No memory growth. Confirmed: the alt buffer is preallocated and never reallocated on mode changes.

---

## 5. Version-bump idempotency for `handleAltScreen` no-ops

**Question:** Do idempotent calls to `handleAltScreen` (e.g., entering alt while already on alt, 1048 enabled) correctly return `false` and suppress version bumps?

**Method:** Read `handleAltScreen` lines 641–708:
- `.saveCursor1048` enabled path (line 647): `mutateActive { buf in buf.savedCursor = buf.cursor }` then unconditional `return false`. Always returns false.
- `.alternateScreen47` (line 661): `guard activeKind != target else { return false }`. Returns false if already on target.
- `.alternateScreen1047` enabled (line 669): `guard activeKind != .alt else { return false }`. Returns false if already on alt.
- `.alternateScreen1047` disabled (line 674): `guard activeKind == .alt else { return false }`. Returns false if not on alt.
- `.alternateScreen1049` enabled (line 685): `guard activeKind != .alt else { return false }`. Returns false if already on alt.
- `.alternateScreen1049` disabled (line 693): `guard activeKind == .alt else { return false }`. Returns false if not on alt.

These false returns propagate up through `handleSetMode` → `handleCSI` → the `changed ||=` accumulator in `apply` → `version &+= 1` is reached only if `changed == true`. There is an existing `version_does_not_bump_on_save_cursor_only` test (line 505) that verifies CSI `.saveCursor` does not bump version. The 1048-enabled no-op follows the same logic.

No test currently verifies that a redundant 1049 enter (enter while already on alt) does not bump version. This is a test gap for the version budget but not a correctness problem.

**Findings:** All idempotent code paths return `false` through explicit guards before any state mutation. Version does not bump. `publishSnapshot` is not called.

**Conclusions:** Version-bump suppression is correct for all no-op paths. There is a minor test gap: no test asserts `version` is unchanged after a double-enter of any alt-screen mode.

---

## 6. `apply(_:)` hot-path overhead — new code

**Question:** Does the addition of `handleAltScreen` add any overhead to non-alt-screen events processed through `apply`?

**Method:** Read `apply` (lines 202–223), `handleCSI` (lines 323–395), `handleSetMode` (lines 611–635). The route to the new code requires:
1. Event must be `.csi`.
2. CSI command must be `.setMode`.
3. Mode must be one of the four alt-screen cases.

For all other event types (`.printable`, `.c0`, `.osc`, `.unrecognized`) and all other CSI commands, the new code is unreachable. The `handleSetMode` switch adds one new multi-case arm (`case .alternateScreen47, .alternateScreen1047, .alternateScreen1049, .saveCursor1048:`). This is a constant-time switch dispatch. No overhead is added to any path other than the alt-screen-mode path itself.

**Findings:** Zero added overhead to the per-byte printable path, C0 control path, SGR path, or any non-alt-screen CSI.

**Conclusions:** Hot path is clean. The new code is cleanly isolated behind switch dispatch.

---

## 7. `handleAltScreen` as a separate function vs. inlined into `handleSetMode`

**Question:** Does separating `handleAltScreen` from `handleSetMode` add function-call overhead?

**Method:** Both are `private func` on the `ScreenModel` actor. The Swift optimizer applies inlining to private functions — `handleAltScreen` is a good candidate because it has exactly one call site (`handleSetMode` line 631) and `private` visibility allows cross-module inlining to be skipped (no ABI concern). The optimizer will likely inline it. Even if not inlined, the call overhead is one branch + frame push for an event that occurs at most a few times per session.

**Findings:** Static dispatch. Single call site. The compiler has all information needed to inline. Even without inlining, the overhead is immeasurable at this frequency.

**Conclusions:** Not an issue. The function separation is the right structural choice for readability and matches the `scrollUp` / `clearGrid` pattern of factoring static helpers.

---

## 8. `clearGrid` call count per mode transition

**Question:** How many times is `clearGrid` (1920 cell writes at 80×24) called per mode transition?

**Method:** Counted invocations per path by reading lines 671, 678, 689, 696:
- `.alternateScreen1047` enter: 1x clearGrid (line 671)
- `.alternateScreen1047` exit: 1x clearGrid (line 678)
- `.alternateScreen1049` enter: 1x clearGrid (line 689)
- `.alternateScreen1049` exit: 1x clearGrid (line 696)
- `.alternateScreen47` enter/exit: 0x clearGrid (legacy, intentional)
- `.saveCursor1048` enable/disable: 0x clearGrid

Maximum clearGrid calls in a single `apply` batch: 1 (each mode transition is a single event; no batch would contain two alt-screen transitions in practice, and even if it did each is handled atomically within the switch).

**Findings:** At most 1 clearGrid per mode event, 4 total across a full vim session lifecycle (enter + exit × 2 modes = not counted that way; in practice vim uses 1049 exclusively, so 2 clearGrid calls per vim session: once on enter, once on exit).

**Conclusions:** The per-session total is 2×1920 = 3840 `Cell` assignments for the common vim/htop/less case. At ~8 bytes per Cell (Character is 1-byte inline for ASCII + CellStyle with two 1-byte TerminalColor enum discriminants + 2-byte attributes = approximately 5–7 bytes, padded), this is roughly 15–30 KB of writes per session lifetime. Completely negligible.
