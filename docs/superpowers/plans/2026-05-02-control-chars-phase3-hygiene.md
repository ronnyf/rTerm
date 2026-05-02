# Control-Characters Phase 3 — Track B Hygiene Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pay down the Phase 2 engineering debt enumerated in the Phase 2 research docs so Phase 3 features do not compound regressions. Nine items: one file split (landing the ordering-invariant doc comment on `publishHistoryTail` in the same commit), one API-hardening rename, one sub-struct extraction, two test gaps, one fixture, two renderer hot-path fixes, one render-loop hoist, one measurement-gated scrollback fix.

**Architecture:** All changes are in-place refactors. No new public types cross the TermCore boundary except where explicitly noted (`Cursor.zero`, `TerminalStateSnapshot` nested type, deprecated-then-new `ScreenModel.init(..., queue: DispatchSerialQueue?)`). No wire-format changes — `ScreenSnapshot` Codable stays byte-identical. Measurement-gated tasks use `os_signpost` + XCTest `measure` blocks; Metal frame-capture and Instruments-only paths are off-table.

**Tech Stack:** Swift 6, Swift Testing (`@Test` / `#expect`) for unit tests, XCTest (`XCTestCase` + `measure`) only where `XCTMetric.wallClockTime` or allocation counters are needed for perf baselines. Metal (`MTKView`), `os.signpost` (`import os` + `OSSignposter`), `Synchronization.Mutex`.

**Execution contract:** Identical to Phase 1 + Phase 2 plans.
- Every implementer task ends with `git commit`. Implementers do not run `xcodebuild`.
- Implementer-facing checkboxes that mention build/test commands are documentation for the controller's verification pass. The implementer's real work is: write test → write impl → commit.
- After each commit, the controller dispatches `agentic:xcode-build-reporter` to run the relevant tests and verify a clean build.
- If the report shows failures, the controller re-dispatches the implementer with a fix-focused prompt.
- After the build reporter passes, the controller dispatches spec-compliance and code-quality reviewers per `superpowers:subagent-driven-development`. Only then is the task marked complete and `/simplify` is invoked before the next task.

`xcodebuild` commands assume the repo root working directory.

---

## Task 0: Test infrastructure prerequisite — `TermCoreTests/TestHelpers.swift`

**Spec reference:** simplify-review recommendation §4 Reuse #1 (LockedAccumulator) + simplify-review §2.3 Efficiency #3 (escape-sequence helpers).

**Goal:** Land one shared test-helpers file up front so every downstream Track A + Track B task that needs a lock-protected spy or a hand-assembled `[UInt8]` escape sequence references a single canonical helper instead of duplicating `@unchecked Sendable` boilerplate. Previously `UnsafeBytesCollector`, `DataSink`, `ClipboardSpy`, `AtomicBool` each appeared as near-identical private classes in 4+ test files; the OSC / CSI byte arrays were hand-assembled with `+ Array("payload".utf8) +` splices everywhere.

**Files:**
- Create: `TermCoreTests/TestHelpers.swift`

### Steps

- [ ] **Step 1: Create `TermCoreTests/TestHelpers.swift`**

```swift
//
//  TestHelpers.swift
//  TermCoreTests
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//
//  Shared test-helper scaffolding. Lock-protected accumulator replaces
//  the per-test UnsafeBytesCollector / DataSink / ClipboardSpy / AtomicBool
//  classes that otherwise duplicate across tasks. Byte-level helpers
//  (Data.csi, Data.osc) replace hand-assembled [UInt8] escape-sequence
//  literals in parser / writeback tests, eliminating off-by-one risk from
//  mid-sequence .utf8 splices.
//

import Foundation

/// Lock-protected accumulator used by every test that spies on a
/// `@Sendable` callback. One generic replaces the four hand-written
/// spies that otherwise repeat the same NSLock body.
public final class LockedAccumulator<T>: @unchecked Sendable {
    private var items: [T] = []
    private let lock = NSLock()

    public init() {}

    public func append(_ item: T) {
        lock.lock(); defer { lock.unlock() }
        items.append(item)
    }

    public func all() -> [T] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    public func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return items.count
    }
}

/// Specialization convenience — the most common shape is a `Data` sink
/// that concatenates writes into one contiguous blob.
public final class DataSink: @unchecked Sendable {
    private var buf = Data()
    private let lock = NSLock()
    public init() {}
    public func append(_ more: Data) {
        lock.lock(); defer { lock.unlock() }
        buf.append(more)
    }
    public func all() -> Data {
        lock.lock(); defer { lock.unlock() }
        return buf
    }
}

/// Atomic-bool replacement for the ad-hoc class in Track B Task 1's
/// `RestoreOrderingTests`. Semantics: a lock-gated boolean that is safe
/// to read/write from arbitrary Task contexts.
public final class AtomicBool: @unchecked Sendable {
    private var value: Bool
    private let lock = NSLock()
    public init(value: Bool) { self.value = value }
    public func load() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    public func store(_ new: Bool) {
        lock.lock(); defer { lock.unlock() }
        value = new
    }
}

// MARK: - Byte-level escape-sequence helpers

public extension Data {
    /// Build a CSI sequence from its parameter+final body. `body` is the
    /// text that follows `ESC [`, e.g. `"?1;2c"` for DA1 response,
    /// `"6n"` for CPR, `"32m"` for an SGR. Prepends the two lead bytes
    /// (ESC, `[`) and encodes the body as ASCII.
    ///
    /// Intent-revealing: `Data.csi("?1;2c")` reads as "CSI ? 1 ; 2 c",
    /// not `Data([0x1B, 0x5B, 0x3F, 0x31, 0x3B, 0x32, 0x63])`.
    static func csi(_ body: String) -> Data {
        var d = Data([0x1B, 0x5B])
        d.append(contentsOf: body.utf8)
        return d
    }

    /// Build an OSC sequence with ST (ESC \) terminator.
    /// `ps` is the numeric parameter (0..=1999); `pt` is the text
    /// payload that follows the semicolon. `Data.osc(8, "id=A;http://x")`
    /// → `ESC ] 8 ; id=A;http://x ESC \`.
    static func osc(_ ps: Int, _ pt: String) -> Data {
        var d = Data([0x1B, 0x5D])
        d.append(contentsOf: String(ps).utf8)
        d.append(0x3B)
        d.append(contentsOf: pt.utf8)
        d.append(contentsOf: [0x1B, 0x5C])
        return d
    }
}
```

- [ ] **Step 2: Add the file to the TermCoreTests target in Xcode**

Drag into the TermCoreTests group, confirm target membership = TermCoreTests only. No pbxproj hand-editing.

- [ ] **Step 3: Commit**

```bash
git add TermCoreTests/TestHelpers.swift rTerm.xcodeproj/project.pbxproj
git commit -m "test(TermCoreTests): shared test helpers (LockedAccumulator, Data.csi/osc)

Land one file up front so downstream Phase 3 Track A + Track B tasks
that need a lock-protected spy or a hand-assembled escape sequence
reference a single canonical helper rather than duplicating
@unchecked Sendable boilerplate or re-deriving byte-array offsets:

- LockedAccumulator<T> generic — replaces the UnsafeBytesCollector /
  DataSink / ClipboardSpy / AtomicBool per-test private classes that
  otherwise repeat the same NSLock body in 4+ files.
- DataSink typealias-style specialization for Data concatenation.
- AtomicBool for the few remaining bool-spin cases.
- Data.csi(String) / Data.osc(Int, String) — intent-revealing
  factories so parser/writeback tests read as 'CSI ? 1 ; 2 c' rather
  than [0x1B, 0x5B, 0x3F, 0x31, 0x3B, 0x32, 0x63]. Eliminates the
  off-by-one risk present in OSC tests with mid-sequence .utf8
  splices."
```

---

## Task 1: Test gap — `AttributeProjection.atlasVariant` invariance + `restore(from payload:)` ordering test

**Spec reference:** §8 Track B item 12 (test gaps).

**Goal:** Two test additions:

1. **`AttributeProjection.atlasVariant` invariance:** prove that non-atlas attributes (`.dim`, `.underline`, `.blink`, `.strikethrough`, `.reverse`) do not change which atlas variant is selected. The existing 6-case test asserts the mapping; this adds the invariance assertion.

2. **`restore(from payload:)` clear-before-publish ordering:** integration test with a concurrent reader that spins on both `latestSnapshot()` and `latestHistoryTail()` while `restore(from payload:)` runs. Asserts the reader never observes a stale history tail alongside a fresh live snapshot.

**Files:**
- Modify: `rTermTests/AttributeProjectionTests.swift`
- Create: `TermCoreTests/RestoreOrderingTests.swift`

### Steps

- [ ] **Step 1: Add invariance test to `AttributeProjectionTests.swift`**

Add to the existing `AttributeProjectionTests` suite:

```swift
@Test("atlasVariant is invariant to non-atlas attributes")
func test_atlasVariant_invariant_to_non_atlas_attributes() {
    // Atlas variant depends only on .bold and .italic. Every other
    // attribute must be irrelevant to the variant selection — the
    // renderer composites them via shader uniforms, not by picking
    // a different glyph atlas.
    let atlasOnlyCombos: [CellAttributes] = [
        [],
        [.bold],
        [.italic],
        [.bold, .italic],
    ]
    let noisyAttributes: [CellAttributes] = [
        .dim, .underline, .blink, .reverse, .strikethrough,
        [.dim, .underline],
        [.dim, .underline, .blink, .reverse, .strikethrough],
    ]
    for base in atlasOnlyCombos {
        let baseVariant = AttributeProjection.atlasVariant(for: base)
        for noise in noisyAttributes {
            let combined = base.union(noise)
            let variant = AttributeProjection.atlasVariant(for: combined)
            #expect(variant == baseVariant,
                    "noise=\(noise.rawValue) must not change atlas variant from base=\(base.rawValue)")
        }
    }
}
```

- [ ] **Step 2: Create `TermCoreTests/RestoreOrderingTests.swift`**

```swift
//
//  RestoreOrderingTests.swift
//  TermCoreTests
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

import Foundation
import Testing
@testable import TermCore

/// Verifies the history-tail-cleared-before-snapshot-restored ordering in
/// `ScreenModel.restore(from payload:)`. A concurrent reader that reads both
/// `latestSnapshot()` and `latestHistoryTail()` in any order must never observe
/// a stale-history-tail alongside a freshly-restored live snapshot, because
/// such a state would briefly composite the old scrollback above the new grid.
@Suite("restore(from payload:) ordering")
struct RestoreOrderingTests {

    @Test("concurrent reader sees no stale-history / fresh-snapshot window")
    func test_restore_ordering_has_no_stale_history_window() async {
        let cols = 80, rows = 24
        let model = ScreenModel(cols: cols, rows: rows, historyCapacity: 10_000)

        // Pre-populate history with recognizable rows.
        for i in 0..<500 {
            await model.apply([.printable(Character(UnicodeScalar(0x41 + (i % 26))!))])
            await model.apply([.c0(.lineFeed)])
        }
        let firstTailSample = model.latestHistoryTail()
        #expect(firstTailSample.count > 0, "sanity: history must be non-empty before restore")

        // Build a fresh payload whose snapshot dimensions match but whose
        // content is completely different (all 'Z' cells, empty history).
        let resetCells = ContiguousArray<Cell>(
            repeating: Cell(character: "Z"),
            count: cols * rows)
        let freshSnapshot = ScreenSnapshot(
            activeCells: resetCells,
            cols: cols,
            rows: rows,
            cursor: Cursor(row: 0, col: 0),
            version: 9999)
        let freshPayload = AttachPayload(
            snapshot: freshSnapshot,
            recentHistory: [],
            historyCapacity: 10_000)

        // Spin a concurrent reader. It records every (snapshot, historyTail)
        // pair it observes. After restore runs, no pair may show
        // "history non-empty AND snapshot.version == 9999" — that would be
        // the stale-history-above-new-grid incoherence window.
        actor Violations {
            var count = 0
            func record() { count += 1 }
            func get() -> Int { count }
        }
        let violations = Violations()
        let stop = AtomicBool(value: false)

        let readerTask = Task.detached(priority: .userInitiated) {
            while !stop.load() {
                let tail = model.latestHistoryTail()
                let snap = model.latestSnapshot()
                if snap.version == 9999, !tail.isEmpty {
                    await violations.record()
                }
            }
        }

        // Let the reader loop spin for a moment before restore so its
        // schedule is warm.
        try? await Task.sleep(nanoseconds: 10_000_000)

        await model.restore(from: freshPayload)

        // Keep reading briefly after restore to catch any lagging
        // publication window.
        try? await Task.sleep(nanoseconds: 50_000_000)

        stop.store(true)
        _ = await readerTask.value

        let got = await violations.get()
        #expect(got == 0, "observed \(got) stale-history / fresh-snapshot windows")
    }
}

// `AtomicBool` above comes from `TermCoreTests/TestHelpers.swift` (Task 0).
// No per-file copy is needed.
```

- [ ] **Step 3: Run new tests**

```bash
xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests \
    -only-testing TermCoreTests/RestoreOrderingTests test -quiet
xcodebuild -project rTerm.xcodeproj -scheme rTermTests \
    -only-testing rTermTests/AttributeProjectionTests/test_atlasVariant_invariant_to_non_atlas_attributes \
    test -quiet
```

Expected: both pass. If the ordering test flakes (unlikely — the ordering is firm), increase the post-restore sleep to 200 ms.

- [ ] **Step 4: Commit**

```bash
git add rTermTests/AttributeProjectionTests.swift \
        TermCoreTests/RestoreOrderingTests.swift
git commit -m "test(phase3): atlasVariant invariance + restore ordering window

Pin two Phase 2 research-doc test gaps:

1. AttributeProjection.atlasVariant must depend only on .bold and
   .italic. A noise-attribute invariance test guards against a future
   refactor that accidentally routes dim/underline/blink/reverse/
   strikethrough through the atlas selector.

2. ScreenModel.restore(from payload:) clears the history tail before
   publishing the new snapshot. A concurrent reader spinning on both
   nonisolated mutexes must never observe the stale-history /
   fresh-snapshot coherence window."
```

---

## Task 2: `top`/`htop` integration fixture

**Spec reference:** §8 Track B item 12c; Phase 2 final review Q7 "behavioral gaps" (deferred fixture).

**Goal:** Add a fourth fixture to `TerminalIntegrationTests.swift` exercising the alt-screen enter/exit pattern that `top` and `htop` share (DEC 1049 + DECSTBM + cursor positioning + SGR + partial-screen repaint + DEC 1049 exit restoring main buffer). Verifies the cross-task alt-screen plumbing end-to-end on a realistic byte stream.

**Files:**
- Modify: `TermCoreTests/TerminalIntegrationTests.swift`

### Steps

- [ ] **Step 1: Capture a representative `top`-style byte stream**

Use the existing fixture structure. The sequence should:
1. Save cursor + switch to alt + clear: `ESC [ ? 1049 h`
2. Clear screen: `ESC [ 2 J`
3. Move cursor home: `ESC [ H`
4. Draw a header row in bold reverse: `ESC [ 1 ; 7 m` + text + `ESC [ 0 m`
5. Move to row 2: `ESC [ 2 ; 1 H`
6. Set a scroll region: `ESC [ 3 ; 22 r`
7. Write 5 process-line rows with SGR color cycling
8. Move cursor back home, then partial repaint of row 3 (the "refresh tick")
9. Exit alt: `ESC [ ? 1049 l`

- [ ] **Step 2: Add the fixture + test**

**Assertion design note:** split the byte stream into enter + exit halves so the test can assert (a) alt was entered, (b) the alt grid holds the shell-drawn content, AND (c) exit restores main with the main content intact. A single `model.apply(events)` call asserting only `activeBuffer == .main` at the end would admit a buggy handler that treats `1049 h`/`1049 l` as no-ops — both enter and exit become no-ops, the shell's content goes to main, and the end state still satisfies `.main`.

Append to `TerminalIntegrationTests.swift`:

```swift
@Test("top-like alt-screen pattern lands on alt, clears region, restores main on exit")
func top_like_pattern_round_trips_alt_screen() async {
    let model = ScreenModel(cols: 80, rows: 24)

    // Pre-fill main with a recognizable marker so alt-exit restoration
    // is visible in assertions.
    for _ in 0..<5 {
        await model.apply([
            .printable("M"), .printable("A"), .printable("I"), .printable("N"),
            .c0(.lineFeed), .c0(.carriageReturn),
        ])
    }
    let beforeAlt = model.latestSnapshot()
    #expect(beforeAlt.activeBuffer == .main)
    #expect(beforeAlt[0, 0].character == "M")

    // --- Part 1: alt enter + draw (everything before 1049 exit). ---
    var enterBytes: [UInt8] = []
    // ESC [ ? 1049 h  — save main cursor, swap to alt, clear alt
    enterBytes += [0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x68]
    // ESC [ 2 J  — erase in display, all
    enterBytes += [0x1B, 0x5B, 0x32, 0x4A]
    // ESC [ H  — cursor to 1;1
    enterBytes += [0x1B, 0x5B, 0x48]
    // Bold + reverse header row
    enterBytes += [0x1B, 0x5B, 0x31, 0x3B, 0x37, 0x6D]        // ESC [ 1 ; 7 m
    enterBytes += Array("PID   USER   CPU%".utf8)
    enterBytes += [0x1B, 0x5B, 0x30, 0x6D]                    // ESC [ 0 m
    // Move to row 2: ESC [ 2 ; 1 H
    enterBytes += [0x1B, 0x5B, 0x32, 0x3B, 0x31, 0x48]
    // DECSTBM: ESC [ 3 ; 22 r
    enterBytes += [0x1B, 0x5B, 0x33, 0x3B, 0x32, 0x32, 0x72]
    // 5 colored process rows
    for i in 0..<5 {
        enterBytes += [0x1B, 0x5B, 0x33, 0x32, 0x6D]           // ESC [ 32 m (green)
        let line = "proc\(i)  alice   1.\(i)%"
        enterBytes += Array(line.utf8)
        enterBytes += [0x0D, 0x0A]
    }
    // Partial repaint: cursor to row 3 col 1, overwrite with "*"
    enterBytes += [0x1B, 0x5B, 0x33, 0x3B, 0x31, 0x48]
    enterBytes += [0x2A]

    var parser = TerminalParser()
    let enterEvents = parser.parse(Data(enterBytes))
    await model.apply(enterEvents)

    // Assert we actually landed on alt and the shell's content is there.
    let mid = model.latestSnapshot()
    #expect(mid.activeBuffer == .alt, "1049 h must swap to alt buffer")
    #expect(mid[0, 0].character == "P", "header row 'P' from 'PID ...' must be on alt")
    #expect(mid[2, 0].character == "*", "partial repaint '*' must be at row 3 col 1 of alt")

    // --- Part 2: exit alt. ---
    // ESC [ ? 1049 l
    var exitBytes: [UInt8] = [0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x6C]
    let exitEvents = parser.parse(Data(exitBytes))
    await model.apply(exitEvents)

    let after = model.latestSnapshot()
    #expect(after.activeBuffer == .main, "1049 l must restore main")
    #expect(after[0, 0].character == "M")
    #expect(after[0, 1].character == "A")
    #expect(after[0, 2].character == "I")
    #expect(after[0, 3].character == "N")
}
```

- [ ] **Step 3: Run the integration test**

```bash
xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests \
    -only-testing TermCoreTests/TerminalIntegrationTests/top_like_pattern_round_trips_alt_screen \
    test -quiet
```

Expected: pass. If the active-buffer assertion fails on exit, inspect `handleAltScreen(.alternateScreen1049, enabled: false)` — the Phase 2 T4 alt-screen handler correction should restore main.

- [ ] **Step 4: Commit**

```bash
git add TermCoreTests/TerminalIntegrationTests.swift
git commit -m "test(phase3): top/htop alt-screen round-trip fixture

Fourth integration fixture, capping the Phase 2 deferred fixture
corpus. Exercises DEC 1049 enter + full-screen erase + DECSTBM +
SGR cycling + partial repaint + 1049 exit restoring main. Verifies
the alt-screen plumbing reassembles a realistic 'top' byte stream
end-to-end."
```

---

## Task 3: `ScreenModel.swift` file split

**Spec reference:** §8 Track B item 5.

**Goal:** `TermCore/ScreenModel.swift` is 941 lines with 10 logical sections. Split into three files linked by Swift extensions. Only **methods** move to the extension files; stored properties and types stay on the main declaration. Access levels do NOT change — this is a pure physical split.

**Access-control rules (single prescription — no mid-plan revisions):**

1. **Stored properties stay in `ScreenModel.swift`** on the actor's main declaration. Swift forbids stored properties on extensions, so `_latestHistoryTail`, `pendingHistoryPublish`, `main`, `alt`, `activeKind`, `pen`, `modes`, `bellCount`, `history`, `_latestSnapshot`, etc. all remain where they are.

2. **Types stay in `ScreenModel.swift`.** `ScrollRegion` (file-scope `private struct`, line 29), `Buffer` (actor-nested `private struct`, line 154), `SnapshotBox` (actor-nested `private final class`, line 99), `HistoryBox` (actor-nested `private final class`, line 119) all remain where they are. Keeping them in the main file means they stay nested-private inside the actor and there is NO access-level change to reason about.

3. **Only methods move.** Extensions in Swift can reference the enclosing type's private stored properties and private nested types, as long as the extension is **in the same module** (TermCore is one module; `fileprivate` would fail, but `private`-to-module visibility works transparently from same-module extensions). Moving a method to `ScreenModel+Buffer.swift` does not require any visibility change on `Buffer` or `ScrollRegion`.

4. **Caveat — `private` vs `fileprivate`:** Swift does NOT allow an extension in File B to access a symbol declared `private` in File A. Because `ScrollRegion` is `private` (file-scope in `ScreenModel.swift`), any method that references `ScrollRegion` as a type name **cannot** move to `ScreenModel+Buffer.swift`. Methods that only touch `ScrollRegion` via `buf.scrollRegion` (where `buf: Buffer` already carries the field) DO work — they don't name `ScrollRegion` directly. Check each candidate method for direct `ScrollRegion` type references before moving.

5. **If a method must move that names `ScrollRegion` directly:** the minimal fix is to promote `ScrollRegion` from `private` to `internal` (leave it file-scoped). `internal` is module-wide; tests and the TermCore umbrella header don't re-export it (that is a separate concern — TermCore.h controls Objective-C re-export, which Swift-only types don't participate in). Narrate this choice at the top of the moved method with a one-line comment.

**File layout:**
- `TermCore/ScreenModel.swift` — actor declaration, stored properties, nested types (`Buffer`, `ScrollRegion`, `SnapshotBox`, `HistoryBox`), `init`, `apply(_:)`, `publishSnapshot`, `makeSnapshot(from:)`, event dispatchers (`handlePrintable`, `handleC0`, `handleCSI`, `applySGR`, `handleOSC`), `eraseInDisplay`, `eraseInLine`, `handleSetMode`, `handleSetScrollRegion`, `handleAltScreen`, `snapshotCursor`, `restoreActiveCursor`, `latestSnapshot()`, `snapshot()`, `applyAndCurrentTitle()`, `currentWindowTitle()`, `currentIconName()`.
- `TermCore/ScreenModel+Buffer.swift` — methods only: `mutateActive<R>`, the `active` computed property, `scrollAndMaybeEvict` (static), `clearGrid` (static). `Buffer` and `ScrollRegion` stay in `ScreenModel.swift`.
- `TermCore/ScreenModel+History.swift` — methods only: `publishHistoryTail()`, `buildAttachPayload()` (nonisolated), `latestHistoryTail()` (nonisolated), `restore(from snapshot:)`, `restore(from payload:)`.

**Files:**
- Modify: `TermCore/ScreenModel.swift` (trim moved methods)
- Create: `TermCore/ScreenModel+Buffer.swift`
- Create: `TermCore/ScreenModel+History.swift`
- Modify: `rTerm.xcodeproj/project.pbxproj` (add new files to TermCore target — use Xcode GUI; do not hand-edit pbxproj)

### Steps

- [ ] **Step 1: Audit method references to file-private types**

Before moving any method, grep each candidate for direct references to `ScrollRegion` (the file-private type):

```bash
rg -n "\\bScrollRegion\\b" TermCore/ScreenModel.swift
```

Methods that name `ScrollRegion` directly (e.g., in a parameter type) cannot move without first promoting the type. Methods that only touch `buf.scrollRegion` (field access via a `Buffer`-typed value) move cleanly.

Expected state based on the current ScreenModel.swift:
- `scrollAndMaybeEvict` reads `buf.scrollRegion` but does not name `ScrollRegion` — moves cleanly.
- `clearGrid` does not touch `scrollRegion` — moves cleanly.
- `mutateActive<R>` and the `active` computed property do not name `ScrollRegion` — move cleanly.
- `handleSetScrollRegion(top:bottom:)` constructs a `ScrollRegion(top:bottom:)` literal — it STAYS in `ScreenModel.swift` (it does not belong to the Buffer extension anyway; it's an event dispatcher).

No type promotion is needed. Access levels do not change in this task.

- [ ] **Step 2: Create `ScreenModel+Buffer.swift`**

```swift
//
//  ScreenModel+Buffer.swift
//  TermCore
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//
//  Split from ScreenModel.swift in Phase 3 Track B (item 5): buffer /
//  grid-mutation helpers. Types (Buffer, ScrollRegion) and stored
//  properties remain in ScreenModel.swift; only methods move here.
//  Same-module extensions see the actor's private storage and nested
//  types transparently — access levels are unchanged.
//

import Foundation

extension ScreenModel {
    // Paste the exact original definitions of:
    //   private func mutateActive<R>(_ body: (inout Buffer) -> R) -> R
    //   private var active: Buffer
    //   private static func scrollAndMaybeEvict(in buf: inout Buffer, cols: Int, rows: Int, isMain: Bool) -> ScrollbackHistory.Row?
    //   private static func clearGrid(in buf: inout Buffer, cols: Int, rows: Int)
    // here, without any code or access-level change.
}
```

- [ ] **Step 3: Create `ScreenModel+History.swift`**

```swift
//
//  ScreenModel+History.swift
//  TermCore
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//
//  Split from ScreenModel.swift in Phase 3 Track B (item 5): scrollback
//  history publication and restore-from-payload concerns. Stored
//  properties (_latestHistoryTail, pendingHistoryPublish) and types
//  (HistoryBox) remain on the actor's main declaration — Swift forbids
//  stored properties on extensions. Only methods move.
//

import Foundation
import Synchronization

extension ScreenModel {
    // Paste the exact original definitions of:
    //   private func publishHistoryTail()
    //   nonisolated public func latestHistoryTail() -> ContiguousArray<ScrollbackHistory.Row>
    //   nonisolated public func buildAttachPayload() -> AttachPayload
    //   public func restore(from snapshot: ScreenSnapshot)
    //   public func restore(from payload: AttachPayload)
    // here, without any code or access-level change.
}
```

**Attach the ordering-invariant doc comment to `publishHistoryTail()` as part of the move (spec §8 Track B item 8).** Immediately above the moved `publishHistoryTail()` declaration, insert:

```swift
/// Publish a fresh history-tail snapshot to the `_latestHistoryTail`
/// mutex for nonisolated render-thread reads.
///
/// **Ordering invariant — callers must preserve this.** Inside
/// `apply(_:)` and `restore(from payload:)`, `publishHistoryTail()` runs
/// *before* `publishSnapshot()` (on the apply side) and *before*
/// `_latestSnapshot.withLock { … }` (on the restore side). The reason:
/// a renderer reading both nonisolated mutexes between the two calls
/// must not observe a snapshot newer than the history tail, because
/// that would briefly composite a stale history tail above a freshly-
/// cleared grid (ghost-row effect). Publishing history first means the
/// worst observable state is a briefly-duplicate row at scrollOffset
/// > 0, which is visually benign. Inverting the two calls breaks the
/// invariant silently — there is no compile-time check.
///
/// If a third publish channel is added in a future phase, it must
/// decide its own ordering against both existing mutexes and document
/// it here.
```

While here, re-verify ordering at the two call sites: in `apply(_:)` (ScreenModel.swift) `publishHistoryTail()` must be called before `publishSnapshot()`; in `restore(from payload:)` (ScreenModel+History.swift) `_latestHistoryTail.withLock` clearing must happen before `_latestSnapshot.withLock` restoration. If either site has been accidentally inverted, correct it as part of this same commit. `RestoreOrderingTests` (Task 1) remains the guardrail.

- [ ] **Step 4: Trim `ScreenModel.swift`**

Delete the moved method bodies from the original file. What remains: stored properties, nested types (`Buffer`, `ScrollRegion`, `SnapshotBox`, `HistoryBox`), `init`, `apply(_:)`, `publishSnapshot`, `makeSnapshot(from:)`, all event dispatchers (`handlePrintable`, `handleC0`, `handleCSI`, `applySGR`, `handleOSC`), `eraseInDisplay`, `eraseInLine`, `handleSetMode`, `handleSetScrollRegion`, `handleAltScreen`, `snapshotCursor`, `restoreActiveCursor`, `latestSnapshot()`, `snapshot()`, `applyAndCurrentTitle()`, `currentWindowTitle()`, `currentIconName()`, `clampCursor(in:)`.

- [ ] **Step 5: Add the two new files to the TermCore target in Xcode**

Open the project in Xcode, drag the two new files into the TermCore group, confirm target membership = TermCore only. Xcode writes the pbxproj changes. Do NOT hand-edit pbxproj — it is error-prone and the "subagent" workflow is not available in this harness. If the implementer has no Xcode access, stop and request one.

- [ ] **Step 6: Build the full project**

```bash
xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build -quiet
```

Expected: clean build. If a visibility error surfaces, it means a method referenced a file-private type directly — Step 1's audit missed it. Move that method back to `ScreenModel.swift` or (last resort) promote the type from `private` to `internal` with an explicit rationale comment.

- [ ] **Step 7: Run the full test suite**

```bash
xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test -quiet
```

Expected: all 222 existing TermCore tests pass. No behavior changed — this is a pure file split.

- [ ] **Step 8: Verify line counts**

```bash
wc -l TermCore/ScreenModel.swift TermCore/ScreenModel+Buffer.swift TermCore/ScreenModel+History.swift
```

Expected: `ScreenModel.swift` ~650–700 lines; `+Buffer` ~80–130; `+History` ~100–150. If any file is unexpectedly large, revisit the split boundary.

- [ ] **Step 9: Commit**

```bash
git add TermCore/ScreenModel.swift \
        TermCore/ScreenModel+Buffer.swift \
        TermCore/ScreenModel+History.swift \
        rTerm.xcodeproj/project.pbxproj
git commit -m "refactor(TermCore): split ScreenModel into +Buffer and +History

ScreenModel.swift at 941 lines with 10 logical sections. Split into:

- ScreenModel.swift: event dispatch, apply(_:), publishSnapshot,
  makeSnapshot, handleCSI/C0/SGR/OSC, mode/scroll-region/alt-screen
  handlers, stored properties, init, nested types (Buffer, ScrollRegion,
  SnapshotBox, HistoryBox).
- ScreenModel+Buffer.swift: mutateActive<R>, active computed, static
  scrollAndMaybeEvict, static clearGrid.
- ScreenModel+History.swift: publishHistoryTail, buildAttachPayload,
  latestHistoryTail, restore(from:) x2 — publishHistoryTail gains the
  history-before-snapshot ordering-invariant doc comment (spec §8
  Track B item 8) as the method moves.

Pure physical split — no access-level changes. Swift forbids stored
properties on extensions, so all stored state stays on the actor's
main declaration. Types stay in ScreenModel.swift so 'private'
visibility never needs to change; same-module extensions see the
actor's private storage and nested types transparently.

No behavior change. Payoff: future Phase 3 handlers and history
operations land in the file that already owns their concern."
```

---

## Task 4: `TerminalStateSnapshot` extraction + `Cursor.zero`

**Spec reference:** §8 Track B items 4 and 9.

**Goal:** Reduce `ScreenSnapshot`'s 12-param init by grouping the 7 terminal-state fields into a nested `TerminalState` struct. Call sites inside TermCore use the sub-struct for tidier construction; public readers continue to access flat fields unchanged. Codable stays byte-identical (wire format unchanged — fields remain flat in JSON).

Also add `Cursor.zero` / `.origin` static to replace the 4 inline `Cursor(row: 0, col: 0)` sites in `ScreenModel.swift` and `ScreenModel+Buffer.swift`.

**Files:**
- Modify: `TermCore/ScreenSnapshot.swift`
- Modify: `TermCore/ScreenModel.swift`, `TermCore/ScreenModel+Buffer.swift` (use `.zero`, use convenience init)

### Steps

- [ ] **Step 1: Add `Cursor.zero` static**

In `TermCore/ScreenSnapshot.swift`, inside the `Cursor` struct:

```swift
/// Origin cursor (row 0, col 0). Equivalent to `Cursor(row: 0, col: 0)`
/// but spelled as a single identifier where construction is boilerplate.
public static let zero = Cursor(row: 0, col: 0)
```

- [ ] **Step 2: Add `TerminalState` nested type + convenience init**

In `TermCore/ScreenSnapshot.swift`, add inside `ScreenSnapshot`:

```swift
/// Grouping of the 7 terminal-state fields used purely for tidier
/// construction. Readers still access fields directly on
/// `ScreenSnapshot` (the flat fields remain first-class); wire format
/// (Codable) is unchanged — fields decode/encode at the snapshot top
/// level, not nested under a "terminalState" key.
public struct TerminalState: Sendable, Equatable {
    public var cursorVisible: Bool
    public var activeBuffer: BufferKind
    public var windowTitle: String?
    public var cursorKeyApplication: Bool
    public var bracketedPaste: Bool
    public var bellCount: UInt64
    public var autoWrap: Bool

    public init(cursorVisible: Bool = true,
                activeBuffer: BufferKind = .main,
                windowTitle: String? = nil,
                cursorKeyApplication: Bool = false,
                bracketedPaste: Bool = false,
                bellCount: UInt64 = 0,
                autoWrap: Bool = true) {
        self.cursorVisible = cursorVisible
        self.activeBuffer = activeBuffer
        self.windowTitle = windowTitle
        self.cursorKeyApplication = cursorKeyApplication
        self.bracketedPaste = bracketedPaste
        self.bellCount = bellCount
        self.autoWrap = autoWrap
    }
}

/// Convenience init that accepts a `TerminalState` bundle. Flat fields
/// are copied out; Codable behavior (in/out) is unchanged.
public init(activeCells: ContiguousArray<Cell>,
            cols: Int,
            rows: Int,
            cursor: Cursor,
            terminalState: TerminalState,
            version: UInt64) {
    self.init(activeCells: activeCells,
              cols: cols,
              rows: rows,
              cursor: cursor,
              cursorVisible: terminalState.cursorVisible,
              activeBuffer: terminalState.activeBuffer,
              windowTitle: terminalState.windowTitle,
              cursorKeyApplication: terminalState.cursorKeyApplication,
              bracketedPaste: terminalState.bracketedPaste,
              bellCount: terminalState.bellCount,
              autoWrap: terminalState.autoWrap,
              version: version)
}

/// Read the snapshot's terminal-state fields as a grouped bundle. Useful
/// when a caller wants to pass them together (e.g., reconstructing a
/// `ScreenModel` from a payload).
public var terminalState: TerminalState {
    TerminalState(cursorVisible: cursorVisible,
                  activeBuffer: activeBuffer,
                  windowTitle: windowTitle,
                  cursorKeyApplication: cursorKeyApplication,
                  bracketedPaste: bracketedPaste,
                  bellCount: bellCount,
                  autoWrap: autoWrap)
}
```

Do **not** change the existing 12-param init signature — callers outside TermCore may rely on it and removing it is a source break. Keep both. The convenience init is additive.

- [ ] **Step 3: Migrate `ScreenModel.makeSnapshot(from:)` to use the convenience init**

Open `TermCore/ScreenModel.swift`. Find `makeSnapshot(from:)`. Its current body constructs `ScreenSnapshot` using the 12-param init. Rewrite to build a `ScreenSnapshot.TerminalState` first, then use the convenience init:

```swift
private func makeSnapshot(from buf: Buffer) -> ScreenSnapshot {
    let terminalState = ScreenSnapshot.TerminalState(
        cursorVisible: modes.cursorVisible,
        activeBuffer: activeKind,
        windowTitle: windowTitle,
        cursorKeyApplication: modes.cursorKeyApplication,
        bracketedPaste: modes.bracketedPaste,
        bellCount: bellCount,
        autoWrap: modes.autoWrap)
    return ScreenSnapshot(
        activeCells: buf.grid,
        cols: cols,
        rows: rows,
        cursor: snapshotCursor(buf: buf),
        terminalState: terminalState,
        version: snapshotVersion)
}
```

- [ ] **Step 4: Migrate `Cursor(row: 0, col: 0)` sites**

In `TermCore/ScreenModel.swift` and `TermCore/ScreenModel+Buffer.swift`, grep for `Cursor(row: 0, col: 0)`. There are at least 2 sites (init and 1049 enter); the exact count is 3–4. Replace each with `Cursor.zero`.

```bash
rg -n "Cursor\(row: 0, col: 0\)" TermCore/
```

Edit each hit. Visual diff should show the rename only, nothing else.

- [ ] **Step 5: Add a test for the convenience init + `.zero`**

Append to `TermCoreTests/CodableTests.swift` (or add to a new `ScreenSnapshotInitTests.swift` if it reads cleaner):

```swift
@Test("Convenience init with TerminalState produces same snapshot as flat init")
func test_convenience_init_equivalent_to_flat() {
    let cells = ContiguousArray<Cell>(repeating: Cell(character: "x"), count: 2)
    let state = ScreenSnapshot.TerminalState(
        cursorVisible: false,
        activeBuffer: .alt,
        windowTitle: "hi",
        cursorKeyApplication: true,
        bracketedPaste: true,
        bellCount: 7,
        autoWrap: false)
    let viaConvenience = ScreenSnapshot(
        activeCells: cells, cols: 2, rows: 1,
        cursor: Cursor.zero,
        terminalState: state,
        version: 42)
    let viaFlat = ScreenSnapshot(
        activeCells: cells, cols: 2, rows: 1,
        cursor: Cursor.zero,
        cursorVisible: false,
        activeBuffer: .alt,
        windowTitle: "hi",
        cursorKeyApplication: true,
        bracketedPaste: true,
        bellCount: 7,
        autoWrap: false,
        version: 42)
    #expect(viaConvenience == viaFlat)
    #expect(viaConvenience.terminalState == state)
}

@Test("Codable wire format unchanged by TerminalState extraction")
func test_codable_roundtrip_flat_after_extraction() throws {
    let cells = ContiguousArray<Cell>(repeating: Cell(character: "A"), count: 4)
    let snap = ScreenSnapshot(
        activeCells: cells, cols: 2, rows: 2,
        cursor: Cursor.zero,
        terminalState: ScreenSnapshot.TerminalState(cursorVisible: true, autoWrap: false),
        version: 1)
    let data = try JSONEncoder().encode(snap)
    let json = String(data: data, encoding: .utf8)!
    // Flat fields must still be at the top level — no "terminalState" key.
    #expect(!json.contains("\"terminalState\""))
    #expect(json.contains("\"autoWrap\""))
    let decoded = try JSONDecoder().decode(ScreenSnapshot.self, from: data)
    #expect(decoded == snap)
}
```

- [ ] **Step 6: Run tests + build**

```bash
xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test -quiet
xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build -quiet
```

- [ ] **Step 7: Commit**

```bash
git add TermCore/ScreenSnapshot.swift \
        TermCore/ScreenModel.swift \
        TermCore/ScreenModel+Buffer.swift \
        TermCoreTests/CodableTests.swift
git commit -m "refactor(TermCore): TerminalState sub-struct + Cursor.zero

ScreenSnapshot gains a nested TerminalState value type grouping the
7 terminal-state fields (cursorVisible, activeBuffer, windowTitle,
cursorKeyApplication, bracketedPaste, bellCount, autoWrap). A
convenience init accepts it; the 12-param init is preserved for
back-compat. Wire format (Codable) stays flat — verified by test.

Cursor.zero replaces 4 inline Cursor(row: 0, col: 0) sites. Both
additions prepare Phase 3 feature work (DECSCUSR cursor shape,
iconName) which otherwise would push the flat init to 14 params."
```

---

## Task 5: `DispatchSerialQueue` typed init

**Spec reference:** §8 Track B item 6.

**Goal:** `ScreenModel.init(..., queue: DispatchQueue? = nil)` force-casts to `DispatchSerialQueue` at runtime. A caller that accidentally passes a `.concurrent` queue crashes with no compile-time warning. Land a single typed init that takes `serialQueue: DispatchSerialQueue?` and migrate the one in-tree caller that passes a queue (`rtermd/Session.swift:123`) in the same commit.

**Design decision — overload resolution hazard avoided.** A single typed init, no deprecated overload. Swift's overload resolution on `nil` against `DispatchQueue?` vs `DispatchSerialQueue?` is ambiguous (no canonical tiebreaker); keeping both would force every default-nil call site to emit either an ambiguity error or a surprise deprecation warning.

**Binary-compat note for BUILD_LIBRARY_FOR_DISTRIBUTION:** TermCore enables `BUILD_LIBRARY_FOR_DISTRIBUTION` only for Release. Since rTerm ships daemon + client in lockstep (spec §6), removing a `public init` is a **source** break but not a meaningful wire/binary break — there is no third-party consumer of TermCore to worry about. All in-tree callers migrate in the same commit.

**Files:**
- Modify: `TermCore/ScreenModel.swift`
- Modify: `rtermd/Session.swift` (call site uses new typed init)
- Modify: `rtermd/main.swift` if it constructs the daemon queue as untyped `DispatchQueue` (check with `rg -n "DispatchQueue\(label:" rtermd/`)

### Steps

- [ ] **Step 1: Read the existing `init`**

Open `TermCore/ScreenModel.swift` around line 211. Current signature:

```swift
public init(cols: Int = 80, rows: Int = 24, historyCapacity: Int = 10_000,
            queue: DispatchQueue? = nil) {
    let q = queue ?? DispatchQueue(label: "com.ronnyf.TermCore.ScreenModel")
    // swiftlint:disable:next force_cast
    self.executorQueue = q as! DispatchSerialQueue
    ...
}
```

- [ ] **Step 2: Replace with a single typed init**

```swift
/// Creates a screen model with the given dimensions.
///
/// - Parameter serialQueue: Optional serial dispatch queue to use as the
///   actor's executor. When `nil`, a private `DispatchSerialQueue` is
///   created. Typed so a concurrent queue is a compile error at the
///   call site — no runtime trap.
public init(cols: Int = 80, rows: Int = 24,
            historyCapacity: Int = 10_000,
            serialQueue: DispatchSerialQueue? = nil) {
    let q = serialQueue
        ?? DispatchSerialQueue(label: "com.ronnyf.TermCore.ScreenModel")
    self.executorQueue = q
    // ... rest of body unchanged, with `q as! DispatchSerialQueue` removed ...
}
```

Note the **argument label rename** — `queue:` → `serialQueue:`. Renaming the label avoids any overload-resolution ambiguity (there is no second overload) AND makes the call-site migration trivially greppable.

- [ ] **Step 3: Migrate known callers in-tree**

```bash
rg -n "ScreenModel\(" TermCore/ rtermd/ rTerm/
```

Expected call sites (verified during plan remediation):
- `rtermd/Session.swift:123` — passes `queue: queue` with `queue: DispatchQueue` typed as untyped. Migration: retype `queue` at the call site (the existing `Session.init` takes `queue: DispatchQueue`; upgrade the init parameter to `DispatchSerialQueue` or wrap at the call site — see Step 4 below).
- `rTerm/ContentView.swift` (inside `TerminalSession.init` — grep to confirm): passes nothing (defaults), so no migration beyond a clean rebuild.
- `TermCoreTests/ScreenModelTests.swift`: ~79 call sites, none pass a queue; no migration.

- [ ] **Step 4: Retype the Session queue parameter**

In `rtermd/Session.swift:111`, the `init(...)` signature currently takes `queue: DispatchQueue`. Upgrade to `DispatchSerialQueue`:

```swift
init(id: SessionID, shell: Shell, rows: UInt16, cols: UInt16,
     queue: DispatchSerialQueue) throws {
    ...
    self.screenModel = ScreenModel(cols: Int(cols), rows: Int(rows),
                                    serialQueue: queue)
    ...
}
```

Then follow up in `rtermd/main.swift` (or wherever the daemon queue is created): ensure the daemon queue variable is typed `DispatchSerialQueue` rather than untyped `DispatchQueue`. Swift's `DispatchQueue(label:)` default is serial but typed as `DispatchQueue` — construct with `DispatchSerialQueue(label:)` explicitly (or cast once where the queue is first created).

- [ ] **Step 5: Add a compile-time test**

In `TermCoreTests/ScreenModelTests.swift`, add at file scope (or a new `ScreenModelInitTests.swift`):

```swift
@Test("Typed init accepts a DispatchSerialQueue and nil")
func test_typed_init_compiles() async {
    let m1 = ScreenModel(cols: 80, rows: 24)
    #expect(await m1.historyCapacity == 10_000)
    let q = DispatchSerialQueue(label: "test.serial")
    let m2 = ScreenModel(cols: 80, rows: 24, historyCapacity: 100, serialQueue: q)
    #expect(await m2.historyCapacity == 100)
}
```

(Intentionally no "untyped-queue overload" test — that overload no longer exists. A failing test would mean the migration was incomplete.)

- [ ] **Step 6: Build + test**

```bash
xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build -quiet
xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test -quiet
```

Expected: clean build. Any compile error at `ScreenModel(...queue:...)` call sites is a migration miss — retype the queue at the reporting site.

- [ ] **Step 7: Commit**

```bash
git add TermCore/ScreenModel.swift \
        rtermd/Session.swift \
        rtermd/main.swift \
        TermCoreTests/
git commit -m "api(TermCore): typed DispatchSerialQueue init; migrate callers

ScreenModel.init's queue parameter is now DispatchSerialQueue?, not
DispatchQueue?. Passing a concurrent queue is a compile error — no
runtime trap via force_cast. The argument label also renamed to
serialQueue: so the call-site migration is greppable.

All in-tree callers (rtermd/Session.swift, rtermd/main.swift)
migrated in the same commit; TermCore tests (79 default-nil sites)
recompile unchanged. We intentionally dropped the deprecated
untyped-init overload because Swift's resolution of nil against
DispatchQueue? vs DispatchSerialQueue? is ambiguous — keeping both
would force every default-nil call site to emit a surprise
deprecation warning or a build error. TermCore ships in lockstep
with rtermd + rTerm per spec §6, so the source break has no
third-party blast radius."
```

---

## Task 6: RenderCoordinator vertex array reuse

**Spec reference:** §8 Track B item 1.

**Goal:** `RenderCoordinator.draw(in:)` declares 6 `[Float]` arrays per frame (`regularVerts`, `boldVerts`, `italicVerts`, `boldItalicVerts`, `underlineVerts`, `strikethroughVerts`) and `reserveCapacity`-initializes each. ~2,880 KB reserved-then-freed per frame; 169 MB/s at 60 fps. Promote to `var` instance properties, call `removeAll(keepingCapacity: true)` at the top of `draw(in:)`. Eliminates the alloc/free cycle entirely.

**Pattern used:** `os.signpost` instrumentation added first to establish a measurement baseline (count of allocations observed via `OSSignposter.beginInterval` inside the arrays' allocation points is infeasible without an allocator hook; instead, count `reserveCapacity` sites and instrument the draw loop to record the per-frame interval duration — the metric is frame time, not allocation count). XCTest `measure` block asserts no regression.

**Files:**
- Create: `TermCore/PerfCountersDebug.swift` (shared DEBUG counters used by Tasks 6, 7, 9)
- Modify: `rTerm/RenderCoordinator.swift`
- Create: `rTermTests/RenderCoordinatorAllocationTests.swift`

### Steps

- [ ] **Step 1: Add signposter + arrays as instance properties + shared `PerfCountersDebug` enum**

Tasks 6, 7, and 9 each want a DEBUG-only counter visible to unit tests. Three separate `nonisolated(unsafe) static var xxxForTesting` declarations with three near-identical Swift 6 isolation rationale paragraphs is not reviewer-friendly. Factor one shared file up front.

Create `rTerm/PerfCountersDebug.swift`:

```swift
//
//  PerfCountersDebug.swift
//  rTerm
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//
//  DEBUG-only shared perf counters exposed to rTermTests +
//  TermCoreTests. Consolidated into one namespace so the Swift 6
//  isolation rationale is written once, not three times.
//
//  `nonisolated(unsafe)` correctness invariant (applies to every field
//  below): the counter is written from whatever actor/queue owns the
//  code path it instruments AND read from a @MainActor test after a
//  deterministic synchronization point (an `await` on the instrumented
//  actor, or `MTKView.draw` completion on the MainActor). Violating
//  either — e.g., reading the counter without an intervening happens-
//  before edge — makes the number meaningless. `nonisolated(unsafe)`
//  here encodes "I have verified happens-before in the calling test,
//  do not diagnose the data race."
//

#if DEBUG
public enum PerfCountersDebug {
    /// Metal buffer allocations observed in the current `draw(in:)` pass.
    /// Written by `RenderCoordinator.draw(in:)` on the MainActor; read
    /// by `RenderCoordinatorAllocationTests` on the MainActor after the
    /// frame completes. Task 7 instruments this.
    nonisolated(unsafe) public static var makeBufferCount: Int = 0

    /// Vertex-array capacities observed after a `beginFrameCleanup`
    /// call. Written by `RenderCoordinator.beginFrameCleanup` on the
    /// MainActor; read by `RenderCoordinatorAllocationTests`. Task 6
    /// uses this (via an instance accessor that reads the capacities
    /// directly — the array storage itself is the counter).
    nonisolated(unsafe) public static var vertexCapacitySnapshot: [Int] = []

    /// `ScrollbackHistory.Row` allocations per scrolling LF. Written
    /// by `ScreenModel.scrollAndMaybeEvict` on the actor's serial
    /// executor (daemon queue); read by
    /// `ScrollbackHistoryAllocationTests` after awaiting the
    /// deterministic number of actor-isolated applies. Task 9 uses this.
    nonisolated(unsafe) public static var rowAllocationCount: Int = 0
}
#endif
```

Add the file to the **rTerm app target** — `PerfCountersDebug` is read by both `rTermTests` (which imports `rTerm`) and needs to be visible to `TermCore` for the Row-allocation increment in `ScreenModel.scrollAndMaybeEvict`. Since TermCore is a framework that rTerm imports (not the other way around), place the counter write site in TermCore too — use the same name but declared in `TermCore/PerfCountersDebug.swift` OR have TermCore export its own counter that rTerm's test imports through `@testable import TermCore`.

**Layering note:** simplest layout is `TermCore/PerfCountersDebug.swift` because TermCore's `ScrollbackHistory` needs to write one of the counters. Reading from `rTermTests` works via `@testable import TermCore` (already used). `rTerm/RenderCoordinator` reads / writes from its own module via `import TermCore`.

Then in `rTerm/RenderCoordinator.swift`, near the top of the class:

```swift
import os

// Inside RenderCoordinator:
private let signposter = OSSignposter(subsystem: "rTerm", category: "RenderCoordinator")

// Vertex buffers reused across frames. Cleared (count reset, capacity
// retained) at the top of draw(in:). Sized to the worst-case grid
// during init and on resize.
private var regularVerts: [Float] = []
private var boldVerts: [Float] = []
private var italicVerts: [Float] = []
private var boldItalicVerts: [Float] = []
private var underlineVerts: [Float] = []
private var strikethroughVerts: [Float] = []
```

- [ ] **Step 2: Reserve capacity at `init` and on resize**

In `RenderCoordinator.init(...)`, after the existing setup:

```swift
// Reserve worst-case capacity once. 24x80 is the default; Metal's
// mtkView(_:drawableSizeWillChange:) expands as needed via a helper.
reserveVertexCapacity(cols: 80, rows: 24)
```

Add the helper:

```swift
private func reserveVertexCapacity(cols: Int, rows: Int) {
    let cells = cols * rows * Self.verticesPerCell
    let glyphFloats = cells * Self.floatsPerCellVertex
    let overlayFloats = cells * Self.floatsPerOverlayVertex
    regularVerts.reserveCapacity(glyphFloats)
    boldVerts.reserveCapacity(glyphFloats)
    italicVerts.reserveCapacity(glyphFloats)
    boldItalicVerts.reserveCapacity(glyphFloats)
    underlineVerts.reserveCapacity(overlayFloats)
    strikethroughVerts.reserveCapacity(overlayFloats)
}
```

Find the existing `mtkView(_:drawableSizeWillChange:)` (or equivalent resize hook) and call `reserveVertexCapacity(cols: newCols, rows: newRows)` when dimensions grow beyond the existing capacity. If no resize hook yet exists on the coordinator, piggy-back on the first `draw(in:)` frame: if `cols * rows * verticesPerCell * floatsPerCellVertex > regularVerts.capacity`, call `reserveVertexCapacity(cols:rows:)`.

- [ ] **Step 3: Rewrite `draw(in:)` preamble**

Find the current block:

```swift
var regularVerts = [Float]()
var boldVerts = [Float]()
... (6 locals)
regularVerts.reserveCapacity(...)
... (6 reserveCapacity calls)
```

Replace with:

```swift
let signpostID = signposter.makeSignpostID()
let signpost = signposter.beginInterval("drawFrame", id: signpostID)
defer { signposter.endInterval("drawFrame", signpost) }

// Reuse instance-level vertex buffers across frames — `removeAll(keepingCapacity:)`
// resets count but keeps the backing allocation. See Phase 2 efficiency
// research doc for the allocation-regression measurement.
regularVerts.removeAll(keepingCapacity: true)
boldVerts.removeAll(keepingCapacity: true)
italicVerts.removeAll(keepingCapacity: true)
boldItalicVerts.removeAll(keepingCapacity: true)
underlineVerts.removeAll(keepingCapacity: true)
strikethroughVerts.removeAll(keepingCapacity: true)

// Resize-on-grow safety: if the grid has expanded beyond the currently
// reserved capacity, re-reserve. `[Float].reserveCapacity` on an array
// that already has sufficient capacity is a no-op.
if regularVerts.capacity < rows * cols * Self.verticesPerCell * Self.floatsPerCellVertex {
    reserveVertexCapacity(cols: cols, rows: rows)
}
```

- [ ] **Step 4: Remove `var` annotations from the local-shadow usages**

The arrays are now instance `var`s. Inside `draw(in:)`, the existing code likely appends to them via `regularVerts.append(contentsOf: ...)` etc. That compiles unchanged (instance-var mutation from a MainActor method is allowed — `RenderCoordinator` is `@MainActor`).

If the original code had `var regularVerts = [Float]()` as a local, the local shadows are now gone (Step 3 removed them). All subsequent uses bind to the instance property. No textual change is needed at append sites.

- [ ] **Step 5: Add allocation-count test**

**Test design note:** extract the bookkeeping preamble of `draw(in:)` into a standalone helper that can run without a drawable. The test exercises the preamble only — the Metal render passes stay untested by unit tests, but the vertex-array capacity invariant (the thing this task is protecting) is exercised end-to-end.

In `rTerm/RenderCoordinator.swift`, factor the capacity-reserve + clear preamble out of `draw(in:)` into an internal method the tests can call:

```swift
/// Reset vertex buffers for a new frame. `removeAll(keepingCapacity:
/// true)` keeps the backing allocation; the capacity-grow check
/// re-reserves if the grid has grown beyond the previously reserved
/// capacity.
///
/// Internal (not private) so the allocation-regression test can call
/// it without going through `draw(in:)`'s full Metal pipeline.
internal func beginFrameCleanup(cols: Int, rows: Int) {
    regularVerts.removeAll(keepingCapacity: true)
    boldVerts.removeAll(keepingCapacity: true)
    italicVerts.removeAll(keepingCapacity: true)
    boldItalicVerts.removeAll(keepingCapacity: true)
    underlineVerts.removeAll(keepingCapacity: true)
    strikethroughVerts.removeAll(keepingCapacity: true)
    if regularVerts.capacity < rows * cols * Self.verticesPerCell * Self.floatsPerCellVertex {
        reserveVertexCapacity(cols: cols, rows: rows)
    }
}
```

Call it from `draw(in:)`'s preamble (replacing the inline block added in Step 3).

Create `rTermTests/RenderCoordinatorAllocationTests.swift`:

```swift
//
//  RenderCoordinatorAllocationTests.swift
//  rTermTests
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

import Foundation
import Metal
import XCTest
@testable import rTerm
@testable import TermCore

/// Guard the invariant that the draw-frame preamble does not re-allocate
/// the six vertex arrays every frame. We call `beginFrameCleanup` directly
/// (bypasses the Metal render path) so the test needs neither a window
/// nor a live drawable — only an `MTLDevice`, which every Mac CI agent
/// has.
final class RenderCoordinatorAllocationTests: XCTestCase {

    @MainActor
    func test_vertex_arrays_preserve_capacity_across_frames() throws {
        // Skip gracefully if the host has no Metal device (rare on macOS
        // CI; present on GitHub Actions default mac runners).
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("no Metal device; unit test requires one")
        }
        let model = ScreenModel(cols: 80, rows: 24)
        let settings = AppSettings()
        let coord = RenderCoordinator(screenModel: model, settings: settings)

        // First "frame" — should reserve capacity.
        coord.beginFrameCleanup(cols: 80, rows: 24)
        let capAfterOne = coord.vertexCapacitiesForTesting()

        // Second "frame" — capacities must be unchanged.
        coord.beginFrameCleanup(cols: 80, rows: 24)
        let capAfterTwo = coord.vertexCapacitiesForTesting()

        XCTAssertEqual(capAfterOne, capAfterTwo,
                       "vertex array capacities must be stable across frames")
        XCTAssertTrue(capAfterOne.allSatisfy { $0 > 0 },
                      "capacities should have been reserved; got \(capAfterOne)")
    }
}
```

In `rTerm/RenderCoordinator.swift`, add the testing accessor:

```swift
#if DEBUG
extension RenderCoordinator {
    /// Test-only: exposes the current capacity of each vertex buffer.
    func vertexCapacitiesForTesting() -> [Int] {
        [regularVerts.capacity, boldVerts.capacity, italicVerts.capacity,
         boldItalicVerts.capacity, underlineVerts.capacity, strikethroughVerts.capacity]
    }
}
#endif
```

No `forTesting` factory — `RenderCoordinator.init(screenModel:settings:)` already constructs a usable coordinator. The only environmental requirement is an `MTLDevice`, which is available on every macOS host; the test uses `XCTSkip` to degrade gracefully if that fails (it won't, in practice).

- [ ] **Step 6: Build + test**

```bash
xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build -quiet
xcodebuild -project rTerm.xcodeproj -scheme rTermTests test -quiet
```

Expected: build clean, allocation test passes (or skips if Metal unavailable).

- [ ] **Step 7: Commit**

```bash
git add rTerm/RenderCoordinator.swift \
        rTermTests/RenderCoordinatorAllocationTests.swift
git commit -m "perf(rTerm): reuse vertex arrays across draw frames

RenderCoordinator.draw(in:) allocated six [Float] arrays per frame and
reserveCapacity'd each — ~2,880 KB reserved-then-freed per frame, or
169 MB/s at 60 fps. Promote them to instance vars and reset with
removeAll(keepingCapacity: true) at the top of draw(in:). Capacity
reserved once in init (and on grid grow) via reserveVertexCapacity.

os_signpost 'drawFrame' interval added so Instruments can show the
per-frame cost drop end-to-end. A DEBUG-only factory hook lets
rTermTests exercise the preamble without a live Metal drawable."
```

---

## Task 7: Metal buffer pre-allocation ring

**Spec reference:** §8 Track B item 2.

**Goal:** `device.makeBuffer(bytes:length:options:)` is called up to 6 times per frame (4 glyph passes + underline + strikethrough). Each call allocates from Metal's shared heap, which is cheap on Apple Silicon but not free. Implement a pre-allocated ring of 6 `MTLBuffer`s per draw pass × `maxBuffersInFlight` (3), so `draw(in:)` writes into an owned buffer instead of allocating a fresh one each time. Target: zero `makeBuffer` calls in steady state.

**Design:** A small `MetalBufferRing` helper type owns `N` fixed-size buffers. `currentBuffer()` returns one, incrementing an internal cursor; after `maxBuffersInFlight` frames the cursor wraps. Sized to the grid's worst-case vertex count. On grow, rebuild the ring.

**Files:**
- Create: `rTerm/MetalBufferRing.swift`
- Modify: `rTerm/RenderCoordinator.swift`
- Create: `rTermTests/MetalBufferRingTests.swift`

### Steps

- [ ] **Step 1: Add measurement first — baseline count**

Task 6 already landed `TermCore/PerfCountersDebug.swift` with a `makeBufferCount` field under a single shared Swift 6 isolation rationale. Use it here; do NOT add a separate `nonisolated(unsafe) static var` on `RenderCoordinator`.

Wrap each `device.makeBuffer(...)` call in `draw(in:)`:

```swift
#if DEBUG
PerfCountersDebug.makeBufferCount += 1
#endif
let buf = device.makeBuffer(bytes: ..., length: ..., options: ...)
```

Add a signposter interval `"metalBufferAlloc"` around each call site so Instruments can render the delta.

Commit this intermediate measurement before implementing the ring:

```bash
git add rTerm/RenderCoordinator.swift
git commit -m "perf(rTerm): instrument per-frame makeBuffer count

Baseline measurement ahead of Track B item 2 (Metal buffer ring).
DEBUG-only counter on RenderCoordinator exposes the per-frame
makeBuffer invocation count to tests."
```

- [ ] **Step 2: Build `MetalBufferRing`**

**GPU-sync design — verified against Apple docs (https://developer.apple.com/documentation/metal/synchronizing-cpu-and-gpu-work):**

> "Even with `maxBuffersInFlight=3`, you must wait for the GPU to finish using the buffer before the CPU modifies it."

The canonical pattern is `DispatchSemaphore(value: maxBuffersInFlight)` paired with `commandBuffer.addCompletedHandler { semaphore.signal() }`. The CPU calls `semaphore.wait()` before writing into the next ring buffer; the completion handler signals when the GPU is done with the frame that used it. Without this sync, the CPU can overwrite a buffer the GPU is still sampling — torn reads or visual corruption, often intermittent.

**Ownership:** the semaphore lives **on the ring**, not on the coordinator. The ring provides `nextBuffer(copying:length:)` (which internally `wait()`s) and `signalOnCompletion(commandBuffer:)` (which registers the handler). Callers never see the semaphore; they treat the ring as a serialized resource.

Create `rTerm/MetalBufferRing.swift`:

```swift
//
//  MetalBufferRing.swift
//  rTerm
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

import Metal
import Dispatch

/// Pre-allocated ring of `MTLBuffer`s used to avoid per-frame
/// `makeBuffer` allocations in the render loop. Pairs a GPU-sync
/// semaphore with the ring so the CPU cannot overwrite a buffer the
/// GPU is still reading — see
/// https://developer.apple.com/documentation/metal/synchronizing-cpu-and-gpu-work.
///
/// Usage per frame (inside draw(in:)):
///   1. let buf = ring.nextBuffer(copying: ptr, length: n)
///      // internally: semaphore.wait(); copy bytes; advance cursor
///   2. encode draw using `buf`
///   3. ring.signalOnCompletion(commandBuffer: cb)
///      // attaches addCompletedHandler that signals the ring's semaphore
///   4. cb.commit()
///
/// On resize, call drainAndResize(byteLength:) — it waits for every
/// in-flight frame to finish (semaphore.wait() × count) before
/// rebuilding the buffers, guaranteeing no GPU is still reading.
@MainActor
final class MetalBufferRing {
    private let device: MTLDevice
    private var buffers: [MTLBuffer]
    private var cursor: Int = 0
    private(set) var byteLength: Int
    private let count: Int

    /// GPU-sync gate. Initial value = count (all buffers free at start).
    /// wait() blocks if all buffers are in flight; signal() releases
    /// one slot after a frame completes.
    nonisolated(unsafe) private let semaphore: DispatchSemaphore

    init(device: MTLDevice, count: Int, byteLength: Int) {
        precondition(count > 0, "ring count must be positive")
        precondition(byteLength > 0, "ring byteLength must be positive")
        self.device = device
        self.count = count
        self.byteLength = byteLength
        self.semaphore = DispatchSemaphore(value: count)
        self.buffers = (0..<count).compactMap {
            device.makeBuffer(length: byteLength, options: .storageModeShared)
        }
        precondition(self.buffers.count == count,
                     "MetalBufferRing failed to allocate \(count) buffers of \(byteLength) bytes")
    }

    /// Write `data` into the next buffer in the ring and return it.
    /// Blocks on the GPU-sync semaphore if all buffers are in flight.
    /// Truncates if `length > byteLength`; caller must have resized.
    func nextBuffer(copying data: UnsafeRawPointer, length: Int) -> MTLBuffer {
        precondition(length <= byteLength,
                     "incoming data length \(length) exceeds ring byteLength \(byteLength); caller must resize first")
        // Wait until the GPU has finished with the buffer at `cursor`.
        semaphore.wait()
        let buf = buffers[cursor]
        buf.contents().copyMemory(from: data, byteCount: length)
        cursor = (cursor + 1) % count
        return buf
    }

    /// Register a GPU-completion handler that signals the ring's
    /// semaphore. Call this after the command buffer uses the buffer
    /// returned by nextBuffer, before committing.
    func signalOnCompletion(commandBuffer: MTLCommandBuffer) {
        let sem = semaphore
        commandBuffer.addCompletedHandler { _ in
            sem.signal()
        }
    }

    /// Drain every in-flight slot and resize. Blocks until the GPU has
    /// finished all outstanding frames that used this ring, then
    /// rebuilds the buffers. Caller (coordinator) must call this from
    /// the resize hook BEFORE the next draw.
    func drainAndResize(byteLength newByteLength: Int) {
        precondition(newByteLength > 0)
        guard newByteLength != byteLength else { return }
        // Wait for every in-flight frame to complete.
        for _ in 0..<count { semaphore.wait() }
        // Rebuild.
        buffers = (0..<count).compactMap {
            device.makeBuffer(length: newByteLength, options: .storageModeShared)
        }
        byteLength = newByteLength
        cursor = 0
        // Release all slots — the new buffers are all free.
        for _ in 0..<count { semaphore.signal() }
    }
}
```

**Note on `nonisolated(unsafe)` for the semaphore:** `DispatchSemaphore` is reference-safe from any thread by contract (it's the whole point of the API). The `@MainActor` class annotation keeps the ring's buffer slice serialized, but the semaphore itself must be readable from the GPU completion handler which runs on an arbitrary Dispatch thread. `nonisolated(unsafe)` is the correct annotation here; the invariant is that `signal()` and `wait()` are both thread-safe operations.

- [ ] **Step 3: Tests for the ring**

Create `rTermTests/MetalBufferRingTests.swift`:

```swift
import Foundation
import Metal
import XCTest
@testable import rTerm

final class MetalBufferRingTests: XCTestCase {

    @MainActor
    func test_ring_cycles_through_buffers() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(),
                                    "Metal device required for this test")
        let ring = MetalBufferRing(device: device, count: 3, byteLength: 256)
        var payload: [UInt8] = Array(repeating: 0xAB, count: 16)

        // Three uses fill the ring.
        let b1 = ring.nextBuffer(copying: &payload, length: 16)
        let b2 = ring.nextBuffer(copying: &payload, length: 16)
        let b3 = ring.nextBuffer(copying: &payload, length: 16)
        XCTAssertNotEqual(ObjectIdentifier(b1), ObjectIdentifier(b2))
        XCTAssertNotEqual(ObjectIdentifier(b2), ObjectIdentifier(b3))

        // A fourth use would block on the semaphore — simulate GPU
        // completion on b1 by manually signaling through a fake command
        // buffer's completion handler. In a real render this happens
        // via addCompletedHandler.
        let cq = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(cq.makeCommandBuffer())
        ring.signalOnCompletion(commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()  // waits until the handler fires

        // Now a fourth use returns b1 (slot released, cursor wraps).
        let b4 = ring.nextBuffer(copying: &payload, length: 16)
        XCTAssertEqual(ObjectIdentifier(b1), ObjectIdentifier(b4),
                       "cursor should wrap to index 0 after slot 0 signaled")
    }

    @MainActor
    func test_drainAndResize_rebuilds_buffers_at_new_size() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let ring = MetalBufferRing(device: device, count: 2, byteLength: 128)
        XCTAssertEqual(ring.byteLength, 128)
        ring.drainAndResize(byteLength: 512)
        XCTAssertEqual(ring.byteLength, 512)
    }

    @MainActor
    func test_drainAndResize_noop_when_size_unchanged() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let ring = MetalBufferRing(device: device, count: 2, byteLength: 128)
        var payload: [UInt8] = Array(repeating: 0, count: 16)

        // First use — takes slot 0.
        let before = ring.nextBuffer(copying: &payload, length: 16)

        // Signal completion so the slot is released.
        let cq = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(cq.makeCommandBuffer())
        ring.signalOnCompletion(commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()

        ring.drainAndResize(byteLength: 128)  // same size — noop

        // After the noop, the cursor has advanced; next use takes slot 1.
        let after = ring.nextBuffer(copying: &payload, length: 16)
        XCTAssertNotEqual(ObjectIdentifier(before), ObjectIdentifier(after))
    }
}
```

- [ ] **Step 4: Wire six rings into `RenderCoordinator`**

In `rTerm/RenderCoordinator.swift`, add instance properties:

```swift
// One ring per vertex-pass category. Verified against plan-time
// `rTerm/RenderCoordinator.swift` (see appendix): there is NO existing
// `maxBuffersInFlight` constant and NO existing `DispatchSemaphore` in
// the file. Default count to 3 — Apple's canonical triple-buffer
// value (see the GPU-sync design note above).
private static let maxBuffersInFlight = 3
private var regularRing: MetalBufferRing?
private var boldRing: MetalBufferRing?
private var italicRing: MetalBufferRing?
private var boldItalicRing: MetalBufferRing?
private var underlineRing: MetalBufferRing?
private var strikethroughRing: MetalBufferRing?
```

Add initialization helper:

```swift
private func ensureRings(cols: Int, rows: Int) {
    let cells = cols * rows * Self.verticesPerCell
    let glyphBytes = cells * Self.floatsPerCellVertex * MemoryLayout<Float>.stride
    let overlayBytes = cells * Self.floatsPerOverlayVertex * MemoryLayout<Float>.stride
    if regularRing == nil {
        regularRing = MetalBufferRing(device: device, count: Self.maxBuffersInFlight, byteLength: glyphBytes)
        boldRing = MetalBufferRing(device: device, count: Self.maxBuffersInFlight, byteLength: glyphBytes)
        italicRing = MetalBufferRing(device: device, count: Self.maxBuffersInFlight, byteLength: glyphBytes)
        boldItalicRing = MetalBufferRing(device: device, count: Self.maxBuffersInFlight, byteLength: glyphBytes)
        underlineRing = MetalBufferRing(device: device, count: Self.maxBuffersInFlight, byteLength: overlayBytes)
        strikethroughRing = MetalBufferRing(device: device, count: Self.maxBuffersInFlight, byteLength: overlayBytes)
    } else if regularRing!.byteLength < glyphBytes {
        // Resize path — drainAndResize waits for in-flight frames.
        regularRing!.drainAndResize(byteLength: glyphBytes)
        boldRing!.drainAndResize(byteLength: glyphBytes)
        italicRing!.drainAndResize(byteLength: glyphBytes)
        boldItalicRing!.drainAndResize(byteLength: glyphBytes)
        underlineRing!.drainAndResize(byteLength: overlayBytes)
        strikethroughRing!.drainAndResize(byteLength: overlayBytes)
    }
}
```

Call `ensureRings(cols: cols, rows: rows)` at the top of `draw(in:)` (right after the `removeAll(keepingCapacity:)` preamble from Task 7).

- [ ] **Step 5: Replace `makeBuffer` call sites with ring allocation**

Find each `device.makeBuffer(bytes: ...verts, length: ..., options: .storageModeShared)` site in `RenderCoordinator.swift` and replace. Each pass's `nextBuffer` must be paired with a `signalOnCompletion` on the enclosing `commandBuffer` so the semaphore is released when the GPU finishes the frame:

```swift
// Before:
let buf = device.makeBuffer(bytes: regularVerts, length: regularVerts.count * 4, options: .storageModeShared)

// After:
let buf = regularVerts.withUnsafeBufferPointer { ptr in
    regularRing!.nextBuffer(copying: ptr.baseAddress!,
                             length: ptr.count * MemoryLayout<Float>.stride)
}
// ... encode the draw call using `buf` ...
```

After encoding ALL passes, register one completion handler per ring on the shared command buffer, right before commit:

```swift
regularRing!.signalOnCompletion(commandBuffer: commandBuffer)
boldRing!.signalOnCompletion(commandBuffer: commandBuffer)
italicRing!.signalOnCompletion(commandBuffer: commandBuffer)
boldItalicRing!.signalOnCompletion(commandBuffer: commandBuffer)
underlineRing!.signalOnCompletion(commandBuffer: commandBuffer)
strikethroughRing!.signalOnCompletion(commandBuffer: commandBuffer)
commandBuffer.commit()
```

Repeat for bold, italic, boldItalic, underline, strikethrough passes. Cursor and overlay (scroll bell flash, etc.) passes that use `setVertexBytes` or separate allocations stay unchanged unless they fit the pattern.

Remove the `#if DEBUG PerfCountersDebug.makeBufferCount += 1` from these sites (since they're no longer making buffers). Keep it on any remaining `makeBuffer` calls that didn't migrate.

- [ ] **Step 6: Add steady-state counter test**

Append to `rTermTests/RenderCoordinatorAllocationTests.swift`. The test exercises the `ensureRings` path directly (not `draw(in:)`) using the same factory-free pattern from Task 6 Step 5:

```swift
@MainActor
func test_steady_state_makeBuffer_count_is_zero() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
        throw XCTSkip("no Metal device; unit test requires one")
    }
    let model = ScreenModel(cols: 80, rows: 24)
    let settings = AppSettings()
    let coord = RenderCoordinator(screenModel: model, settings: settings)

    // Prime the rings with an ensureRings call (the warmup that would
    // happen on the first draw frame).
    coord.ensureRingsForTesting(cols: 80, rows: 24)
    PerfCountersDebug.makeBufferCount = 0

    // Simulate several steady-state frames. ensureRings at a stable size
    // is a no-op after the priming call, so makeBufferCount must stay at 0.
    for _ in 0..<10 {
        coord.ensureRingsForTesting(cols: 80, rows: 24)
    }
    XCTAssertEqual(PerfCountersDebug.makeBufferCount, 0,
                   "steady-state draw should allocate no MTLBuffers")
}
```

Add the `ensureRingsForTesting(cols:rows:)` DEBUG-only accessor on `RenderCoordinator` that forwards to the private `ensureRings(cols:rows:)` implementation — same pattern as `vertexCapacitiesForTesting`.

- [ ] **Step 7: Build + test**

```bash
xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build -quiet
xcodebuild -project rTerm.xcodeproj -scheme rTermTests test -quiet
```

- [ ] **Step 8: Commit**

```bash
git add rTerm/MetalBufferRing.swift \
        rTerm/RenderCoordinator.swift \
        rTermTests/MetalBufferRingTests.swift \
        rTermTests/RenderCoordinatorAllocationTests.swift
git commit -m "perf(rTerm): pre-allocated Metal buffer rings with GPU sync

Six MetalBufferRing instances (one per vertex-pass category — regular,
bold, italic, boldItalic, underline, strikethrough). Each ring holds
maxBuffersInFlight=3 MTLBuffers sized to the worst-case grid, plus a
DispatchSemaphore(value: 3) gating CPU writes against in-flight GPU
reads (per Apple's triple-buffering guidance:
https://developer.apple.com/documentation/metal/synchronizing-cpu-and-gpu-work).

draw(in:) writes via nextBuffer(copying:length:) (which semaphore.wait()s
before returning the next slot) and registers signalOnCompletion on the
frame's command buffer so the semaphore signals when the GPU finishes.
Grid resize uses drainAndResize(byteLength:) which waits for every
in-flight slot to drain before rebuilding — no torn reads possible.

Steady-state makeBuffer count drops from 4-6/frame to 0. Ring lifecycle
covered by unit tests that exercise the semaphore via a real
MTLCommandQueue. DEBUG-only counter test pins the
zero-steady-state invariant."
```

---

## Task 8: `cellAt` scrolled-render loop hoist

**Spec reference:** §8 Track B item 7.

**Goal:** In `RenderCoordinator.draw(in:)`, when `scrollOffset > 0` the renderer's inner loop calls `history[historyRowIdx]` once per (row, col) pair — 1,920 `ContiguousArray<Cell>` header copies per frame at 24×80 (~46 KB/frame, 2.6 MB/s at 60 fps). Hoist the row load to the outer loop.

**Files:**
- Modify: `rTerm/RenderCoordinator.swift`

### Steps

- [ ] **Step 1: Locate the scrolled render loop**

Grep: `rg -n "cellAt|history\[.*\]|scrollOffset" rTerm/RenderCoordinator.swift`. Find the nested loop block that iterates `(row, col)` and at each `col` calls either `snapshot[row, col]` (live path) or `history[historyRowIdx]` (scrolled path) with the row-header copy per call.

- [ ] **Step 2: Restructure the loop**

Refactor the inner loop so the history row is loaded once per outer-loop iteration:

```swift
// Before (illustrative):
for row in 0..<rows {
    for col in 0..<cols {
        let cell = cellAt(row: row, col: col, snapshot: snapshot, history: history, scrollOffset: scrollOffset)
        // emit vertices for cell
    }
}

// After:
for row in 0..<rows {
    if row < scrollOffset {
        // Scrolled-back row lives in history; hoist the row header out
        // of the column loop.
        let historyRowIdx = history.count - scrollOffset + row
        let historyRow: ContiguousArray<Cell> = history[historyRowIdx]
        for col in 0..<cols {
            let cell = col < historyRow.count ? historyRow[col] : Cell(character: " ")
            // emit vertices for cell
        }
    } else {
        // Live row — snapshot subscript is already fast.
        let liveRow = row - scrollOffset
        for col in 0..<cols {
            let cell = snapshot[liveRow, col]
            // emit vertices for cell
        }
    }
}
```

- [ ] **Step 3: Verify `cellAt` is no longer called from the hot path**

If `cellAt` has no remaining callers after the restructure, remove it. If it is still used elsewhere (e.g., cursor rendering), leave it in place — the hot-path win is preserved regardless.

- [ ] **Step 4: Test — scrolled rendering still correct**

The existing `ScrollViewStateTests` don't exercise the coordinator's render loop (they're state tests). Verify by launching the app, scrolling back via wheel + PgUp, and confirming the scrolled content is correctly rendered. The existing integration tests don't cover this path.

Because manual verification is the practical check, flag to the user for confirmation.

- [ ] **Step 5: Build**

```bash
xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build -quiet
```

- [ ] **Step 6: Commit**

```bash
git add rTerm/RenderCoordinator.swift
git commit -m "perf(rTerm): hoist history row-header load out of column loop

When scrollOffset > 0, the scrolled render loop called
history[historyRowIdx] once per (row, col) pair — 1,920 header copies
per frame at 24x80 (~46 KB/frame). Restructure: load the history row
once per outer-loop iteration, index into it for each column. Cuts
scrolled-frame overhead by ~2.5 MB/s at 60 fps. Live-render path is
unchanged."
```

---

## Task 9: `ScrollbackHistory.Row` pre-allocation (measurement-gated)

**Spec reference:** §8 Track B item 3.

**Goal:** `scrollAndMaybeEvict` allocates a new `ContiguousArray<Cell>` (~3.1 KB) per scrolling LF on main. At 1,000 LF/s (fast `cat`) this is ~3 MB/s; at 10,000 LF/s burst it could show up as allocator pressure. The spec instructs: **measure first**, implement only if measurement shows a meaningful regression.

Approach: add allocation instrumentation, run a sustained-throughput benchmark, and decide based on the numbers. If no regression, commit the instrumentation + a "deferred with measurement" note. If regression, implement a ring of pre-allocated Row buffers.

**Files:**
- Modify: `TermCore/ScrollbackHistory.swift` (benchmark hook; conditional implementation)
- Create: `TermCoreTests/ScrollbackHistoryAllocationTests.swift`

### Steps

- [ ] **Step 1: Add an allocation counter increment to `ScrollbackHistory`**

Task 6 already landed `TermCore/PerfCountersDebug.swift` with a shared `rowAllocationCount` field under a single Swift 6 isolation rationale. Use it; do NOT introduce a second `nonisolated(unsafe)` declaration here.

In `TermCore/ScrollbackHistory.swift`, in `push(_:)` (or wherever the new Row is constructed inside `scrollAndMaybeEvict`), add:

```swift
#if DEBUG
PerfCountersDebug.rowAllocationCount += 1
#endif
```

Note: the Row allocation actually happens in `ScreenModel.scrollAndMaybeEvict` (which constructs `var top = ScrollbackHistory.Row()` then appends). Place the counter there if that's cleaner.

- [ ] **Step 2: Write the allocation-measurement test**

Create `TermCoreTests/ScrollbackHistoryAllocationTests.swift`:

```swift
//
//  ScrollbackHistoryAllocationTests.swift
//  TermCoreTests
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

import Foundation
import Testing
@testable import TermCore

@Suite("ScrollbackHistory allocation measurement")
struct ScrollbackHistoryAllocationTests {

    @Test("Row allocations scale linearly with scrolling-LF count")
    func test_row_alloc_count_scales_linearly() async {
        let model = ScreenModel(cols: 80, rows: 24, historyCapacity: 10_000)
        // Fill the screen first so every subsequent LF triggers a scroll.
        for _ in 0..<24 {
            await model.apply([.c0(.lineFeed)])
        }
        PerfCountersDebug.rowAllocationCount = 0
        let lfCount = 1_000
        for _ in 0..<lfCount {
            await model.apply([.c0(.lineFeed)])
        }
        let allocs = PerfCountersDebug.rowAllocationCount
        #expect(allocs == lfCount,
                "Expected exactly one Row allocation per scrolling LF; got \(allocs) for \(lfCount) LFs")
    }
}
```

This test establishes the baseline: one allocation per scrolling LF. If the ring-buffer optimization lands, the expected value drops to a small constant (~`capacity` initial allocations, plus any reallocations on grow).

- [ ] **Step 3: Run the test — measurement collection**

```bash
xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests \
    -only-testing TermCoreTests/ScrollbackHistoryAllocationTests test -quiet
```

Expected: `allocs == 1000`. This is the baseline regression number.

- [ ] **Step 4: Measurement — unconditional**

Collect the baseline numbers. This step ALWAYS runs; it is not a branching decision.

Add a throughput test alongside the allocation-count test:

```swift
@Test("Throughput gate: 37,500 scrolling LFs in under 2.0 s (60 MB/s target)")
func test_throughput_gate() async {
    // 80 cols × 40 B/cell = 3.2 KB per Row.
    // 3.2 KB × 37,500 / 2.0 s = 60 MB/s — exactly the spec §8 Track B
    // item 3 threshold. Passing in under 2 s meets the gate; failing
    // means throughput is below it and the ring-buffer implementation
    // is warranted.
    let model = ScreenModel(cols: 80, rows: 24, historyCapacity: 10_000)
    for _ in 0..<24 { await model.apply([.c0(.lineFeed)]) }
    let start = Date()
    for _ in 0..<37_500 {
        await model.apply([.c0(.lineFeed)])
    }
    let elapsed = Date().timeIntervalSince(start)
    #expect(elapsed < 2.0,
            "37,500 scrolling LFs took \(elapsed)s (target: 60 MB/s = under 2.0 s)")
}
```

Run it:

```bash
xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests \
    -only-testing TermCoreTests/ScrollbackHistoryAllocationTests/test_throughput_gate test -quiet
```

Record the elapsed time in a scratch note. This measurement drives Step 5's conditional.

- [ ] **Step 5a: Commit the measurement + baseline deferral (always runs)**

The spec §8 Track B item 3 gate is the throughput-gate test from Step 4: `37_500 scrolling LFs in under 2.0 s on Apple Silicon` (≈ 60 MB/s sustained). The gate is **numerical and named** (`ScrollbackHistoryAllocationTests.test_throughput_gate`).

This sub-step ALWAYS commits the instrumentation + baseline deferral. The conditional follow-up (Step 5b) fires only if the measurement exceeded the 37,500-LF / 2.0 s bound.

Add a doc comment in `ScreenModel+Buffer.swift` (at the `scrollAndMaybeEvict` site):

```swift
/// Phase 3 Track B item 3: considered allocating a fixed-size Row
/// ring here to eliminate the per-LF ContiguousArray allocation.
/// Gate: ScrollbackHistoryAllocationTests.test_throughput_gate —
/// 37,500 scrolling LFs in under 2.0 s (60 MB/s sustained). When the
/// gate passes, the ring-buffer optimization is deferred indefinitely;
/// the allocation counter + throughput test remain as living
/// documentation so a future regression trips the gate immediately.
```

Commit the measurement + deferral:

```bash
git add TermCore/ScrollbackHistory.swift TermCore/ScreenModel+Buffer.swift \
        TermCoreTests/ScrollbackHistoryAllocationTests.swift
git commit -m "measure(TermCore): Row per-LF allocation gated at 60 MB/s; defer

Phase 2 efficiency research flagged ScrollbackHistory.Row per-LF
allocation (~3.1 KB per scrolling LF) as a potential hotspot.
Measurement: 1,000 scrolling LFs produce exactly 1,000 Row allocations.
Throughput gate: ScrollbackHistoryAllocationTests.test_throughput_gate —
37,500 scrolling LFs in under 2.0 s on Apple Silicon = 60 MB/s
sustained, the spec §8 Track B item 3 threshold. Passing the gate pins
that the baseline is NOT regressing.

Ring-buffer optimization deferred by Step 5a's baseline commit.
Counter + throughput test remain as living documentation."
```

- [ ] **Step 5b: Ring implementation (follow-up, ONLY if the 37,500-LF / 2.0 s gate failed in Step 4)**

This sub-step fires iff the `test_throughput_gate` assertion failed (elapsed >= 2.0 s on the host that ran Step 4). Skip entirely otherwise; the baseline committed in Step 5a is sufficient.

Implement:
  - Add `ScrollbackHistory` private storage `_rowPool: ContiguousArray<Row>` sized at `capacity` with each element pre-allocated to `cols * stride`.
  - `push(_:)` takes a new Row from the pool, copies into it, stores it, and the evicted Row goes back to the pool's free list.
  - Update the counter expectation in the baseline test to `~capacity + grow-count`.
  - Rerun the throughput test — it must now pass.

Commit the implementation:

```bash
git add TermCore/ScrollbackHistory.swift TermCoreTests/ScrollbackHistoryAllocationTests.swift
git commit -m "perf(TermCore): pre-allocated Row pool in ScrollbackHistory

Step 4's measurement showed per-LF Row allocation failed the numerical
37,500-LF / 2.0 s throughput gate (spec §8 Track B item 3 ≈ 60 MB/s).
Implement a fixed-size pool of pre-allocated ContiguousArray<Cell>
slots reused across scrolls. Row allocation count drops from O(LF) to
O(capacity). Throughput test now passes: 37,500 scrolling LFs in under
2.0 s. No behavior change visible to readers — tail(), all(), count
are unchanged."
```

---

## Track B completion checklist

After Task 9 lands, verify the following before opening a PR:

- [ ] `wc -l TermCore/ScreenModel*.swift` shows the split is intact.
- [ ] `rg -c "Cursor\(row: 0, col: 0\)" TermCore/` returns 0 (all migrated to `Cursor.zero`).
- [ ] `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test` passes (≥ 226 tests expected: 222 + 3 new + 1 from Task 1).
- [ ] `xcodebuild -project rTerm.xcodeproj -scheme rTermTests test` passes (≥ 56 tests expected: 53 + 1 invariance + 2 allocation).
- [ ] Deprecation warnings surface in `xcodebuild` output only for deliberate deprecation checks — no production-code warnings.
- [ ] PR description cites Phase 2 research doc findings, not just "fixes lint."
- [ ] CLAUDE.md does **not** need a new "Key Conventions" bullet for `nonisolated` value types — the spec reviewer flagged this as low priority and the pattern is already consistently applied.

**Self-review note:** this plan covers items 1–10, 12 from §8 Track B. Track B item 8 (`publishHistoryTail` ordering doc comment) lands inside Task 3 (file split) rather than its own task — the doc comment attaches to the method as it moves. Items 11 (`ImmutableBox<T>`) and 13 (comment cleanup) are deliberately not-in-Phase-3 per the spec. Item 10 (`CircularCollection` TODO) is deferred to a tracking comment only. If any item in §8 Track B lacks a task, add it inline.
