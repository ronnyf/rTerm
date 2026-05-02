# T7 Efficiency Review — c37093e (arrows/Home/End/PgUp/PgDn + DECCKM)

Date: 2026-05-01
Reviewer: Claude Sonnet 4.6 (Code Review role)
Scope: Hot-path efficiency of the key-encoding pipeline added in T7. No build performed.

---

## Questions Under Review

1. **`cursorKeyModeProvider` reads `latestSnapshot()` on every keyDown — is this OK?**
2. **`Data([0x1B, 0x5B, ...])` small allocations on every keyDown — material?**
3. **`cursorKey(_:mode:)` helper — any work that could be hoisted out of the per-call path?**

---

## 1. `latestSnapshot()` on every keyDown

**Verdict: fine.**

`latestSnapshot()` is `nonisolated` at `ScreenModel.swift:681` and its entire body is:

```swift
nonisolated public func latestSnapshot() -> ScreenSnapshot {
    _latestSnapshot.withLock { $0.snapshot }
}
```

`_latestSnapshot` is a `Mutex<SnapshotBox>` (`ScreenModel.swift:105`). `SnapshotBox` is a `final class` holding the snapshot by reference. So the hot path is:

1. Enter mutex (OS unfair lock — ~10 ns uncontested on arm64).
2. Load a reference (pointer-width read).
3. ARC retain on the `SnapshotBox` (atomic increment).
4. Exit mutex.
5. Load `Bool` field `cursorKeyApplication` off the `SnapshotBox`.
6. ARC release when the closure in `makeCursorKeyModeProvider` returns.

No `await`, no actor hop, no copying of the full `ScreenSnapshot` struct off the heap. The closure at `TermView.swift:103` captures `model` (the `ScreenModel` actor reference) once at view-make time — there is no closure re-creation on each keystroke.

The closure itself is re-created on each `updateNSView` call (`TermView.swift:92`), but that is driven by SwiftUI's diff cycle (triggered by `@Observable` changes on `TerminalSession`), not by every keyDown. This is correct.

**Caching `cursorKeyApplication` would be premature optimization** — it would add observable state somewhere (on `TerminalMTKView` or `TerminalSession`) and a synchronization point without measurable benefit. The mutex read is already the minimal synchronization cost for reading a value that can change at any time from the daemon queue.

---

## 2. `Data([0x1B, 0x5B, ...])` allocations on every keyDown

**Verdict: not material.**

Each arrow/navigation key returns a 3- or 4-byte `Data` allocation. Heap allocation for a 3–4 byte `Data` on macOS is approximately 30–60 ns (malloc fast path from the default zone). At 100 keystrokes/second (sustained fast typing), this is ~5 µs/s of allocation pressure. The Swift runtime's small-allocation fast path makes these essentially free compared to the actual I/O work that follows (XPC send to rtermd).

`Data` with small inline storage (≤ 15 bytes on 64-bit) may not heap-allocate at all on recent Swift runtimes depending on the bridging path — this applies to the 3- and 4-byte sequences produced here. Even if they do allocate, the ARC lifecycle is short (handed to `onKeyInput` and released in the same call frame if the closure does not retain it).

**No change warranted.**

---

## 3. `cursorKey(_:mode:)` helper — hoistable work?

**Verdict: nothing to hoist.**

The helper at `KeyEncoder.swift:98–108` is:

```swift
private func cursorKey(_ key: CursorKey, mode: CursorKeyMode) -> Data {
    let final: UInt8
    switch key {
    case .up:    final = 0x41
    case .down:  final = 0x42
    case .right: final = 0x43
    case .left:  final = 0x44
    }
    let intro: UInt8 = (mode == .application) ? 0x4F : 0x5B
    return Data([0x1B, intro, final])
}
```

All work here is:
- Two integer comparisons (switch + ternary): O(1), no branches to eliminate.
- One 3-byte `Data` construction: already at minimum size.

There is no precomputation worth caching. A static lookup table (`[CursorKey: [UInt8]]`) would add more complexity than it removes and would still need the `mode` dispatch to pick the intro byte.

`KeyEncoder` is a value type (`struct`) with no stored properties, so `self` is a no-op; the method call is a direct dispatch (no vtable). The compiler will inline this freely.

**No change warranted.**

---

## 4. `KeyEncoder()` instantiation in `keyDown`

Not in the original question but worth noting: `KeyEncoder()` is constructed fresh on each `keyDown` call (`TermView.swift:53`). Since `KeyEncoder` is an empty struct with no stored properties, this compiles to zero runtime work — the compiler emits no allocation and no initialization. This pattern is already correct and there is nothing to gain by hoisting it to a stored property.

---

## Summary

All three hot-path concerns are negligible:

| Concern | Cost per keyDown | Action |
|---|---|---|
| `latestSnapshot()` mutex read | ~10 ns uncontested lock + pointer load + ARC pair | None needed |
| `Data([...])` allocation | ~30–60 ns or free (small inline) | None needed |
| `cursorKey` switch/ternary | ~2 integer ops | None needed |
| `KeyEncoder()` construction | Zero (empty struct) | None needed |

The encoding hot path for T7 is negligible relative to the XPC round-trip that follows. No efficiency changes are recommended for this commit.
