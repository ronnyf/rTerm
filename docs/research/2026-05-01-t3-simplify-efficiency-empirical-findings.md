# T3 Efficiency Review — Empirical Findings

**Date:** 2026-05-01
**Commit:** ed1b63f
**Reviewer:** Claude Sonnet 4.6 (efficiency review pass)

---

## 1. SnapshotBox — struct-vs-class boundary still intact?

**Question:** Does `SnapshotBox` still gate `ScreenSnapshot` copies so `latestSnapshot()` copies only a pointer, not the full struct?

**Method:** Read `ScreenModel.swift` lines 97–105, 242, 563–565.

**Findings:**
- `SnapshotBox` is a `private final class` (line 99). `_latestSnapshot` is `Mutex<SnapshotBox>` (line 105).
- `publishSnapshot()` builds one `ScreenSnapshot` value and wraps it in a new `SnapshotBox(snap)` (line 242). The `withLock` replaces the box pointer, not the struct contents. One struct copy at publish time; zero copies per `latestSnapshot()` read.
- `latestSnapshot()` (line 563–565) calls `$0.snapshot` through the box — ARC retain of the box, one value-type read of `ScreenSnapshot.snapshot` (which is a `let`). The struct fields are read from the box's heap allocation, not copied.
- T3 added 4 primitive fields (3 `Bool` + 1 `UInt64`). On a 64-bit platform: 3 × 1 byte + 1 × 8 bytes = 11 bytes, padded to 16 bytes alignment within the struct. Total `ScreenSnapshot` inline payload grows by ~16 bytes but the `activeCells: ContiguousArray<Cell>` already dominates (header + buffer pointer). The new fields contribute negligible memory to the one live snapshot copy.

**Conclusion:** The SnapshotBox class boundary is intact. T3's field additions cost ~16 bytes in the heap-allocated snapshot. No regression.

---

## 2. `bellCount` mutation outside `mutateActive` — actor isolation correctness

**Question:** `bellCount &+= 1` in `handleC0(.bell)` (ScreenModel.swift:279) is called outside `mutateActive`. Is this a race?

**Method:** Checked actor declaration (line 49), `handleC0` callsite in `apply(_:)` (line 209), `bellCount` declaration (line 84).

**Findings:**
- `ScreenModel` is an `actor`. All methods called via `await` run on the actor's serial executor.
- `handleC0` is a `private func` — not `nonisolated`, so it is actor-isolated. Mutations to `bellCount` on line 279 are serialized by the actor executor.
- `bellCount` is `private var`, only read in `publishSnapshot()` (line 238) and `snapshot()` (line 530), both of which are also actor-isolated.
- `latestSnapshot()` (line 563) reads `bellCount` via the already-published `SnapshotBox`, not directly — no actor isolation required at the reader.
- There is no `nonisolated(unsafe)` anywhere in this file.

**Conclusion:** `bellCount` mutation is correctly actor-isolated. No race.

---

## 3. `handlePrintable` hot-path overhead analysis

**Question:** Does the T3 change to `handlePrintable` add measurable per-character overhead?

**Method:** Read `ScreenModel.swift` lines 247–272. Analyzed instruction count change vs pre-T3.

**Findings:**
- Pre-T3: `if buf.cursor.col >= cols { wrap }; write; col += 1`. One branch + one store.
- T3: two local captures (`pen`, `autoWrap`) before entering `mutateActive`; one additional branch (`if autoWrap || buf.cursor.col < cols - 1`) for the conditional advance.
- The `let pen = self.pen` capture is a pre-existing pattern for correctness inside the `inout` closure — not new overhead.
- `let autoWrap = modes.autoWrap` is a new scalar Bool capture: one load from the actor's heap-allocated storage, captured before the closure, then read twice inside the closure (one in the wrap branch, one in the advance guard). This is one extra load per call to `handlePrintable`.
- The advance guard `if autoWrap || buf.cursor.col < cols - 1` replaces the unconditional `col += 1`. With `autoWrap == true` (the default, normal case), the short-circuit evaluates `true` immediately and the increment executes — identical to pre-T3. With `autoWrap == false`, both sides are evaluated. Modern CPUs predict the `autoWrap == true` branch at near-100% after the first few characters.
- No allocations, no String creation, no optional unwraps on the hot path.

**Conclusion:** T3 adds one Bool load per `handlePrintable` call. Cost is ~1 extra load instruction at worst. Branch predictor handles the advance guard perfectly in the common case. No measurable regression.

---

## 4. `handleSetMode` idempotency — version bump short-circuit confirmed

**Question:** Does a no-op mode set (same value) correctly avoid bumping `version` in `apply(_:)`?

**Method:** Read `handleSetMode` (ScreenModel.swift:617–642) and `apply(_:)` (lines 202–223).

**Findings:**
- Each `handleSetMode` arm starts with `guard modes.X != enabled else { return false }`. For an idempotent set (same value), `return false` exits immediately.
- `apply(_:)` uses `changed = handleCSI(cmd) || changed` (line 211 → 382–383 → `handleSetMode`). If all events return `false`, `changed` stays `false` and `version &+= 1` / `publishSnapshot()` are skipped entirely.
- Test `test_mode_toggle_idempotent` (ScreenModelTests.swift:585) confirms this for `cursorKeyApplication`. The test checks `v1 == v2`.

**Conclusion:** Idempotent mode sets produce zero extra snapshot allocations or version bumps. Confirmed.

---

## 5. `TerminalModes` access level — `public` vs `package`

**Question:** `TerminalModes` is declared `public struct` but is only referenced within `TermCore` (no usages in `rTerm` or `rtermd`). Should it be `package` or `internal`?

**Method:**
- `rg "TerminalModes" /Users/ronny/rdev/rTerm --type swift -n` — results: only `TermCore/ScreenModel.swift` and `TermCore/TerminalModes.swift`.
- TermCore is built with `BUILD_LIBRARY_FOR_DISTRIBUTION` (Release), which enforces module stability. `public` types become part of the module interface and are binary-stable.

**Findings:**
- `TerminalModes` is not used outside TermCore. It is an implementation detail of `ScreenModel`.
- Declaring it `public` exports it in the TermCore.swiftinterface under `BUILD_LIBRARY_FOR_DISTRIBUTION`, unnecessarily enlarging the stable ABI surface.
- `package` access would make it visible within the same Swift package, but TermCore is a *framework* target (not a Swift package), so `package` resolves to intra-module only (same as `internal` for a non-package build). The correct access level is `internal` (default) or `package` if future targets in the same package need it.
- `ScreenModel.modes` is `private var` — callers never touch `TerminalModes` directly; they see individual snapshot fields instead.

**Conclusion:** `public` on `TerminalModes` is an over-exposure. Should be `internal` (or simply remove the `public` keyword). This is separate from the `@frozen` issue identified in the quality review doc.

---

## 6. `ScreenSnapshot` field ordering and alignment

**Question:** Do the 4 new fields (`cursorKeyApplication`, `bracketedPaste`, `bellCount`, `autoWrap`) affect struct layout padding significantly?

**Method:** Inspected field declaration order in `ScreenSnapshot.swift` lines 55–66.

**Findings:**
Field declaration order (relevant for alignment on 64-bit):
1. `activeCells: ContiguousArray<Cell>` — 3 words (pointer + length + capacity = 24 bytes)
2. `cols: Int` — 8 bytes
3. `rows: Int` — 8 bytes
4. `cursor: Cursor` — 2 × Int = 16 bytes
5. `cursorVisible: Bool` — 1 byte
6. `activeBuffer: BufferKind` (String raw enum) — 1 byte (raw value `String` but Swift stores enum case discriminant as Int; however `BufferKind` has 2 cases so discriminant fits in 1 byte; actual layout depends on Swift enum ABI)
7. `windowTitle: String?` — 16 bytes (Optional<String> is 2 words on 64-bit)
8. `cursorKeyApplication: Bool` — 1 byte
9. `bracketedPaste: Bool` — 1 byte
10. `bellCount: UInt64` — 8 bytes (may need 7 bytes padding after the two new Bools)
11. `autoWrap: Bool` — 1 byte
12. `version: UInt64` — 8 bytes

The snapshot is value-typed but held in a heap-allocated `SnapshotBox`. Alignment padding within the struct is the compiler's concern; no programmer action needed. The dominant cost is `activeCells: ContiguousArray<Cell>` — the extra ~24 bytes from T3 fields is noise.

**Conclusion:** Field ordering is acceptable. No actionable padding optimization.

---

## Summary

All efficiency questions resolve cleanly:
- SnapshotBox class boundary intact — pointer-copy only at `latestSnapshot()`.
- `bellCount` mutation is correctly actor-isolated — no race.
- `handlePrintable` adds one Bool load and one branch — branch-predicted to near-zero cost.
- Idempotent mode sets short-circuit before version bump — confirmed by test and code inspection.
- `TerminalModes` is `public` but only used inside TermCore — should be `internal`. (Important.)
- Struct size growth is ~16–24 bytes in a heap-allocated box — negligible.
