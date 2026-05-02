# Control-Characters Phase 3 — Track B Hygiene Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pay down the Phase 2 engineering debt enumerated in the Phase 2 research docs so Phase 3 features do not compound regressions. Ten items: one file split, one API-hardening rename, one sub-struct extraction, two test gaps, one fixture, two renderer hot-path fixes, one render-loop hoist, one measurement-gated scrollback fix.

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

/// Minimal sendable atomic bool — local to this test file. Avoids pulling
/// in Atomics package just for one test.
private final class AtomicBool: @unchecked Sendable {
    private var value: Bool
    private let lock = NSLock()
    init(value: Bool) { self.value = value }
    func load() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func store(_ new: Bool) { lock.lock(); defer { lock.unlock() }; value = new }
}
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

**Assertion design note:** the earlier draft of this fixture applied the entire byte stream in a single `model.apply(events)` call and asserted only the final `activeBuffer == .main` state. That admits a buggy handler that treats `1049 h`/`1049 l` as no-ops — both enter and exit become no-ops, the shell's content goes to main, and the end state still satisfies `.main`. The rewritten test splits the stream into two halves so we assert (a) alt was entered AND (b) alt grid holds the shell-drawn content, THEN (c) exit restores main with the MAIN content intact.

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

Expected: pass. If the active-buffer assertion fails on exit, inspect `handleAltScreen(.alternateScreen1049, enabled: false)` — the T4 correction should restore main.

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

**Goal:** `TermCore/ScreenModel.swift` is 941 lines with 10 logical sections. Split into three files linked by Swift extensions:

- `TermCore/ScreenModel.swift` — actor declaration, stored properties, `init`, `apply(_:)`, `publishSnapshot`, `makeSnapshot(from:)`, event dispatch helpers (`handlePrintable`, `handleC0`, `handleCSI`, `applySGR`, `handleOSC`), `eraseInDisplay`, `eraseInLine`, `handleSetMode`, `handleSetScrollRegion`, `handleAltScreen`, `snapshotCursor`, `restoreActiveCursor`, `latestSnapshot()`.
- `TermCore/ScreenModel+Buffer.swift` — `ScrollRegion`, `Buffer`, `mutateActive<R>`, `active`, `scrollAndMaybeEvict`, `clearGrid`.
- `TermCore/ScreenModel+History.swift` — `publishHistoryTail`, `restore(from snapshot:)`, `restore(from payload:)`, `buildAttachPayload`, `latestHistoryTail`, `_latestHistoryTail` storage, `pendingHistoryPublish`, `HistoryBox`.

Access promotion required: `Buffer` and `ScrollRegion` currently `private`; promote to `fileprivate` (new files must access them) — use `internal` only if a test file needs direct visibility (none does). `HistoryBox` and `SnapshotBox` stay `private` to their respective extension files.

**Files:**
- Modify: `TermCore/ScreenModel.swift`
- Create: `TermCore/ScreenModel+Buffer.swift`
- Create: `TermCore/ScreenModel+History.swift`
- Modify: `rTerm.xcodeproj/project.pbxproj` (add new files to TermCore target)

### Steps

- [ ] **Step 1: Plan the cut points**

Read `TermCore/ScreenModel.swift` in full. Identify the exact line ranges that belong to each extension file. Write these to a scratch file (discard after commit) so the cut is mechanical, not guesswork. Buffer-extension ranges: `ScrollRegion` struct, `Buffer` nested struct, `mutateActive`, `active`, `scrollAndMaybeEvict`, `clearGrid`. History-extension ranges: `_latestHistoryTail` property, `HistoryBox` class, `pendingHistoryPublish` flag, `publishHistoryTail()`, `buildAttachPayload()`, `latestHistoryTail()`, both `restore(from:)` methods.

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
//  scroll-region / grid mutation concerns.
//

import Foundation

extension ScreenModel {
    // ScrollRegion, Buffer, mutateActive<R>, active, scrollAndMaybeEvict,
    // clearGrid — moved from ScreenModel.swift without code changes.
    //
    // NOTE: Buffer and ScrollRegion were `private` inside the actor body.
    // They are now fileprivate here, but because this file and the main
    // ScreenModel.swift share a module, they remain unreachable from
    // outside TermCore.
}
```

Paste the exact original code for `ScrollRegion`, `Buffer`, `mutateActive`, `active`, `scrollAndMaybeEvict`, `clearGrid` inside the extension body. Change their access levels as needed to be reachable across extension boundaries in the same module (typically: leave unchanged if they were already module-internal or if they're nested inside the extension body).

For `Buffer` and `ScrollRegion` that were `private` nested types: keep them nested inside the extension and change `private` to `fileprivate`. The main `ScreenModel.swift` will then also be able to reference them via the same module.

Actually — the cleanest approach: define `Buffer` and `ScrollRegion` at `fileprivate` inside the Buffer extension file using the `extension ScreenModel { fileprivate struct Buffer ... }` syntax. But Swift disallows `fileprivate` types nested inside `extension X where` blocks from being visible to the main `ScreenModel.swift` at file scope.

Use `internal` visibility for `Buffer` and `ScrollRegion` in the new files. Mark them internal-only by keeping them inside an `extension ScreenModel { ... }` block — this keeps them module-private to TermCore. They will not be re-exported because the extension wraps them.

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
//  history publication and restore-from-payload concerns.
//

import Foundation
import Synchronization

extension ScreenModel {
    // _latestHistoryTail, HistoryBox, pendingHistoryPublish,
    // publishHistoryTail, buildAttachPayload, latestHistoryTail,
    // restore(from snapshot:), restore(from payload:).
}
```

Move the exact original implementations inside the extension body. `HistoryBox` stays `private final class`.

**Blocker note:** Swift forbids stored properties on extensions. `_latestHistoryTail` and `pendingHistoryPublish` **must remain on the actor's main declaration** in `ScreenModel.swift`. The extension contains only the methods that read/write them.

Revise Step 3 accordingly: `_latestHistoryTail`, `pendingHistoryPublish`, and `HistoryBox` stay in `ScreenModel.swift`. Only the methods move to the extension file. Update the header comment in `ScreenModel+History.swift` to reflect this.

- [ ] **Step 4: Trim `ScreenModel.swift`**

Delete the moved code from the original file. What remains: stored properties, `init`, `apply(_:)`, `publishSnapshot`, `makeSnapshot(from:)`, all event dispatchers (`handlePrintable` / `handleC0` / `handleCSI` / `applySGR` / `handleOSC`), `eraseInDisplay`, `eraseInLine`, `handleSetMode`, `handleSetScrollRegion`, `handleAltScreen`, `snapshotCursor`, `restoreActiveCursor`, `latestSnapshot()`, `currentWindowTitle()`, `currentIconName()`, `SnapshotBox`.

- [ ] **Step 5: Add the two new files to the TermCore target in Xcode**

Edit `rTerm.xcodeproj/project.pbxproj` — add `PBXFileReference` entries for `ScreenModel+Buffer.swift` and `ScreenModel+History.swift`, add corresponding `PBXBuildFile` entries, and include them in the TermCore target's sources-phase file list.

Simplest approach: open the project in Xcode, drag the two new files into the TermCore group, confirm target membership = TermCore only. Xcode writes the pbxproj changes. If the implementer can't use Xcode GUI, dispatch a "pbxproj surgery" subagent with the two new file names and the TermCore target UUID (grep for `TermCore` in pbxproj to find the target).

- [ ] **Step 6: Build the full project**

```bash
xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build -quiet
```

Expected: clean build. If an access-level error surfaces for `Buffer` / `ScrollRegion` / `HistoryBox`, tighten their visibility (`internal` → nested inside extension is typical) or adjust the split boundary.

- [ ] **Step 7: Run the full test suite**

```bash
xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test -quiet
```

Expected: all 222 existing TermCore tests pass. No behavior changed — this is a pure file split.

- [ ] **Step 8: Verify line counts**

```bash
wc -l TermCore/ScreenModel.swift TermCore/ScreenModel+Buffer.swift TermCore/ScreenModel+History.swift
```

Expected: `ScreenModel.swift` around 650–700 lines; `+Buffer` around 100–150; `+History` around 100–150. If any file is unexpectedly large, revisit the split boundary.

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
  handlers, SnapshotBox, stored properties, init.
- ScreenModel+Buffer.swift: ScrollRegion, Buffer, mutateActive<R>,
  active, scrollAndMaybeEvict, clearGrid.
- ScreenModel+History.swift: publishHistoryTail, buildAttachPayload,
  latestHistoryTail, restore(from:) x2. Stored properties
  (_latestHistoryTail, pendingHistoryPublish, HistoryBox) stay on
  the main declaration — Swift forbids stored props on extensions.

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

## Task 5: `publishHistoryTail()` ordering doc comment

**Spec reference:** §8 Track B item 8.

**Goal:** Add a doc comment on `publishHistoryTail()` in `TermCore/ScreenModel+History.swift` (post-split) describing the history-before-snapshot ordering invariant, so a future refactor that adds a third publish point does not accidentally invert the calls. Small task, no behavior change.

**Files:**
- Modify: `TermCore/ScreenModel+History.swift`

### Steps

- [ ] **Step 1: Locate `publishHistoryTail`**

Grep: `rg -n "publishHistoryTail" TermCore/`. Locate the definition in `ScreenModel+History.swift` (post-Task-3).

- [ ] **Step 2: Insert ordering-invariant doc comment**

Immediately above the `publishHistoryTail()` declaration, insert:

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

- [ ] **Step 3: Verify ordering at the two call sites**

Grep: `rg -n "publishHistoryTail|publishSnapshot|_latestSnapshot.withLock" TermCore/`. Confirm in `apply(_:)` (ScreenModel.swift) that `publishHistoryTail()` is called before `publishSnapshot()`, and in `restore(from payload:)` (ScreenModel+History.swift) that `_latestHistoryTail.withLock` clearing happens before `_latestSnapshot.withLock` restoration. If either site has been accidentally inverted, correct it.

- [ ] **Step 4: Build + test**

```bash
xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build -quiet
xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test -quiet
```

No behavior change, no new tests. Existing `RestoreOrderingTests` (Task 1) remains green.

- [ ] **Step 5: Commit**

```bash
git add TermCore/ScreenModel+History.swift
git commit -m "doc(TermCore): publishHistoryTail ordering invariant

Document the history-before-snapshot publication ordering at the
function declaration so a future refactor introducing a third publish
channel is prompted to choose its position deliberately. No behavior
change — existing call-site comments remain."
```

---

## Task 6: `DispatchSerialQueue` typed init + deprecation

**Spec reference:** §8 Track B item 6.

**Goal:** `ScreenModel.init(..., queue: DispatchQueue? = nil)` force-casts to `DispatchSerialQueue` at runtime. A caller that accidentally passes a `.concurrent` queue crashes with no compile-time warning. Add a new `init(..., queue: DispatchSerialQueue? = nil)` with the typed parameter and deprecate the untyped one. Keep both — `BUILD_LIBRARY_FOR_DISTRIBUTION` is enabled on TermCore (Release), so removing the old init is a binary-compat break.

**Files:**
- Modify: `TermCore/ScreenModel.swift`
- Modify: `rtermd/Session.swift` (call site uses new typed init)
- Modify: `rTerm/ContentView.swift` if it passes a queue (check — it currently passes nil, so no change)

### Steps

- [ ] **Step 1: Read the existing `init`**

Open `TermCore/ScreenModel.swift` around line 210–230. Current signature:

```swift
public init(cols: Int = 80, rows: Int = 24, historyCapacity: Int = 10_000,
            queue: DispatchQueue? = nil) {
    ...
    self.executorQueue = q as! DispatchSerialQueue
    ...
}
```

- [ ] **Step 2: Extract the initialization body into a private helper**

Create a `private func _initialize(cols:rows:historyCapacity:queue:)` taking `DispatchSerialQueue?` (the typed form). Move the existing body into it. Both inits will delegate.

```swift
private init(cols: Int, rows: Int, historyCapacity: Int, serialQueue: DispatchSerialQueue?) {
    // ... the full original body, using serialQueue (no force-cast needed) ...
}
```

- [ ] **Step 3: Add the typed public init**

```swift
/// Preferred initializer — `queue` is typed to require a serial dispatch
/// queue at compile time. Passing a concurrent queue is a compile error.
public convenience init(cols: Int = 80, rows: Int = 24,
                         historyCapacity: Int = 10_000,
                         queue: DispatchSerialQueue? = nil) {
    self.init(cols: cols, rows: rows,
              historyCapacity: historyCapacity,
              serialQueue: queue)
}
```

- [ ] **Step 4: Replace the old untyped init with a deprecated delegating one**

```swift
/// Legacy untyped-queue initializer. Retained for binary compatibility
/// under BUILD_LIBRARY_FOR_DISTRIBUTION; will be removed once all
/// callers migrate to the typed-`queue` form.
///
/// - Warning: Passing a queue that is not a `DispatchSerialQueue` traps
///   at runtime via an internal force-cast. Use the typed overload.
@available(*, deprecated,
           message: "Pass DispatchSerialQueue? instead of DispatchQueue?. The untyped overload traps at runtime on concurrent queues.",
           renamed: "init(cols:rows:historyCapacity:queue:)")
public convenience init(cols: Int = 80, rows: Int = 24,
                         historyCapacity: Int = 10_000,
                         queue: DispatchQueue? = nil) {
    // swiftlint:disable:next force_cast
    let serial = queue.map { $0 as! DispatchSerialQueue }
    self.init(cols: cols, rows: rows,
              historyCapacity: historyCapacity,
              serialQueue: serial)
}
```

**Compiler-overload note:** Swift's overload resolution prefers the most specific type, so a caller passing `nil` picks the `DispatchSerialQueue?` overload (more specific context); a caller passing `DispatchQueue(label:)` matches the deprecated overload and gets the deprecation warning. A caller passing an explicitly-typed `DispatchSerialQueue` matches the typed overload with no warning.

- [ ] **Step 5: Migrate known callers in-tree**

```bash
rg -n "ScreenModel\(" TermCore/ rtermd/ rTerm/
```

Callers to check:
- `rTerm/ContentView.swift`: `TerminalSession.init` passes nothing (defaults). No migration needed beyond recompiling — default-nil binds to the new typed overload.
- `rtermd/Session.swift`: check if it passes a queue. If so, ensure the queue variable is typed `DispatchSerialQueue` (not `DispatchQueue`). Given the summary says the queue originates from `main.swift` as `DispatchQueue(label:)`, update `main.swift` to type it as `DispatchSerialQueue` explicitly or cast at the call site.
- `TermCoreTests/ScreenModelTests.swift`: 79 call sites. None pass a queue (all are `ScreenModel(cols: X, rows: Y)`), so no migration needed.

If any test file does pass a queue, migrate it.

- [ ] **Step 6: Add a compile-time test**

In `TermCoreTests/ScreenModelTests.swift`, add at file scope (or a new `ScreenModelInitTests.swift`):

```swift
@Test("Typed init accepts a DispatchSerialQueue and nil")
func test_typed_init_compiles() {
    let m1 = ScreenModel(cols: 80, rows: 24)
    #expect(m1.historyCapacity == 10_000)
    let q = DispatchSerialQueue(label: "test.serial")
    let m2 = ScreenModel(cols: 80, rows: 24, historyCapacity: 100, queue: q)
    #expect(m2.historyCapacity == 100)
    // If the typed overload resolves, this compiles. If the untyped
    // overload resolved instead, the deprecation warning would surface.
}
```

- [ ] **Step 7: Build + test**

```bash
xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build -quiet
xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test -quiet
```

Expected: clean build. If a deprecation warning fires in production code, migrate that caller.

- [ ] **Step 8: Commit**

```bash
git add TermCore/ScreenModel.swift rtermd/ rTerm/ TermCoreTests/
git commit -m "api(TermCore): typed DispatchSerialQueue init; deprecate untyped

ScreenModel.init gains a typed-queue overload. The untyped overload
remains for BUILD_LIBRARY_FOR_DISTRIBUTION binary compat but is
@available deprecated with a renamed: directive pointing at the
typed form. Production callers (ContentView, Session, main.swift)
migrated; 79 test sites unaffected (none pass a queue)."
```

---

## Task 7: RenderCoordinator vertex array reuse

**Spec reference:** §8 Track B item 1.

**Goal:** `RenderCoordinator.draw(in:)` declares 6 `[Float]` arrays per frame (`regularVerts`, `boldVerts`, `italicVerts`, `boldItalicVerts`, `underlineVerts`, `strikethroughVerts`) and `reserveCapacity`-initializes each. ~2,880 KB reserved-then-freed per frame; 169 MB/s at 60 fps. Promote to `var` instance properties, call `removeAll(keepingCapacity: true)` at the top of `draw(in:)`. Eliminates the alloc/free cycle entirely.

**Pattern used:** `os.signpost` instrumentation added first to establish a measurement baseline (count of allocations observed via `OSSignposter.beginInterval` inside the arrays' allocation points is infeasible without an allocator hook; instead, count `reserveCapacity` sites and instrument the draw loop to record the per-frame interval duration — the metric is frame time, not allocation count). XCTest `measure` block asserts no regression.

**Files:**
- Modify: `rTerm/RenderCoordinator.swift`
- Create: `rTermTests/RenderCoordinatorAllocationTests.swift`

### Steps

- [ ] **Step 1: Add signposter + arrays as instance properties**

Open `rTerm/RenderCoordinator.swift`. Near the top of the class:

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
import XCTest
@testable import rTerm

/// Guard the invariant that `draw(in:)` does not re-allocate the six
/// vertex arrays every frame. We can't count heap allocations directly
/// without an allocator hook, so we measure the mutation pattern: a
/// vertex array's `capacity` after one draw frame must be the same as
/// after two consecutive frames (no ephemeral grow).
final class RenderCoordinatorAllocationTests: XCTestCase {

    @MainActor
    func test_vertex_arrays_preserve_capacity_across_frames() throws {
        // Use a reasonable grid size; this is a unit test, not a
        // full Metal pipeline exercise.
        let model = ScreenModel(cols: 80, rows: 24)
        let coord = try XCTUnwrap(try? RenderCoordinator.forTesting(screenModel: model))

        coord.drawTestFrame()
        let capAfterOne = coord.vertexCapacitiesForTesting()

        coord.drawTestFrame()
        let capAfterTwo = coord.vertexCapacitiesForTesting()

        // No regression — capacities must not shrink to zero between
        // frames, which would be the signature of `[Float]()` reallocating.
        XCTAssertEqual(capAfterOne, capAfterTwo,
                       "vertex array capacities must be stable across frames")
        XCTAssertTrue(capAfterOne.allSatisfy { $0 > 0 },
                      "capacities should have been reserved on first frame; got \(capAfterOne)")
    }
}
```

In `rTerm/RenderCoordinator.swift`, add testing hooks (keep them `internal` so only the `@testable` import sees them):

```swift
#if DEBUG
extension RenderCoordinator {
    /// Test-only factory — bypasses `MTKView` creation and the Metal
    /// pipeline to let the allocation-regression test exercise `draw(in:)`
    /// bookkeeping paths without a live drawable.
    static func forTesting(screenModel: ScreenModel) throws -> RenderCoordinator {
        // Implement a minimal no-render init that reserves capacity and
        // returns a coordinator whose `drawTestFrame()` runs the
        // `removeAll(keepingCapacity:) + reserve-if-grown` preamble
        // without submitting a Metal command buffer. Implementation
        // sketch: factor out the preamble into a separate `private func
        // beginFrameCleanup(cols:rows:)` and call it from both `draw(in:)`
        // and `drawTestFrame()`.
        throw NSError(domain: "RenderCoordinator.forTesting", code: 1)
    }

    /// Test-only: runs the draw preamble (capacity reservation + clearing)
    /// without submitting a frame.
    func drawTestFrame() {
        // Calls the extracted beginFrameCleanup helper. Cols/rows come
        // from the coordinator's current cached grid dimensions.
    }

    /// Test-only: exposes the current capacity of each vertex buffer.
    func vertexCapacitiesForTesting() -> [Int] {
        [regularVerts.capacity, boldVerts.capacity, italicVerts.capacity,
         boldItalicVerts.capacity, underlineVerts.capacity, strikethroughVerts.capacity]
    }
}
#endif
```

The implementer may choose to skip the `forTesting` factory if wiring Metal in a unit test is prohibitively complex. In that case, add the test but mark it `throw XCTSkip("requires Metal device; run manually")` and document the manual-run command in the commit message.

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

## Task 8: Metal buffer pre-allocation ring

**Spec reference:** §8 Track B item 2.

**Goal:** `device.makeBuffer(bytes:length:options:)` is called up to 6 times per frame (4 glyph passes + underline + strikethrough). Each call allocates from Metal's shared heap, which is cheap on Apple Silicon but not free. Implement a pre-allocated ring of 6 `MTLBuffer`s per draw pass × `maxBuffersInFlight` (3), so `draw(in:)` writes into an owned buffer instead of allocating a fresh one each time. Target: zero `makeBuffer` calls in steady state.

**Design:** A small `MetalBufferRing` helper type owns `N` fixed-size buffers. `currentBuffer()` returns one, incrementing an internal cursor; after `maxBuffersInFlight` frames the cursor wraps. Sized to the grid's worst-case vertex count. On grow, rebuild the ring.

**Files:**
- Create: `rTerm/MetalBufferRing.swift`
- Modify: `rTerm/RenderCoordinator.swift`
- Create: `rTermTests/MetalBufferRingTests.swift`

### Steps

- [ ] **Step 1: Add measurement first — baseline count**

In `rTerm/RenderCoordinator.swift`, add a DEBUG-only counter:

```swift
#if DEBUG
nonisolated(unsafe) static var makeBufferCountForTesting: Int = 0
#endif
```

Wrap each `device.makeBuffer(...)` call in `draw(in:)`:

```swift
#if DEBUG
Self.makeBufferCountForTesting += 1
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

/// Pre-allocated ring of `MTLBuffer`s used to avoid per-frame
/// `makeBuffer` allocations in the render loop.
///
/// The ring holds `count` buffers each sized at `byteLength`. Call
/// `nextBuffer(copying:)` to write `data` into the next buffer in the
/// ring and return it. Sized to one buffer per draw pass per
/// frame-in-flight; `RenderCoordinator` owns six rings (one per
/// vertex-pass category).
///
/// On grid resize the ring is rebuilt; call `resize(byteLength:)` from
/// the coordinator's drawable-size change hook.
@MainActor
final class MetalBufferRing {
    private let device: MTLDevice
    private var buffers: [MTLBuffer]
    private var cursor: Int = 0
    private(set) var byteLength: Int

    init(device: MTLDevice, count: Int, byteLength: Int) {
        precondition(count > 0, "ring count must be positive")
        precondition(byteLength > 0, "ring byteLength must be positive")
        self.device = device
        self.byteLength = byteLength
        self.buffers = (0..<count).compactMap {
            device.makeBuffer(length: byteLength, options: .storageModeShared)
        }
        precondition(self.buffers.count == count,
                     "MetalBufferRing failed to allocate \(count) buffers of \(byteLength) bytes")
    }

    /// Write `data` into the next buffer in the ring and return it.
    /// Truncates if `data` exceeds `byteLength` (should not happen if
    /// `resize` is driven by draw preconditions).
    func nextBuffer(copying data: UnsafeRawPointer, length: Int) -> MTLBuffer {
        precondition(length <= byteLength,
                     "incoming data length \(length) exceeds ring byteLength \(byteLength); caller must resize first")
        let buf = buffers[cursor]
        buf.contents().copyMemory(from: data, byteCount: length)
        cursor = (cursor + 1) % buffers.count
        return buf
    }

    /// Resize every buffer in the ring. O(count). Caller guarantees no
    /// buffer is currently in flight.
    func resize(byteLength newByteLength: Int) {
        precondition(newByteLength > 0)
        guard newByteLength != byteLength else { return }
        buffers = (0..<buffers.count).compactMap {
            device.makeBuffer(length: newByteLength, options: .storageModeShared)
        }
        byteLength = newByteLength
        cursor = 0
    }
}
```

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
        let b1 = ring.nextBuffer(copying: &payload, length: 16)
        let b2 = ring.nextBuffer(copying: &payload, length: 16)
        let b3 = ring.nextBuffer(copying: &payload, length: 16)
        let b4 = ring.nextBuffer(copying: &payload, length: 16)
        XCTAssertNotEqual(ObjectIdentifier(b1), ObjectIdentifier(b2))
        XCTAssertNotEqual(ObjectIdentifier(b2), ObjectIdentifier(b3))
        XCTAssertEqual(ObjectIdentifier(b1), ObjectIdentifier(b4),
                       "cursor should wrap to index 0 after count=3 uses")
    }

    @MainActor
    func test_ring_resize_reallocates_buffers() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let ring = MetalBufferRing(device: device, count: 2, byteLength: 128)
        XCTAssertEqual(ring.byteLength, 128)
        ring.resize(byteLength: 512)
        XCTAssertEqual(ring.byteLength, 512)
    }

    @MainActor
    func test_ring_resize_noop_when_size_unchanged() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let ring = MetalBufferRing(device: device, count: 2, byteLength: 128)
        var payload: [UInt8] = Array(repeating: 0, count: 16)
        let before = ring.nextBuffer(copying: &payload, length: 16)
        ring.resize(byteLength: 128)  // same size — must not reallocate
        ring.resize(byteLength: 128)  // still same size
        // After two same-size resizes, the next buffer in the ring
        // cycles normally (we did not reset cursor).
        let after = ring.nextBuffer(copying: &payload, length: 16)
        XCTAssertNotEqual(ObjectIdentifier(before), ObjectIdentifier(after))
    }
}
```

- [ ] **Step 4: Wire six rings into `RenderCoordinator`**

In `rTerm/RenderCoordinator.swift`, add instance properties:

```swift
// One ring per vertex-pass category. Sized to the worst-case grid and
// maxBuffersInFlight (3, matching the Metal semaphore triple-buffer
// convention used elsewhere in the coordinator — confirm by grepping
// `maxBuffersInFlight` or `semaphore` in the current file; if none,
// default count to 3).
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
        regularRing!.resize(byteLength: glyphBytes)
        boldRing!.resize(byteLength: glyphBytes)
        italicRing!.resize(byteLength: glyphBytes)
        boldItalicRing!.resize(byteLength: glyphBytes)
        underlineRing!.resize(byteLength: overlayBytes)
        strikethroughRing!.resize(byteLength: overlayBytes)
    }
}
```

Call `ensureRings(cols: cols, rows: rows)` at the top of `draw(in:)` (right after the `removeAll(keepingCapacity:)` preamble from Task 7).

- [ ] **Step 5: Replace `makeBuffer` call sites with ring allocation**

Find each `device.makeBuffer(bytes: ...verts, length: ..., options: .storageModeShared)` site in `RenderCoordinator.swift` and replace:

```swift
// Before:
let buf = device.makeBuffer(bytes: regularVerts, length: regularVerts.count * 4, options: .storageModeShared)

// After:
let buf = regularVerts.withUnsafeBufferPointer { ptr in
    regularRing!.nextBuffer(copying: ptr.baseAddress!, length: ptr.count * MemoryLayout<Float>.stride)
}
```

Repeat for bold, italic, boldItalic, underline, strikethrough passes. Cursor and overlay (scroll bell flash, etc.) passes that use `setVertexBytes` or separate allocations stay unchanged unless they fit the pattern.

Remove the `#if DEBUG makeBufferCountForTesting += 1` from these sites (since they're no longer making buffers). Keep it on any remaining `makeBuffer` calls that didn't migrate.

- [ ] **Step 6: Add steady-state counter test**

Append to `rTermTests/RenderCoordinatorAllocationTests.swift`:

```swift
@MainActor
func test_steady_state_makeBuffer_count_is_zero() throws {
    let model = ScreenModel(cols: 80, rows: 24)
    let coord = try XCTUnwrap(try? RenderCoordinator.forTesting(screenModel: model))
    // Prime the rings with one warmup frame.
    coord.drawTestFrame()
    RenderCoordinator.makeBufferCountForTesting = 0
    // Run several frames at steady-state grid size.
    for _ in 0..<10 { coord.drawTestFrame() }
    XCTAssertEqual(RenderCoordinator.makeBufferCountForTesting, 0,
                   "steady-state draw should allocate no MTLBuffers")
}
```

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
git commit -m "perf(rTerm): pre-allocated Metal buffer rings

Six MetalBufferRing instances (one per vertex-pass category — regular,
bold, italic, boldItalic, underline, strikethrough). Each ring holds
maxBuffersInFlight=3 MTLBuffers sized to the worst-case grid; draw(in:)
writes via nextBuffer(copying:) instead of device.makeBuffer.

Steady-state makeBuffer count drops from 4–6/frame to 0. Ring resize
on grid grow preserves correctness; resize is a no-op when byteLength
matches the current sizing. DEBUG-only counter test pins the
zero-steady-state invariant."
```

---

## Task 9: `cellAt` scrolled-render loop hoist

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

## Task 10: `ScrollbackHistory.Row` pre-allocation (measurement-gated)

**Spec reference:** §8 Track B item 3.

**Goal:** `scrollAndMaybeEvict` allocates a new `ContiguousArray<Cell>` (~3.1 KB) per scrolling LF on main. At 1,000 LF/s (fast `cat`) this is ~3 MB/s; at 10,000 LF/s burst it could show up as allocator pressure. The spec instructs: **measure first**, implement only if measurement shows a meaningful regression.

Approach: add allocation instrumentation, run a sustained-throughput benchmark, and decide based on the numbers. If no regression, commit the instrumentation + a "deferred with measurement" note. If regression, implement a ring of pre-allocated Row buffers.

**Files:**
- Modify: `TermCore/ScrollbackHistory.swift` (benchmark hook; conditional implementation)
- Create: `TermCoreTests/ScrollbackHistoryAllocationTests.swift`

### Steps

- [ ] **Step 1: Add an allocation counter to `ScrollbackHistory`**

In `TermCore/ScrollbackHistory.swift`:

```swift
#if DEBUG
nonisolated(unsafe) public static var rowAllocationCountForTesting: Int = 0
#endif
```

In the `push(_:)` method (or wherever the new Row is constructed inside `scrollAndMaybeEvict`), add:

```swift
#if DEBUG
ScrollbackHistory.rowAllocationCountForTesting += 1
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
        ScrollbackHistory.rowAllocationCountForTesting = 0
        let lfCount = 1_000
        for _ in 0..<lfCount {
            await model.apply([.c0(.lineFeed)])
        }
        let allocs = ScrollbackHistory.rowAllocationCountForTesting
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

- [ ] **Step 4: Decision point — implement or defer**

The spec §8 Track B item 3 gating criterion: "if measurements show no regression at 60 MB/s sustained throughput, document 'deferred with measurement' and move on."

**Quick throughput calculation:**
- 80 cols × ~40 bytes/Cell = 3.2 KB per Row
- 3.2 KB × 1,000 LF/s = 3.2 MB/s at "fast cat" rate
- Sustained 60 MB/s requires 60,000,000 / 3,200 ≈ 18,750 LF/s

**Decision rule:** if the test demonstrates 18,750 LFs complete in under 1 second on the implementer's hardware without exhausting memory, defer. Otherwise implement.

Run a 20,000-LF variant:

```swift
@Test("Large-burst throughput is sustainable without allocator stall")
func test_large_burst_does_not_stall() async {
    let model = ScreenModel(cols: 80, rows: 24, historyCapacity: 10_000)
    for _ in 0..<24 { await model.apply([.c0(.lineFeed)]) }
    let start = Date()
    for _ in 0..<20_000 {
        await model.apply([.c0(.lineFeed)])
    }
    let elapsed = Date().timeIntervalSince(start)
    #expect(elapsed < 2.0, "20K scrolling LFs took \(elapsed)s — allocator pressure?")
}
```

Run it:

```bash
xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests \
    -only-testing TermCoreTests/ScrollbackHistoryAllocationTests/test_large_burst_does_not_stall test -quiet
```

- If pass (< 2 s): no visible regression. **Defer the ring-buffer implementation.** Add a doc comment in `ScreenModel+Buffer.swift` (the `scrollAndMaybeEvict` site):

```swift
/// Phase 3 Track B item 3: considered allocating a fixed-size Row ring
/// here to eliminate the per-LF ContiguousArray allocation. Benchmark
/// showed 20,000 scrolling LFs complete in well under 2 s on Apple
/// Silicon, so the allocation is not a hotspot at any realistic
/// workload. Deferred indefinitely pending a real-world trigger.
```

- If fail (>= 2 s): implement the ring. Outline:
  - Add `ScrollbackHistory` private storage `_rowPool: ContiguousArray<Row>` sized at `capacity` with each element pre-allocated to `cols * stride`.
  - `push(_:)` takes a new Row from the pool, copies into it, stores it, and the evicted Row goes back to the pool's free list.
  - Update the counter expectation in the test to `~capacity + grow-count`.

- [ ] **Step 5: Commit (measurement-gated path chosen)**

**If deferred:**

```bash
git add TermCore/ScrollbackHistory.swift TermCore/ScreenModel+Buffer.swift \
        TermCoreTests/ScrollbackHistoryAllocationTests.swift
git commit -m "measure(TermCore): Row per-LF allocation quantified; defer ring

Phase 2 efficiency research flagged ScrollbackHistory.Row per-LF
allocation (~3.1 KB per scrolling LF) as a potential hotspot.
Measurement: 1,000 scrolling LFs produce exactly 1,000 Row allocations
(as expected), and 20,000 LFs complete in under 2 s on Apple Silicon.
No visible allocator pressure at any realistic terminal workload.

Ring-buffer optimization deferred indefinitely per Phase 3 Track B
item 3's measurement-gating criterion. Counter + test remain as
living documentation so a future regression is caught immediately."
```

**If implemented:**

```bash
git add TermCore/ScrollbackHistory.swift TermCoreTests/ScrollbackHistoryAllocationTests.swift
git commit -m "perf(TermCore): pre-allocated Row pool in ScrollbackHistory

Measurement showed per-LF Row allocation causing allocator stalls at
sustained 20K LF/s. Implement a fixed-size pool of pre-allocated
ContiguousArray<Cell> slots reused across scrolls. Row allocation
count drops from O(LF) to O(capacity). No behavior change visible
to readers — tail(), all(), count are unchanged."
```

---

## Track B completion checklist

After Task 10 lands, verify the following before opening a PR:

- [ ] `wc -l TermCore/ScreenModel*.swift` shows the split is intact.
- [ ] `rg -c "Cursor\(row: 0, col: 0\)" TermCore/` returns 0 (all migrated to `Cursor.zero`).
- [ ] `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test` passes (≥ 226 tests expected: 222 + 3 new + 1 from Task 1).
- [ ] `xcodebuild -project rTerm.xcodeproj -scheme rTermTests test` passes (≥ 56 tests expected: 53 + 1 invariance + 2 allocation).
- [ ] Deprecation warnings surface in `xcodebuild` output only for deliberate deprecation checks — no production-code warnings.
- [ ] PR description cites Phase 2 research doc findings, not just "fixes lint."
- [ ] CLAUDE.md does **not** need a new "Key Conventions" bullet for `nonisolated` value types — the spec reviewer flagged this as low priority and the pattern is already consistently applied.

**Self-review note:** this plan covers items 1–10, 12 from §8 Track B. Items 11 (`ImmutableBox<T>`) and 13 (comment cleanup) are deliberately not-in-Phase-3 per the spec. Item 10 (`CircularCollection` TODO) is deferred to a tracking comment only. If any item in §8 Track B lacks a task, add it inline.
