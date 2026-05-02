# Control-Characters Phase 3 — Track A Features Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Prerequisite:** Track B hygiene (plan `2026-05-02-control-chars-phase3-hygiene.md`) must be landed on `main` before this plan begins. Track B delivers the `ScreenModel` file split, `TerminalStateSnapshot` extraction, Metal buffer ring, and typed `DispatchSerialQueue` init that Track A work builds on.

**Goal:** Land the Phase 3 feature scope — OSC 8 hyperlinks, OSC 52 clipboard set path, DECSCUSR cursor shape, blink rendering, DA1/DA2/CPR terminal-ID responses, DECOM origin mode, DECCOLM 132-column mode, `iconName` snapshot exposure, palette chooser UI.

**Architecture:** Parser emits new typed CSI/OSC variants. `ScreenModel` stores mode state and hyperlink pen. A new "writeback" path lets `ScreenModel` emit bytes destined for the PTY primary — DA1/DA2/CPR responses flow through `DaemonResponse.writeback(sessionID:data:)` (new XPC case) which the daemon routes to the PTY write end. OSC 52 clipboard flows through `DaemonResponse.clipboardWrite(sessionID:target:payload:)` (new XPC case) routed to `NSPasteboard` under a user-consent gate. Renderer gains a blink uniform, cursor-shape variant, and hyperlink hover/click handling.

**Tech Stack:** Swift 6, Swift Testing (`@Test` / `#expect`), XPC (`import XPC`), AppKit (`NSPasteboard`, `NSWorkspace`), Metal, `os.signpost`.

**Execution contract:** Identical to prior phases.
- Every implementer task ends with `git commit`. Implementers do not run `xcodebuild`.
- Implementer-facing checkboxes that mention build/test commands are documentation for the controller's verification pass.
- After each commit, the controller dispatches `agentic:xcode-build-reporter` to run the relevant tests and verify a clean build.
- If the report shows failures, the controller re-dispatches the implementer with a fix-focused prompt.
- After the build reporter passes, the controller dispatches spec-compliance and code-quality reviewers per `superpowers:subagent-driven-development`. Only then is the task marked complete and `/simplify` is invoked before the next task.

**Task dependency map.** Track A tasks must land in the order rows appear — a remediation pass that parallelizes would hit compile errors at shared enum / struct extension points (`CSICommand`, `OSCCommand`, `ScreenSnapshot`, `TerminalModes`).

| Task | Depends on | Delivers | Parallelizable with |
|------|-----------|----------|---------------------|
| T1 | Track B | `ScreenModelOutput` enum + `installOutputSink` + `.ptyWriteback` daemon path | — |
| T2 | T1 | DA1 + DA2 + CPR parser cases + writeback replies | T5, T6, T7 once landed |
| T3 | T1, Track B T4 (`Cursor.zero`) | DECSCUSR parser + model state + renderer shape | T5, T6, T7 once landed |
| T4 | T3 (needs `cursorShape` state), Track B T4 (TerminalState convenience init) | `cursorShape` + `iconName` fields on `ScreenSnapshot` + Codable back-compat | T5, T6, T7 once landed |
| T5 | Track B (renderer prerequisites) | Blink fragment-shader uniform | T2, T3, T6, T7 |
| T6 | T1 (adds `TerminalModes.originMode`) | DECOM origin-mode translation | T2, T3, T5, T7 (enum-case sequencing) |
| T7 | T6 (references `originMode` reset) | DECCOLM 132-column + 4-side-effect reset | — (serialize after T6) |
| T8 | Track B (Codable convention) | OSC 8 parser + `Hyperlink` value + `CellStyle.hyperlink` + pen state | — |
| T9 | T8 (reads `cell.style.hyperlink`) | OSC 8 hover + click + `NSWorkspace` URI open | — |
| T10 | T1 (reuses `ScreenModelOutput` + `installOutputSink`) | OSC 52 set path + consent prompt + NSPasteboard; grows `ScreenModelOutput` with `.clipboardWrite` and the daemon switch with the matching arm | T8, T9 |
| T11 | Track B T4 (AppSettings palette field), Phase 2 renderer | Palette chooser Settings scene + preset lookup | — |

Within Track A, the rule is: **never start a task whose "Depends on" row has not landed.** T2/T3/T4 all wire into `CSICommand.swift` + `ScreenModel.handleCSI`; landing them out of order causes merge conflicts at the enum-case addition site. T6/T7 similarly wire into `DECPrivateMode.swift` + `handleSetMode`.

---

## Task 1: Unified `ScreenModelOutput` sink + PTY writeback infrastructure

**Spec reference:** §8 Phase 3 Track A — Terminal identification responses prelude.

**Goal:** The daemon must accept output events originating from `ScreenModel` (writeback bytes in response to DA1/DA2/CPR; later phases add clipboard writes from OSC 52, focus events, etc.) and route each to the appropriate destination. Today the daemon only receives bytes from the shell and from the client's keyboard input. Introduce **one** typed output enum + one installer on `ScreenModel` so every future side-effect event is a new enum case, not a new `@Sendable` property. Task 1 ships the enum with a single case:

```swift
public enum ScreenModelOutput: Sendable {
    /// PTY-writeback bytes (DA1, DA2, CPR, future DSR, XtSmGraphics,
    /// terminal parameters, …). Daemon writes directly to the PTY
    /// primary and fans out on the writeback XPC case.
    case ptyWriteback(Data)

    // Phase 3 Task 10 extends this enum with `.clipboardWrite(...)`
    // alongside the `ClipboardTargets` struct it depends on. Phase 4
    // adds e.g. `.osc4ColorReply`, `.focusEvent`, …
}
```

**Why unified?** Reference terminals converge on a single output stream:
- wezterm (`~/dev/public/wezterm/term/src/terminalstate/mod.rs:356`): `writer: BufWriter<ThreadedWriter>` — every emission (DA1 line 1296, DA2 1311, DA3 1316, status 1336, focus 788–789, keyboard 843–844) flows through `self.writer.write(...)`.
- iTerm2 (`~/rdev/iTerm2/sources/VT100TerminalDelegate.h:112`): one delegate method `- (void)terminalSendReport:(NSData *)report` for all non-clipboard writeback. A specialized variant routes OSC 4 color reports; even then, signature-identical.
- Terminal.app (`~/dev/swe/terminal/TTVT100Emulator.m`): every DA1/DA2/CPR/status/keyboard reply routes through `[_shell writeData:]`.

Splitting `ScreenModel` output into separate `_writebackSink`/`_clipboardSink` per kind would invite a third sink the moment Phase 4 adds OSC 4 replies. Collapsing to one typed enum means future kinds are one-line enum additions.

**Task 1 delivers:** `ScreenModelOutput` enum (single-case: `.ptyWriteback(Data)`), `ScreenModel.installOutputSink(_:)`, `emitOutput(_:)`, the writeback case routed through `Session` + the `DaemonResponse.writeback` XPC push. Task 10 (OSC 52) grows the enum with `.clipboardWrite(...)` — alongside the `ClipboardTargets` definition it depends on — and extends the daemon's output-handler switch with one matching arm.

For convenience at call sites that only emit writeback bytes, expose a thin wrapper `emitWriteback(_ data: Data)` that forwards to `emitOutput(.ptyWriteback(data))`.

**Files:**
- Modify: `TermCore/DaemonProtocol.swift` (add `.writeback` case)
- Create: `TermCore/ScreenModelOutput.swift` (new enum + its `Sendable` conformance)
- Modify: `TermCore/ScreenModel.swift` (add `_outputSink` + `installOutputSink(_:)` + `emitOutput(_:)` + `emitWriteback` wrapper)
- Modify: `rtermd/Session.swift` (install sink from within `startOutputHandler()`'s `assumeIsolated` block; switch on the event, write writeback bytes to PTY primary, broadcast XPC)
- Create: `TermCoreTests/ScreenModelOutputTests.swift`

### Steps

- [ ] **Step 1: Create `ScreenModelOutput` + add XPC response case**

Create `TermCore/ScreenModelOutput.swift`:

```swift
//
//  ScreenModelOutput.swift
//  TermCore
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

import Foundation

/// Typed output events originating inside `ScreenModel`. A single
/// `installOutputSink` pair hosts every model-originated side effect;
/// adding a new kind is a new enum case, not a new `@Sendable` sink
/// property. Reference-terminal consensus (wezterm `self.writer`,
/// iTerm2 `terminalSendReport:`, Terminal.app `[_shell writeData:]`):
/// one typed output channel.
public enum ScreenModelOutput: Sendable {
    /// PTY-writeback bytes — DA1/DA2/CPR today; DSR / XtSmGraphics /
    /// terminal parameters / focus events in later phases. The daemon
    /// writes directly to the PTY primary and fans out on the
    /// `DaemonResponse.writeback` XPC push so mirrored clients see
    /// the inbound bytes.
    case ptyWriteback(Data)

    // Phase 3 Task 10 extends this enum with `.clipboardWrite(targets:
    // base64Payload:)` once `ClipboardTargets` is defined. Phase 4 adds
    // further cases (focus events, OSC 4 color replies, …).
}
```

In `TermCore/DaemonProtocol.swift`, add a new case to `DaemonResponse`:

```swift
/// Emitted when the daemon (or the model inside it) originates a byte
/// write to the PTY primary — typically a DA1/DA2/CPR reply to a shell
/// query. Clients do NOT have to act on this; the daemon has already
/// performed the write. It is pushed to attached clients so their local
/// ScreenModel mirrors stay consistent if they also re-parse shell
/// output that may arrive after the writeback.
case writeback(sessionID: SessionID, data: Data)
```

Extend the `Codable` conformance accordingly (if hand-coded). If `DaemonResponse` uses an auto-derived `Codable` enum, no further work is needed.

- [ ] **Step 2: Add `_outputSink` + `installOutputSink` + `emitOutput` + `emitWriteback` to `ScreenModel`**

`ScreenModel` is a `public actor` (verified `TermCore/ScreenModel.swift:49`). The sink install and emit run inside the actor (either via `assumeIsolated` at daemon-queue callsites, or via `await` elsewhere). The sink closure is `@Sendable (ScreenModelOutput) -> Void` so it's safe to store on the actor and invoke from any actor-isolated method; the daemon's implementation synchronizes through its own serial queue.

```swift
/// Installed by the daemon's `Session` at create time so the model can
/// originate PTY writebacks, clipboard writes, or future side-effect
/// events. `nil` when running client-side — the client never originates
/// these events.
///
/// Mutated only inside the actor; readers are also actor-isolated so
/// no additional sync is needed beyond the actor's existing serial
/// executor.
private var _outputSink: (@Sendable (ScreenModelOutput) -> Void)? = nil

/// Install an output sink. Called exactly once per model instance;
/// a second call is a programmer error. Actor-isolated.
public func installOutputSink(_ sink: @escaping @Sendable (ScreenModelOutput) -> Void) {
    precondition(_outputSink == nil, "output sink already installed")
    _outputSink = sink
}

/// Invoke the output sink with `event`. No-op if no sink is installed.
/// Actor-isolated.
internal func emitOutput(_ event: ScreenModelOutput) {
    _outputSink?(event)
}

/// Convenience: emit a PTY writeback. Used by DA1/DA2/CPR + future
/// writeback-shaped sequences (DSR, terminal parameters, …).
internal func emitWriteback(_ data: Data) {
    emitOutput(.ptyWriteback(data))
}
```

- [ ] **Step 3: Install the sink in `rtermd/Session.swift`**

`Session.init` runs before `startOutputHandler()` on a different thread than the daemon queue — it is NOT safe to call `assumeIsolated` from `init`. Install the sink lazily in `startOutputHandler()`, where the handler is already guaranteed to execute on the daemon queue (the actor's executor).

```swift
// In Session.swift, inside startOutputHandler(), after the precondition
// checks and before installing the dispatch source:
screenModel.assumeIsolated { model in
    model.installOutputSink { [weak self] event in
        guard let self else { return }
        switch event {
        case .ptyWriteback(let bytes):
            // Writeback bytes — write directly to the PTY primary so
            // the shell receives the reply. Broadcast the writeback to
            // attached clients so their mirrors stay in sync.
            self.write(bytes)
            self.broadcast(.writeback(sessionID: self.id, data: bytes))
        }
        // Task 10 (OSC 52) adds a `.clipboardWrite(...)` case to the
        // enum AND grows this switch with a matching arm. At Task 1's
        // commit boundary the enum is single-case and this switch is
        // exhaustive by construction.
    }
}
```

`Session.write(_:)` (line 272) already performs the full-write loop against `primaryFD`; no new helper required. The `.clipboardWrite` arm is added alongside the enum-case growth in Task 10 Step 5 — both changes land atomically with the `ClipboardTargets` definition, so exhaustiveness is preserved at every commit boundary (no need for `@unknown default`, which anyway applies only to `@frozen` public enums imported from another module).

- [ ] **Step 4: Unit tests**

Create `TermCoreTests/ScreenModelOutputTests.swift`:

```swift
//
//  ScreenModelOutputTests.swift
//  TermCoreTests
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

import Foundation
import Testing
@testable import TermCore

@Suite("ScreenModel output sink")
struct ScreenModelOutputTests {

    @Test("emitWriteback forwards ptyWriteback events to the sink")
    func test_sink_receives_writeback() async {
        let model = ScreenModel(cols: 80, rows: 24)
        let received = LockedAccumulator<ScreenModelOutput>()
        await model.installOutputSink { event in received.append(event) }
        await model._testEmitWriteback(Data([0x41, 0x42]))
        let events = received.all()
        #expect(events.count == 1)
        if case .ptyWriteback(let data) = events[0] {
            #expect(data == Data([0x41, 0x42]))
        } else {
            Issue.record("expected .ptyWriteback")
        }
    }

    @Test("emitOutput is a no-op with no sink")
    func test_no_sink_is_noop() async {
        let model = ScreenModel(cols: 80, rows: 24)
        await model._testEmitWriteback(Data([0x7E]))
        // No crash, no observable effect. Implicit pass.
    }

    @Test("Second sink install traps")
    func test_double_install_traps() async {
        // Precondition trap — cannot be asserted from Swift Testing
        // directly. Manual inspection:
        // let model = ScreenModel(cols: 80, rows: 24)
        // model.installOutputSink { _ in }
        // model.installOutputSink { _ in }   // ← traps
    }
}

// `LockedAccumulator` comes from `TermCoreTests/TestHelpers.swift`
// (Track B Task 0).
```

Add a `@testable`-scope helper on `ScreenModel` to exercise the sink from tests without faking a full DA1/DA2/CPR event path:

```swift
#if DEBUG
extension ScreenModel {
    func _testEmitWriteback(_ data: Data) async {
        emitWriteback(data)
    }
}
#endif
```

- [ ] **Step 5: Build + test**

```bash
xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test -quiet
xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build -quiet
```

- [ ] **Step 6: Commit**

```bash
git add TermCore/DaemonProtocol.swift \
        TermCore/ScreenModelOutput.swift \
        TermCore/ScreenModel.swift \
        rtermd/Session.swift \
        TermCoreTests/ScreenModelOutputTests.swift
git commit -m "feat(TermCore): unified ScreenModelOutput sink (writeback + clipboard)

Introduces one typed output enum + one installOutputSink so
ScreenModel-originated side effects flow through a single channel.
Reference terminals converge on this shape: wezterm 'self.writer',
iTerm2 '[delegate terminalSendReport:]', Terminal.app
'[_shell writeData:]' — splitting into per-kind sinks invites a
third sink the moment Phase 4 adds OSC 4 / focus events.

Phase 3 ships the enum single-case: .ptyWriteback(Data) — used by
DA1/DA2/CPR today and by future DSR / XtSmGraphics / focus events.
Task 10 grows the enum with .clipboardWrite(targets: base64Payload:)
alongside ClipboardTargets (the type that case depends on). Future
kinds are one-line enum additions.

Daemon's Session installs the sink at session-create time inside
startOutputHandler's assumeIsolated block, switches on the event, and
routes writeback to PTY primary + XPC fanout. Client never installs
(emitOutput is a no-op with no sink)."
```

---

## Task 2: Device Attribute + Cursor Position Responses (DA1 + DA2 + CPR)

**Spec reference:** §8 Phase 3 Track A — Terminal identification responses.

**Goal:** Parser emits `.csi(.deviceAttributes(.primary))` for `CSI c` / `CSI 0 c`, `.csi(.deviceAttributes(.secondary))` for `CSI > c` / `CSI > 0 c`, and `.csi(.cursorPositionReport)` for `CSI 6 n`. `ScreenModel` responds via `emitWriteback` with xterm-compatible identifiers (DA1, DA2) or `ESC [ <row> ; <col> R` with 1-indexed coordinates (CPR). All three share the writeback path from Task 1 and the same parser-extension / handler / writeback impl shape — one coherent reviewable unit.

**VT semantics — grounded against xterm's documented behavior:**

- **DA1 (primary):** xterm's canonical default DA1 response is `ESC [ ? 1 ; 2 c` — VT102 terminal class (1) with advanced video option (2). Most terminal detection logic (tmux, vim, less, ncurses) pattern-matches this for "baseline xterm-class." Emit `1 ; 2` (xterm default).
- **DA2 (secondary):** xterm's DA2 is `ESC [ > 0 ; Pv ; 0 c` where the first `0` is terminal class ("xterm"), `Pv` is xterm's patch level, final `0` is cartridge ROM. Emit `Pv = 322` — a concrete, credible xterm patch level that clears the vim/emacs `>= 277 mouse_sgr` threshold.
- **CPR (Cursor Position Report):** `CSI 6 n` → `ESC [ <row> ; <col> R` where `<row>` and `<col>` are the active buffer's cursor position, converted from the internal 0-indexed representation to the VT 1-indexed wire format.

**Files:**
- Modify: `TermCore/CSICommand.swift` (add `.deviceAttributes(DeviceAttributesKind)` + `.cursorPositionReport`)
- Modify: `TermCore/TerminalParser.swift` (dispatch `c`, `> c`, and `n` with param `6`)
- Modify: `TermCore/ScreenModel.swift` (handle all three in `handleCSI`, emit writeback bytes)
- Modify: `TermCoreTests/TerminalParserTests.swift`
- Create: `TermCoreTests/DeviceAttributesTests.swift`

### Steps

- [ ] **Step 1: Extend `CSICommand` + add `DeviceAttributesKind`**

In `TermCore/CSICommand.swift`:

```swift
/// Device Attribute query variants. See xterm ctlseqs — "Primary" and
/// "Secondary" correspond to `CSI c` / `CSI > c` respectively.
@frozen public enum DeviceAttributesKind: Sendable, Equatable {
    case primary
    case secondary
}
```

Add two new cases to `CSICommand`:

```swift
case deviceAttributes(DeviceAttributesKind)
case cursorPositionReport
```

- [ ] **Step 2: Parse `CSI c`, `CSI > c`, and `CSI 6 n`**

The parser already carries intermediates into `mapCSI` (verified: `TermCore/TerminalParser.swift:42-43,112,122` — `csiParam` / `csiIntermediate` states both thread `intermediates: [UInt8]` through, and `>` is stashed in intermediates at line 278). Extend the `mapCSI` switch with two new arms:

```swift
case 0x63 /* c */:
    if intermediates == [0x3E] {  // '>'
        return .deviceAttributes(.secondary)
    } else if intermediates.isEmpty {
        return .deviceAttributes(.primary)
    } else {
        return .unknown(params: params, intermediates: intermediates, final: final)
    }

case 0x6E /* n */:
    // Only param 6 is implemented — Device Status Report; param 5
    // (Device Status) falls through to .unknown for now.
    if intermediates.isEmpty, params.first == 6 {
        return .cursorPositionReport
    }
    return .unknown(params: params, intermediates: intermediates, final: final)
```

- [ ] **Step 3: Write parser tests**

Append to `TermCoreTests/TerminalParserTests.swift`:

```swift
@Test("CSI c emits deviceAttributes(.primary)")
func test_csi_c_primary() {
    var parser = TerminalParser()
    let events = parser.parse(.csi("c"))
    #expect(events == [.csi(.deviceAttributes(.primary))])
}

@Test("CSI 0 c also emits deviceAttributes(.primary)")
func test_csi_zero_c_primary() {
    var parser = TerminalParser()
    let events = parser.parse(.csi("0c"))
    #expect(events == [.csi(.deviceAttributes(.primary))])
}

@Test("CSI > c emits deviceAttributes(.secondary)")
func test_csi_gt_c_secondary() {
    var parser = TerminalParser()
    let events = parser.parse(.csi(">c"))
    #expect(events == [.csi(.deviceAttributes(.secondary))])
}

@Test("CSI 6 n emits cursorPositionReport")
func test_csi_6n_cpr() {
    var parser = TerminalParser()
    let events = parser.parse(.csi("6n"))
    #expect(events == [.csi(.cursorPositionReport)])
}
```

`Data.csi` comes from `TermCoreTests/TestHelpers.swift` (Track B Task 0).

- [ ] **Step 4: Handle all three in `ScreenModel.handleCSI`**

Add to the `handleCSI` switch:

```swift
case .deviceAttributes(let kind):
    switch kind {
    case .primary:
        // CSI ? 1 ; 2 c  — xterm default: VT102 + advanced video.
        emitWriteback(Data([0x1B, 0x5B, 0x3F, 0x31, 0x3B, 0x32, 0x63]))
    case .secondary:
        // CSI > 0 ; 322 ; 0 c  — xterm-class (0), patch 322, cartridge 0.
        emitWriteback(Data([0x1B, 0x5B, 0x3E, 0x30, 0x3B, 0x33, 0x32, 0x32, 0x3B, 0x30, 0x63]))
    }
    return false  // no snapshot bump — pure writeback

case .cursorPositionReport:
    // Active-buffer cursor is 0-indexed internally; VT reports 1-indexed.
    let cursor = active.cursor
    let row = cursor.row + 1
    let col = cursor.col + 1
    var reply = Data([0x1B, 0x5B])
    reply.append(contentsOf: String(row).utf8)
    reply.append(0x3B)
    reply.append(contentsOf: String(col).utf8)
    reply.append(0x52)
    emitWriteback(reply)
    return false
```

- [ ] **Step 5: Write model tests**

Create `TermCoreTests/DeviceAttributesTests.swift`:

```swift
//
//  DeviceAttributesTests.swift
//  TermCoreTests
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

import Foundation
import Testing
@testable import TermCore

@Suite("Device Attribute responses")
struct DeviceAttributesTests {

    @Test("DA1 writes CSI ? 1 ; 2 c (xterm default VT102 + advanced video)")
    func test_DA1_response() async {
        let model = ScreenModel(cols: 80, rows: 24)
        let sink = DataSink()
        await model.installOutputSink { output in
            if case .ptyWriteback(let data) = output { sink.append(data) }
        }
        await model.apply([.csi(.deviceAttributes(.primary))])
        #expect(sink.all() == .csi("?1;2c"))
    }

    @Test("DA2 writes CSI > 0 ; 322 ; 0 c (xterm class, patch 322)")
    func test_DA2_response() async {
        let model = ScreenModel(cols: 80, rows: 24)
        let sink = DataSink()
        await model.installOutputSink { output in
            if case .ptyWriteback(let data) = output { sink.append(data) }
        }
        await model.apply([.csi(.deviceAttributes(.secondary))])
        #expect(sink.all() == .csi(">0;322;0c"))
    }
}

@Suite("CPR response")
struct CPRTests {

    @Test("CPR reports 1-indexed cursor position")
    func test_cpr_at_origin() async {
        let model = ScreenModel(cols: 80, rows: 24)
        let sink = DataSink()
        await model.installOutputSink { output in
            if case .ptyWriteback(let data) = output { sink.append(data) }
        }
        await model.apply([.csi(.cursorPositionReport)])
        // Cursor at (0,0) → "ESC [ 1 ; 1 R"
        #expect(sink.all() == .csi("1;1R"))
    }

    @Test("CPR reports after cursor moved")
    func test_cpr_after_move() async {
        let model = ScreenModel(cols: 80, rows: 24)
        let sink = DataSink()
        await model.installOutputSink { output in
            if case .ptyWriteback(let data) = output { sink.append(data) }
        }
        await model.apply([
            .csi(.cursorPosition(row: 4, col: 9)),  // 0-indexed (5, 10) in VT terms
            .csi(.cursorPositionReport),
        ])
        // Cursor at (4,9) 0-indexed = (5,10) 1-indexed → "ESC [ 5 ; 10 R"
        #expect(sink.all() == .csi("5;10R"))
    }
}

// `DataSink` + `Data.csi` come from `TermCoreTests/TestHelpers.swift` (Track B Task 0).
```

- [ ] **Step 6: Build + test + commit**

```bash
xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test -quiet
git add TermCore/CSICommand.swift \
        TermCore/TerminalParser.swift \
        TermCore/ScreenModel.swift \
        TermCoreTests/TerminalParserTests.swift \
        TermCoreTests/DeviceAttributesTests.swift
git commit -m "feat(TermCore): DA1 + DA2 + CPR responses

Parse CSI c / CSI 0 c / CSI > c / CSI > 0 c as deviceAttributes;
parse CSI 6 n as cursorPositionReport. All three respond via the
Phase 3 writeback sink with xterm-compatible identifiers:
  - DA1: ESC [ ? 1 ; 2 c  (xterm default: VT102 + advanced video)
  - DA2: ESC [ > 0 ; 322 ; 0 c  (xterm class, patch 322, cartridge 0)
  - CPR: ESC [ <row> ; <col> R  (1-indexed per VT spec)
Chosen so tmux/vim/mosh detection logic (pattern-matches 'CSI ? 1' +
'CSI > 0' for xterm-class) recognizes rTerm correctly."
```

---

## Task 3: DECSCUSR cursor shape (parser + model + renderer)

**Spec reference:** §8 Phase 3 Track A — DECSCUSR (`CSI Ps SP q`).

**Goal:** Parser emits `.csi(.setCursorShape(CursorShape))` for `CSI Ps SP q`. Model stores the current shape on `ScreenModel`. Renderer draws the shape variant + respects blinking. The snapshot-field exposure (+ Codable migration) is combined with the `iconName` snapshot-field work in Task 4 — see that task for the `ScreenSnapshot` / `TerminalState` / `CodingKeys` / `makeSnapshot` changes.

`Ps` mapping (xterm convention):
- 0 or 1 — blinking block (default)
- 2 — steady block
- 3 — blinking underline
- 4 — steady underline
- 5 — blinking bar
- 6 — steady bar

**Files:**
- Modify: `TermCore/CSICommand.swift`
- Create: `TermCore/CursorShape.swift`
- Modify: `TermCore/TerminalParser.swift`
- Modify: `TermCore/ScreenModel.swift` (stored property + handler)
- Modify: `rTerm/RenderCoordinator.swift`
- Create: `TermCoreTests/CursorShapeTests.swift`

### Steps

- [ ] **Step 1: Create `CursorShape`**

Create `TermCore/CursorShape.swift`:

```swift
//
//  CursorShape.swift
//  TermCore
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

/// Cursor shape and blink state selected by DECSCUSR (`CSI Ps SP q`).
///
/// - `style` — rectangle / underline / bar.
/// - `blinking` — whether the cursor blinks. Renderer drives the
///   blink phase from a shared global timer uniform.
@frozen public struct CursorShape: Sendable, Equatable, Codable {

    @frozen public enum Style: Sendable, Equatable, Codable {
        case block
        case underline
        case bar
    }

    public let style: Style
    public let blinking: Bool

    public init(style: Style, blinking: Bool) {
        self.style = style
        self.blinking = blinking
    }

    public static let `default` = CursorShape(style: .block, blinking: true)
}
```

- [ ] **Step 2: Extend `CSICommand`**

```swift
case setCursorShape(CursorShape)
```

- [ ] **Step 3: Parse `CSI Ps SP q`**

The intermediate byte is `0x20` (SPACE), final is `q` (`0x71`). Extend `mapCSI`:

```swift
case 0x71 /* q */:
    if intermediates == [0x20] {  // SPACE intermediate — DECSCUSR
        let ps = params.first ?? 0
        switch ps {
        case 0, 1: return .setCursorShape(CursorShape(style: .block, blinking: true))
        case 2:    return .setCursorShape(CursorShape(style: .block, blinking: false))
        case 3:    return .setCursorShape(CursorShape(style: .underline, blinking: true))
        case 4:    return .setCursorShape(CursorShape(style: .underline, blinking: false))
        case 5:    return .setCursorShape(CursorShape(style: .bar, blinking: true))
        case 6:    return .setCursorShape(CursorShape(style: .bar, blinking: false))
        default:   return .unknown(params: params, intermediates: intermediates, final: final)
        }
    }
    return .unknown(params: params, intermediates: intermediates, final: final)
```

- [ ] **Step 4: Handle in `ScreenModel`**

Add a stored property `private var cursorShape: CursorShape = .default` on `ScreenModel` (not inside `TerminalModes` — `TerminalModes` is the DEC-private-mode flags; cursor shape is separate).

In `handleCSI`:

```swift
case .setCursorShape(let shape):
    guard cursorShape != shape else { return false }
    cursorShape = shape
    return true  // snapshot bump
```

(`makeSnapshot(from:)` will surface `cursorShape` into the snapshot in Task 4.)

- [ ] **Step 5: Renderer — draw the shape**

In `rTerm/RenderCoordinator.swift`, find the cursor-drawing block (currently a filled rectangle at the cursor cell). Replace the rectangle generation with a switch on `snapshot.cursorShape.style`:

```swift
let shape = snapshot.cursorShape
switch shape.style {
case .block:
    // existing rectangle code
case .underline:
    // rectangle 2 px tall at the baseline
case .bar:
    // rectangle 2 px wide at the cell's left edge
}
```

Blink: add a uniform `cursorBlinkPhase: Float` updated each frame (wrap `Date().timeIntervalSince1970 * blinkFrequency`). If `shape.blinking` and phase is in the off-half, skip cursor emission.

Document the constants inline:

```swift
// Cursor blink cycle: 1 Hz (500 ms on, 500 ms off). Matches xterm default.
private static let cursorBlinkHz: Double = 1.0
```

- [ ] **Step 6: Tests**

Create `TermCoreTests/CursorShapeTests.swift`:

```swift
import Foundation
import Testing
@testable import TermCore

@Suite("DECSCUSR cursor shape")
struct CursorShapeTests {

    @Test("CSI 0 SP q is blinking block")
    func test_0() {
        var p = TerminalParser()
        #expect(p.parse(Data([0x1B, 0x5B, 0x30, 0x20, 0x71]))
                == [.csi(.setCursorShape(CursorShape(style: .block, blinking: true)))])
    }

    @Test("CSI 2 SP q is steady block")
    func test_2() {
        var p = TerminalParser()
        #expect(p.parse(Data([0x1B, 0x5B, 0x32, 0x20, 0x71]))
                == [.csi(.setCursorShape(CursorShape(style: .block, blinking: false)))])
    }

    @Test("CSI 6 SP q is steady bar")
    func test_6() {
        var p = TerminalParser()
        #expect(p.parse(Data([0x1B, 0x5B, 0x36, 0x20, 0x71]))
                == [.csi(.setCursorShape(CursorShape(style: .bar, blinking: false)))])
    }
}
```

Snapshot-level tests (`test_snapshot_has_shape`, `test_unknown_ps`) live in Task 4 alongside the `iconName` back-compat tests.

- [ ] **Step 7: Build + commit**

```bash
xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test -quiet
xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build -quiet
git add TermCore/CursorShape.swift \
        TermCore/CSICommand.swift \
        TermCore/TerminalParser.swift \
        TermCore/ScreenModel.swift \
        rTerm/RenderCoordinator.swift \
        TermCoreTests/CursorShapeTests.swift
git commit -m "feat: DECSCUSR cursor shape (block/underline/bar + blinking)

Parse CSI Ps SP q into setCursorShape(CursorShape). ScreenModel stores
the active shape; renderer draws block / underline / bar geometry per
Ps, and respects the blinking flag via a 1 Hz timer uniform. The
snapshot-field exposure + Codable migration lands in Task 4 (combined
with iconName)."
```

---

## Task 4: Expose `cursorShape` + `iconName` on `ScreenSnapshot`

**Spec reference:** §8 Phase 3 Track A — DECSCUSR (snapshot exposure) + open question 7 (`iconName` answered: yes).

**Goal:** Add two fields to `ScreenSnapshot` in one Codable migration. Both use `decodeIfPresent` with a default so pre-Phase-3 JSON payloads still decode unchanged. Combined into one task because both fields extend `ScreenSnapshot.TerminalState`, both add `CodingKeys` entries, and both use the same rewrite of `makeSnapshot(from:)` — doing them together avoids three separate rewrites of the init + CodingKeys + `makeSnapshot` body.

**Files:**
- Modify: `TermCore/ScreenSnapshot.swift` (add two fields + extend `TerminalState` + CodingKeys + Codable path)
- Modify: `TermCore/ScreenModel.swift` (pass `cursorShape` + `iconName` into `makeSnapshot`; restore in `restore(from:)`)
- Modify: `TermCoreTests/CodableTests.swift` (or `CursorShapeTests.swift` / `ScreenModelTests.swift`) — snapshot-level tests

### Steps

- [ ] **Step 1: Extend `ScreenSnapshot.TerminalState`**

In `TermCore/ScreenSnapshot.swift`, add two fields to `TerminalState`:

```swift
public struct TerminalState: Sendable, Equatable {
    // ... existing fields ...
    public var cursorShape: CursorShape = .default
    public var iconName: String? = nil
}
```

Extend the `TerminalState.init` to accept both defaults. The convenience `ScreenSnapshot.init` forwards them to the flat init.

- [ ] **Step 2: Extend flat `ScreenSnapshot` + CodingKeys**

Add two flat public fields parallel to the existing ones:

```swift
public let cursorShape: CursorShape
public let iconName: String?
```

Extend the 12-param init signature with both (with `.default` and `nil` as defaults respectively, so existing call sites compile unchanged if they use trailing-default arguments).

Extend `CodingKeys`:

```swift
case cursorShape, iconName
```

Hand-coded `init(from:)`:

```swift
self.cursorShape = try container.decodeIfPresent(CursorShape.self, forKey: .cursorShape) ?? .default
self.iconName = try container.decodeIfPresent(String.self, forKey: .iconName)
```

`encode(to:)`:

```swift
try container.encode(cursorShape, forKey: .cursorShape)
try container.encodeIfPresent(iconName, forKey: .iconName)
```

- [ ] **Step 3: Pass into `makeSnapshot(from:)`**

In `TermCore/ScreenModel.swift`:

```swift
let terminalState = ScreenSnapshot.TerminalState(
    cursorVisible: modes.cursorVisible,
    activeBuffer: activeKind,
    windowTitle: windowTitle,
    cursorKeyApplication: modes.cursorKeyApplication,
    bracketedPaste: modes.bracketedPaste,
    bellCount: bellCount,
    autoWrap: modes.autoWrap,
    cursorShape: cursorShape,
    iconName: iconName)
```

In `restore(from snapshot:)`: `cursorShape = snapshot.cursorShape` and `iconName = snapshot.iconName`.

- [ ] **Step 4: Snapshot-level tests**

Append to `TermCoreTests/CodableTests.swift` (or a new `ScreenSnapshotFieldsTests.swift`):

```swift
@Test("Snapshot carries cursorShape")
func test_snapshot_has_shape() async {
    let model = ScreenModel(cols: 80, rows: 24)
    await model.apply([.csi(.setCursorShape(CursorShape(style: .underline, blinking: false)))])
    let snap = model.latestSnapshot()
    #expect(snap.cursorShape.style == .underline)
    #expect(snap.cursorShape.blinking == false)
}

@Test("Unknown Ps values are ignored, shape stays at default")
func test_unknown_ps() async {
    let model = ScreenModel(cols: 80, rows: 24)
    var p = TerminalParser()
    let events = p.parse(Data([0x1B, 0x5B, 0x39, 0x20, 0x71]))  // Ps=9 unknown
    await model.apply(events)
    let snap = model.latestSnapshot()
    #expect(snap.cursorShape == .default)
}

@Test("OSC 1 sets iconName visible on snapshot")
func test_osc1_icon_name_on_snapshot() async {
    let model = ScreenModel(cols: 80, rows: 24)
    await model.apply([.osc(.setIconName("my-icon"))])
    let snap = model.latestSnapshot()
    #expect(snap.iconName == "my-icon")
}

@Test("Legacy ScreenSnapshot JSON without cursorShape / iconName decodes to defaults")
func test_legacy_snapshot_back_compat() throws {
    // Minimal snapshot JSON carrying only the Phase 1/2 fields — no
    // cursorShape key, no iconName key. decodeIfPresent must yield the
    // defaults (.default / nil).
    let cells = ContiguousArray<Cell>(repeating: Cell(character: "x"), count: 1)
    let snap = ScreenSnapshot(
        activeCells: cells, cols: 1, rows: 1,
        cursor: Cursor.zero,
        terminalState: ScreenSnapshot.TerminalState(),
        version: 0)
    let data = try JSONEncoder().encode(snap)
    let decoded = try JSONDecoder().decode(ScreenSnapshot.self, from: data)
    #expect(decoded.cursorShape == .default)
    #expect(decoded.iconName == nil)
}
```

- [ ] **Step 5: Build + commit**

```bash
xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test -quiet
xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build -quiet
git add TermCore/ScreenSnapshot.swift \
        TermCore/ScreenModel.swift \
        TermCoreTests/CodableTests.swift
git commit -m "feat(TermCore): expose cursorShape + iconName on ScreenSnapshot

Two new snapshot fields land in a single Codable migration. Both use
decodeIfPresent with a default (.default / nil) so Phase 1/2 wire
payloads still decode unchanged. Combined because both fields extend
ScreenSnapshot.TerminalState, both add CodingKeys entries, and both
rewrite makeSnapshot(from:) the same way — doing them together avoids
three round trips through the Codable boilerplate.

Phase 1 stored OSC 1's iconName internally with no consumer; exposing
on the snapshot unblocks Phase 4 dock-icon wiring. cursorShape
exposure completes Task 3 (DECSCUSR) — parser + model + renderer land
in Task 3; snapshot surface lands here."
```

---

## Task 5: Blink attribute rendering

**Spec reference:** §8 Phase 3 Track A — Blink attribute.

**Goal:** Already parsed in Phase 1 (`SGRAttribute.blink`, `CellAttributes.blink`). Currently has no visual effect. Land the global timer uniform + shader toggle so cells with `.blink` flash at the same 1 Hz phase as the cursor.

**Files:**
- Modify: `rTerm/Shaders.metal`
- Modify: `rTerm/RenderCoordinator.swift`

### Steps

- [ ] **Step 1: Extend fragment shader uniform**

In `rTerm/Shaders.metal`, add a uniform struct entry for `blinkPhase: Float` (0.0 = on, 1.0 = off). Existing uniforms: cell grid, atlas, palette. Add `blinkPhase` to the uniform struct used by the per-cell fragment shader.

In the fragment shader's main function, after looking up the cell's color:

```metal
// Blink: when the cell has the blink flag and the current frame is in
// the off-phase, substitute the background color for the foreground.
// Background stays visible so the cell remains selectable by mouse
// (which Track A doesn't add, but Phase 4 will).
if ((cell.attrFlags & kAttrBlink) != 0 && u.blinkPhase > 0.5) {
    color = bg;
}
```

Define `kAttrBlink` in the shader as `(1 << 4)` matching `CellAttributes.blink.rawValue` in Swift.

- [ ] **Step 2: Update Swift side uniform binding**

In `RenderCoordinator.draw(in:)`, compute `blinkPhase`:

```swift
// 1 Hz blink phase: 0..1, repeats per second.
let now = CACurrentMediaTime()
let blinkPhase = Float((now.truncatingRemainder(dividingBy: 1.0)) < 0.5 ? 0.0 : 1.0)
```

Pass it in the uniform buffer/struct bound to the fragment stage. Reuse an existing uniform buffer if one exists; otherwise `setFragmentBytes`.

- [ ] **Step 3: Ensure the view redraws at 1 Hz**

Verified against `rTerm/TermView.swift:148` (plan-time snapshot — see appendix): the `MTKView` is configured with `preferredFramesPerSecond = 60` (not on-demand). No timer is needed — the 60 fps loop drives both cursor and cell blink via the `blinkPhase` uniform recomputed on every `draw(in:)` call.

- [ ] **Step 4: Manual visual test + commit**

Launch the app, run `printf '\033[5mHELLO\033[0m\n'`. The "HELLO" text should blink at 1 Hz. If the renderer is on-demand, add the timer; otherwise the 60 fps loop handles it.

```bash
git add rTerm/Shaders.metal rTerm/RenderCoordinator.swift
git commit -m "feat(rTerm): blink attribute rendering

Fragment shader swaps fg for bg when (attr & kAttrBlink) != 0 and
global blinkPhase is in the off-half of a 1 Hz cycle. Matches xterm
and is phase-aligned with the cursor blink uniform introduced in
Task 3 (DECSCUSR). Cells without .blink are unaffected."
```

Flag manual verification required — unit tests cannot observe Metal pixel output.

---

## Task 6: DECOM origin mode (mode 6)

**Spec reference:** §8 Phase 3 Track A — Origin mode.

**Goal:** When DECOM is set, all cursor-position commands (CUP, HVP, CHA, VPA, save/restore cursor) become scroll-region-relative. Default (DECOM unset): absolute positioning.

`DECPrivateMode.init(rawParam:)` already routes unknown modes to `.unknown(Int)`. Add `.originMode` case; wire into `handleSetMode`; update `handleCSI`'s cursor-position arms to translate when DECOM is set.

**Files:**
- Modify: `TermCore/DECPrivateMode.swift`
- Modify: `TermCore/TerminalModes.swift`
- Modify: `TermCore/ScreenModel.swift`
- Create: `TermCoreTests/OriginModeTests.swift`

### Steps

- [ ] **Step 1: Add `.originMode` to `DECPrivateMode`**

In `TermCore/DECPrivateMode.swift`:

```swift
case originMode                // 6    DECOM
```

Update `init(rawParam:)`:

```swift
case 6: self = .originMode
```

- [ ] **Step 2: Add `originMode: Bool` to `TerminalModes`**

```swift
struct TerminalModes: Equatable, Codable {
    // ... existing fields ...
    var originMode: Bool = false
}
```

- [ ] **Step 3: Wire `handleSetMode`**

**API note (see appendix — `TermCore/ScreenModel.swift`):** `active` is a get-only computed property; mutations route through `mutateActive`. `scrollRegion` is on `Buffer`, not `ScreenModel`; `ScrollRegion.top` is non-optional. `Cursor.zero` arrives via Track B Task 4 — this task depends on it.

```swift
case .originMode:
    guard modes.originMode != enabled else { return false }
    modes.originMode = enabled
    // Per VT spec, setting/resetting DECOM homes the cursor (to origin
    // of the new coordinate space).
    mutateActive { buf in
        if enabled {
            // Origin-relative: home is the scroll region's top (or row 0
            // when no region is set).
            buf.cursor = Cursor(row: buf.scrollRegion?.top ?? 0, col: 0)
        } else {
            buf.cursor = Cursor.zero
        }
    }
    return true
```

- [ ] **Step 4: Translate cursor-position CSI handlers**

**API note (see appendix — `TermCore/ScreenModel.swift`):** existing handlers for `.cursorPosition`, `.cursorHorizontalAbsolute`, `.verticalPositionAbsolute` go through `mutateActive { buf in … clampCursor(in: &buf) … }`. The translation below preserves that pattern; add DECOM-aware offsets inside the existing closure.

In `handleCSI`, modify each absolute-positioning handler (`cursorPosition`, `verticalPositionAbsolute`, `cursorHorizontalAbsolute`) to translate when DECOM is set. `saveCursor`/`restoreCursor` operate on whatever coordinate space was active at save time — no DECOM translation needed on either side (save stores the absolute row/col; restore puts them back absolute). Example rewrite for `.cursorPosition`:

```swift
case .cursorPosition(let r, let c):
    return mutateActive { buf in
        let topOffset = self.modes.originMode ? (buf.scrollRegion?.top ?? 0) : 0
        buf.cursor.row = r + topOffset
        buf.cursor.col = c
        self.clampCursorToRegion(in: &buf)
        return true
    }
```

Introduce a `clampCursorToRegion(in:)` helper that respects DECOM state — when DECOM is on and `buf.scrollRegion != nil`, clamp `buf.cursor.row` to `[region.top, region.bottom]`; otherwise clamp to `[0, rows - 1]` as `clampCursor(in:)` already does. Column clamping is unchanged by DECOM.

```swift
private func clampCursorToRegion(in buf: inout Buffer) {
    if modes.originMode, let region = buf.scrollRegion {
        buf.cursor.row = max(region.top, min(region.bottom, buf.cursor.row))
    } else {
        buf.cursor.row = max(0, min(rows - 1, buf.cursor.row))
    }
    buf.cursor.col = max(0, min(cols - 1, buf.cursor.col))
}
```

Apply the same `topOffset` translation pattern to `.verticalPositionAbsolute` (row only) and leave `.cursorHorizontalAbsolute` unchanged (column only — DECOM doesn't affect horizontal translation).

- [ ] **Step 5: Tests**

Create `TermCoreTests/OriginModeTests.swift` with tests for:
- Default DECOM-off: CUP 5;10 → cursor at (4,9).
- DECSTBM 10;20 then DECOM-on: CUP 1;1 → cursor at (9, 0).
- DECOM-on: cursor cannot escape above scroll-region top.

```swift
@Suite("DECOM origin mode")
struct OriginModeTests {

    @Test("DECOM off: cursor position is absolute")
    func test_decom_off_absolute() async {
        let model = ScreenModel(cols: 80, rows: 24)
        await model.apply([.csi(.cursorPosition(row: 4, col: 9))])
        let snap = model.latestSnapshot()
        #expect(snap.cursor.row == 4)
        #expect(snap.cursor.col == 9)
    }

    @Test("DECOM on within DECSTBM 10..20: CUP 0;0 positions to region top")
    func test_decom_on_with_stbm() async {
        let model = ScreenModel(cols: 80, rows: 24)
        await model.apply([
            .csi(.setScrollRegion(top: 10, bottom: 20)),
            .csi(.setMode(.originMode, enabled: true)),
            .csi(.cursorPosition(row: 0, col: 0)),
        ])
        let snap = model.latestSnapshot()
        #expect(snap.cursor.row == 9, "0-indexed row 9 = VT 10; region-relative origin")
    }

    @Test("DECOM off restores absolute positioning")
    func test_decom_toggle_off() async {
        let model = ScreenModel(cols: 80, rows: 24)
        await model.apply([
            .csi(.setScrollRegion(top: 10, bottom: 20)),
            .csi(.setMode(.originMode, enabled: true)),
            .csi(.setMode(.originMode, enabled: false)),
            .csi(.cursorPosition(row: 0, col: 0)),
        ])
        let snap = model.latestSnapshot()
        #expect(snap.cursor.row == 0)
        #expect(snap.cursor.col == 0)
    }
}
```

- [ ] **Step 6: Build + commit**

```bash
xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test -quiet
git add TermCore/DECPrivateMode.swift \
        TermCore/TerminalModes.swift \
        TermCore/ScreenModel.swift \
        TermCoreTests/OriginModeTests.swift
git commit -m "feat(TermCore): DECOM origin mode (mode 6)

Cursor-position commands (CUP, HVP, CHA, VPA, s, u) translate to
scroll-region-relative coordinates when DECOM is set. DECOM toggle
homes the cursor to the origin of the new coordinate space per VT
spec. Parser already emits .csi(.setMode(.originMode, ...)); the
handler wires the behavior end to end."
```

---

## Task 7: DECCOLM 132-column mode (mode 3)

**Spec reference:** §8 Phase 3 Track A — 132-column mode.

**Goal:** When DECCOLM is set, resize buffer to 132 columns; when reset, resize to 80. Per VT spec DECCOLM also clears the screen and homes the cursor. Requires `ScreenModel.resize(cols:rows:)` and the daemon-side PTY `TIOCSWINSZ` propagation (the daemon already supports resize via `DaemonRequest.resize`, so reuse that path).

**Files:**
- Modify: `TermCore/DECPrivateMode.swift`
- Modify: `TermCore/ScreenModel.swift` (add `.deccolm` handling — triggers resize)
- Modify: `rTerm/ContentView.swift` or wherever the `TerminalSession` owns the resize flow (propagate to daemon + tell the renderer to adopt the new cols)
- Create: `TermCoreTests/DECCOLMTests.swift`

### Steps

- [ ] **Step 1: Add `.column132` to `DECPrivateMode`**

```swift
case column132                 // 3    DECCOLM
```

`init(rawParam:)`:

```swift
case 3: self = .column132
```

- [ ] **Step 2: Handle in `ScreenModel.handleSetMode`**

**VT semantics — verified against VT510 spec (DECCOLM, mode 3) + xterm's documented behavior for mode 3.** Per the spec, setting or resetting DECCOLM performs FOUR state changes, not two:

1. Clear the screen (equivalent to `ED 2`).
2. Home the cursor.
3. **Reset DECSTBM (scroll region) to the full screen** — any prior `CSI <top> ; <bot> r` is discarded.
4. **Reset DECOM (origin mode) to off** — any prior `CSI ? 6 h` is cleared.

Side effects 3 and 4 are load-bearing — tmux/vim rely on the post-DECCOLM state being "full-screen region, origin off". Without (3), a prior `CSI 5;22 r` leaks into the 132-column session; without (4), a prior `CSI ?6 h` silently re-origins subsequent cursor-position commands.

DECCOLM is a mode that changes buffer dimensions. The actor cannot directly drive a PTY resize — that's the daemon's job. The model:
1. Clears both screens (alt and main) via ED-style grid clear.
2. Resets scroll region on BOTH buffers (side effect 3 above).
3. Resets origin mode (side effect 4 above).
4. Homes the cursor on the active buffer.
5. Signals the pending-cols change through `pendingCols`.

For Phase 3 simplicity, expose via an `@Observable` property on `TerminalSession` that the SwiftUI view reacts to by calling `session.resize(rows:, cols:)`. The resize eventually reaches the daemon via the existing `DaemonRequest.resize` path.

```swift
// In ScreenModel:
/// When non-nil, signals that a DECCOLM toggle requested a column
/// change. Consumer (TerminalSession) should invoke the resize flow
/// and clear this back to nil.
public private(set) var pendingCols: Int? = nil

// In handleSetMode:
case .column132:
    let newCols = enabled ? 132 : 80
    // (1) Clear both buffers — DECCOLM clears the screen; alt is cleared
    // defensively so a subsequent alt-enter finds a clean grid.
    Self.clearGrid(in: &main, cols: cols, rows: rows)
    Self.clearGrid(in: &alt, cols: cols, rows: rows)
    // (2) + (3) Reset scroll region on both buffers.
    main.scrollRegion = nil
    alt.scrollRegion = nil
    // (4) Reset origin mode.
    modes.originMode = false
    // (5) Home cursor on the active buffer.
    mutateActive { buf in buf.cursor = Cursor.zero }
    // Signal the pending resize.
    pendingCols = newCols
    return true
```

In `TerminalSession` or `ContentView`, observe `pendingCols` via SwiftUI `onChange` and call the session resize + reset it.

- [ ] **Step 3: Test**

```swift
@Suite("DECCOLM column-switch mode")
struct DECCOLMTests {

    @Test("DECCOLM set signals 132 cols pending")
    func test_deccolm_on_signals_132() async {
        let model = ScreenModel(cols: 80, rows: 24)
        await model.apply([.csi(.setMode(.column132, enabled: true))])
        let pending = await model.pendingCols
        #expect(pending == 132)
    }

    @Test("DECCOLM reset signals 80 cols pending")
    func test_deccolm_off_signals_80() async {
        let model = ScreenModel(cols: 80, rows: 24)
        await model.apply([.csi(.setMode(.column132, enabled: false))])
        let pending = await model.pendingCols
        #expect(pending == 80)
    }

    @Test("DECCOLM clears active grid")
    func test_deccolm_clears_grid() async {
        let model = ScreenModel(cols: 80, rows: 24)
        await model.apply([.printable("X"), .printable("Y")])
        await model.apply([.csi(.setMode(.column132, enabled: true))])
        let snap = model.latestSnapshot()
        #expect(snap[0, 0].character == " ")
        #expect(snap[0, 1].character == " ")
        #expect(snap.cursor == Cursor.zero)
    }

    @Test("DECCOLM resets DECSTBM scroll region (side effect 3)")
    func test_deccolm_resets_scroll_region() async {
        let model = ScreenModel(cols: 80, rows: 24)
        // Set a scroll region, then DECCOLM — region must be gone.
        await model.apply([
            .csi(.setScrollRegion(top: 5, bottom: 22)),
            .csi(.setMode(.column132, enabled: true)),
        ])
        // Verify by writing a line-feed flood: if region survived, the
        // bottom row would be the region bottom - 1 (0-indexed row 21),
        // not the screen bottom (row 23). Simplest check: after
        // flooding, cursor ends up at row 23.
        for _ in 0..<30 {
            await model.apply([.c0(.lineFeed)])
        }
        let snap = model.latestSnapshot()
        #expect(snap.cursor.row == 23, "region should have been cleared; LF flood must hit the screen bottom")
    }

    @Test("DECCOLM resets DECOM origin mode (side effect 4)")
    func test_deccolm_resets_origin_mode() async {
        let model = ScreenModel(cols: 80, rows: 24)
        // Turn origin mode on, set a region, then DECCOLM — origin must
        // be off so a subsequent CUP is absolute.
        await model.apply([
            .csi(.setScrollRegion(top: 10, bottom: 20)),
            .csi(.setMode(.originMode, enabled: true)),
            .csi(.setMode(.column132, enabled: true)),
            .csi(.cursorPosition(row: 0, col: 0)),
        ])
        let snap = model.latestSnapshot()
        #expect(snap.cursor.row == 0, "origin mode should be off after DECCOLM; CUP 0;0 is absolute")
    }
}
```

- [ ] **Step 4: Wire the resize observer**

In `rTerm/ContentView.swift`, add an `.onChange(of: session.pendingCols)` modifier that triggers `session.resize(rows: rows, cols: newCols)` and calls `session.screenModel.clearPendingCols()` (a new nonisolated function that resets the pending flag).

- [ ] **Step 5: Commit**

```bash
git add TermCore/DECPrivateMode.swift \
        TermCore/ScreenModel.swift \
        rTerm/ContentView.swift \
        TermCoreTests/DECCOLMTests.swift
git commit -m "feat(TermCore): DECCOLM 132-column mode (mode 3)

Set/reset DECCOLM performs all four VT510-spec side effects:
  1. clear both buffers (equivalent to ED 2 on each)
  2. home the cursor on the active buffer
  3. reset DECSTBM scroll region to full screen on both buffers
  4. reset DECOM origin mode to off

Per VT510 reference + xterm's documented behavior for mode 3. Side
effects 3 and 4 are load-bearing for tmux/vim which rely on the
post-DECCOLM state being 'full-screen region, origin off'.

Signals a pending column change via ScreenModel.pendingCols.
ContentView observes the signal and routes a resize request through
the existing TerminalSession.resize → daemon → PTY TIOCSWINSZ path,
preserving the Phase 1/2 resize semantics unchanged."
```

---

## Task 8: OSC 8 hyperlinks — parser + model

**Spec reference:** §8 Phase 3 Track A — OSC 8 hyperlinks.

**Goal:** Promote OSC 8 out of `.osc(.unknown)` into typed `OSCCommand.setHyperlink(id: String?, uri: String?)`. Extend `CellStyle` with `hyperlink: Hyperlink?`. `ScreenModel` stamps the current hyperlink onto cells via pen state, same as fg/bg.

`OSC 8 ; <params> ; <uri> ST` — params is semicolon-delimited key=value list (typically `id=<id>`). Terminator `OSC 8 ; ; ST` clears the pen hyperlink.

**Files:**
- Modify: `TermCore/OSCCommand.swift` (new typed case)
- Create: `TermCore/Hyperlink.swift`
- Modify: `TermCore/CellStyle.swift` (add field; Codable via decodeIfPresent)
- Modify: `TermCore/TerminalParser.swift` (dispatch OSC 8 params/uri)
- Modify: `TermCore/ScreenModel.swift` (pen state)
- Create: `TermCoreTests/HyperlinkTests.swift`

### Steps

- [ ] **Step 1: Create `Hyperlink`**

Create `TermCore/Hyperlink.swift`:

```swift
//
//  Hyperlink.swift
//  TermCore
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

/// OSC 8 hyperlink target. The `id` field is optional; when present,
/// multiple non-contiguous cells with the same `id` are treated as a
/// single interactive region by the renderer (e.g., hover highlight
/// spans all cells in the group, not only the hovered cell).
public struct Hyperlink: Sendable, Equatable, Codable {
    public let id: String?
    public let uri: String

    public init(id: String?, uri: String) {
        self.id = id
        self.uri = uri
    }
}
```

- [ ] **Step 2: Extend `OSCCommand`**

```swift
case setHyperlink(Hyperlink?)   // nil terminates the pen hyperlink
```

- [ ] **Step 3: Parse OSC 8 in `TerminalParser`**

**VT semantics — verified against the consensus OSC 8 hyperlink grammar** (Egmont Kob's spec, https://gist.github.com/egmontkob/eb114294efbcd5adb1944c9f3cb5feda — adopted by iTerm2, WezTerm, kitty, Alacritty):

> "params is an optional list of key=value assignments, separated by the : character. Example: id=xyz123:foo=bar:baz=quux."
>
> "Due to the syntax, additional parameter values cannot contain the `:` and `;` characters either."

In other words:
- Outer: `OSC 8 ; <params> ; <uri> ST` — `;` separates the three fields (8, params, uri).
- Inner (inside `<params>`): **`:`** separates key=value entries.

Inner separator is `:` per OSC 8 grammar (iTerm2, wezterm, kitty, Alacritty are concordant). The outer `;` only splits the three top-level fields (8, params, uri).

In `mapOSC(ps:pt:)`:

```swift
case 8:
    return Self.parseOSC8(pt: pt)
```

Implement:

```swift
private static func parseOSC8(pt: String) -> OSCCommand {
    // Payload: "<params>;<uri>". Both halves may be empty.
    // OSC 8 ; ; ST  → clears pen hyperlink (.setHyperlink(nil))
    guard let sepIdx = pt.firstIndex(of: ";") else {
        // Malformed — treat as unknown so downstream can log.
        return .unknown(ps: 8, pt: pt)
    }
    let uriStart = pt.index(after: sepIdx)
    let paramsPart = pt[..<sepIdx]
    let uriPart = String(pt[uriStart...])
    if uriPart.isEmpty {
        return .setHyperlink(nil)
    }
    // Extract id= from params. Inner separator is ':' per the OSC 8
    // grammar; '; ' is the outer field separator and was already
    // consumed by the split above.
    let id: String? = paramsPart
        .split(separator: ":")
        .compactMap { kv -> String? in
            let parts = kv.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0] == "id" else { return nil }
            return String(parts[1])
        }
        .first
    return .setHyperlink(Hyperlink(id: id, uri: uriPart))
}
```

- [ ] **Step 4: Extend `CellStyle`**

```swift
public struct CellStyle: Sendable, Equatable, Codable {
    public var foreground: TerminalColor
    public var background: TerminalColor
    public var attributes: CellAttributes
    public var hyperlink: Hyperlink?   // NEW

    public init(foreground: TerminalColor = .default,
                background: TerminalColor = .default,
                attributes: CellAttributes = [],
                hyperlink: Hyperlink? = nil) {
        self.foreground = foreground
        self.background = background
        self.attributes = attributes
        self.hyperlink = hyperlink
    }

    public static let `default` = CellStyle()

    private enum CodingKeys: String, CodingKey {
        case foreground, background, attributes, hyperlink
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.foreground = try c.decode(TerminalColor.self, forKey: .foreground)
        self.background = try c.decode(TerminalColor.self, forKey: .background)
        self.attributes = try c.decode(CellAttributes.self, forKey: .attributes)
        self.hyperlink = try c.decodeIfPresent(Hyperlink.self, forKey: .hyperlink)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(foreground, forKey: .foreground)
        try c.encode(background, forKey: .background)
        try c.encode(attributes, forKey: .attributes)
        if let h = hyperlink { try c.encode(h, forKey: .hyperlink) }
    }
}
```

**Why hand-coded Codable, not auto-derived?** The current `CellStyle` (`TermCore/CellStyle.swift:40`) uses **auto-derived** `Codable` (`public struct CellStyle: Sendable, Equatable, Codable`, no hand-written `init(from:)` or `encode(to:)`). Adding a new field `hyperlink: Hyperlink?` with auto-derived Codable would make the synthesized `init(from:)` require the new key — decoding a legacy Phase 1/2 payload (no `hyperlink` key) would throw.

The rewrite **to** hand-coded Codable with `decodeIfPresent` is the `Hyperlink?` field's contract: nil-valued. Decoding legacy payloads yields `hyperlink: nil`; encoding drops the key when nil. This is the project convention for all new Codable fields (spec §6). Note: mixed daemon/client versions are not a Phase 3 constraint (daemon and client ship together per spec §6) — the compat motivation here is "round-trip tests of pre-Phase-3 JSON blobs continue to decode," not "new daemon talks to old client."

- [ ] **Step 5: `ScreenModel` pen state + handler**

In `ScreenModel`, the `pen: CellStyle` already exists. Add to `handleOSC`:

```swift
case .setHyperlink(let hyperlink):
    pen.hyperlink = hyperlink
    return false  // pen change does not alone bump the snapshot
```

`handlePrintable` already stamps the full pen onto the new cell; no change needed.

- [ ] **Step 6: Tests**

Create `TermCoreTests/HyperlinkTests.swift`:

```swift
import Foundation
import Testing
@testable import TermCore

@Suite("OSC 8 hyperlinks")
struct HyperlinkTests {

    @Test("OSC 8 ; id=A ; http://x ST parses to setHyperlink")
    func test_osc8_with_id() {
        var p = TerminalParser()
        let events = p.parse(.osc(8, "id=A;http://x"))
        #expect(events == [.osc(.setHyperlink(Hyperlink(id: "A", uri: "http://x")))])
    }

    @Test("OSC 8 ; ; http://x ST parses without id")
    func test_osc8_no_id() {
        var p = TerminalParser()
        let events = p.parse(.osc(8, ";http://x"))
        #expect(events == [.osc(.setHyperlink(Hyperlink(id: nil, uri: "http://x")))])
    }

    @Test("OSC 8 ; ; ST terminates hyperlink")
    func test_osc8_terminator() {
        var p = TerminalParser()
        let events = p.parse(.osc(8, ";"))
        #expect(events == [.osc(.setHyperlink(nil))])
    }

    @Test("OSC 8 with multi-param id=A:user=joe extracts id correctly")
    func test_osc8_multi_param_colon_separator() {
        // Per the OSC 8 grammar, inner key=value entries are separated
        // by ':'. A payload "id=A:user=joe;http://x" must yield
        // id == "A", regardless of whether 'user' appears before or
        // after 'id' in the list.
        var p = TerminalParser()
        let events = p.parse(.osc(8, "id=A:user=joe;http://x"))
        #expect(events == [.osc(.setHyperlink(Hyperlink(id: "A", uri: "http://x")))])

        // Also verify order-independence.
        var p2 = TerminalParser()
        let events2 = p2.parse(.osc(8, "user=joe:id=B;http://y"))
        #expect(events2 == [.osc(.setHyperlink(Hyperlink(id: "B", uri: "http://y")))])
    }

    @Test("Pen hyperlink stamps onto subsequent printable writes")
    func test_pen_stamps_hyperlink() async {
        let model = ScreenModel(cols: 10, rows: 1)
        let link = Hyperlink(id: "L", uri: "http://example")
        await model.apply([
            .osc(.setHyperlink(link)),
            .printable("A"), .printable("B"),
            .osc(.setHyperlink(nil)),
            .printable("C"),
        ])
        let snap = model.latestSnapshot()
        #expect(snap[0, 0].style.hyperlink == link)
        #expect(snap[0, 1].style.hyperlink == link)
        #expect(snap[0, 2].style.hyperlink == nil)
    }

    @Test("Cell Codable round-trip with hyperlink preserves fidelity")
    func test_cell_codable_with_hyperlink() throws {
        let link = Hyperlink(id: "A", uri: "http://example")
        let cell = Cell(character: "X",
                        style: CellStyle(hyperlink: link))
        let data = try JSONEncoder().encode(cell)
        let decoded = try JSONDecoder().decode(Cell.self, from: data)
        #expect(decoded == cell)
    }

    @Test("Legacy Cell without hyperlink key decodes with nil hyperlink")
    func test_legacy_cell_decodes() throws {
        // Simulate a pre-Phase-3 wire payload: style without hyperlink key.
        let legacyJSON = #"{"character":"X","style":{"foreground":{"default":{}},"background":{"default":{}},"attributes":{"rawValue":0}}}"#
        let data = legacyJSON.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Cell.self, from: data)
        #expect(decoded.style.hyperlink == nil)
    }

    @Test("Legacy CellStyle JSON without hyperlink key decodes to nil")
    func test_legacy_cellstyle_decodes() throws {
        // Direct CellStyle round-trip — confirms the hand-coded
        // decodeIfPresent path handles a pre-Phase-3 CellStyle blob.
        let legacyJSON = #"{"foreground":{"default":{}},"background":{"default":{}},"attributes":{"rawValue":0}}"#
        let data = legacyJSON.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CellStyle.self, from: data)
        #expect(decoded.hyperlink == nil)
        #expect(decoded.attributes == [])
    }

    @Test("Encoded CellStyle omits hyperlink key when nil")
    func test_cellstyle_encode_omits_nil_hyperlink() throws {
        let style = CellStyle()  // default — no hyperlink
        let data = try JSONEncoder().encode(style)
        let json = String(data: data, encoding: .utf8)!
        #expect(!json.contains("\"hyperlink\""),
                "nil hyperlink must not be encoded; got \(json)")
    }
}
```

- [ ] **Step 7: Build + commit**

```bash
xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test -quiet
git add TermCore/Hyperlink.swift \
        TermCore/OSCCommand.swift \
        TermCore/CellStyle.swift \
        TermCore/TerminalParser.swift \
        TermCore/ScreenModel.swift \
        TermCoreTests/HyperlinkTests.swift
git commit -m "feat(TermCore): OSC 8 hyperlinks — parser + pen state

Promote OSC 8 out of .osc(.unknown). Parser splits the payload on the
first semicolon, extracts id= from params (inner separator ':' per
the consensus OSC 8 grammar — iTerm2, WezTerm, kitty, Alacritty), and
emits .osc(.setHyperlink(Hyperlink(id:uri:))) or
.osc(.setHyperlink(nil)) on terminator.

CellStyle gains a hyperlink: Hyperlink? field. The rewrite from
auto-derived to hand-coded Codable is necessary because the
auto-derived init(from:) cannot ignore a missing 'hyperlink' key —
it would throw on any pre-Phase-3 JSON blob. Hand-coded with
decodeIfPresent handles legacy payloads cleanly; encoding drops the
key when nil. Roundtrip tests pin both the legacy-decodes-to-nil
and the encode-omits-nil-key invariants. Project convention for all
new Codable fields (spec §6); mixed daemon/client versions are NOT a
Phase 3 compat concern (daemon + client ship together per §6), but
the roundtrip tests guard against a future regression."
```

---

## Task 9: OSC 8 — renderer + click handling

**Spec reference:** §8 Phase 3 Track A — OSC 8 renderer + URI allowlist (`http(s):`, `file:`, `mailto:`).

**Goal:** Renderer adds a hover-underline for cells whose `style.hyperlink` is non-nil. Click handler opens the URI via `NSWorkspace.open(_:)` after validating the scheme against the allowlist.

**Files:**
- Modify: `rTerm/RenderCoordinator.swift` (hover tracking + underline overlay)
- Modify: `rTerm/TermView.swift` (mouse tracking + click → URI open)
- Create: `rTerm/HyperlinkScheme.swift`
- Create: `rTermTests/HyperlinkSchemeTests.swift`

### Steps

- [ ] **Step 1: Create the scheme allowlist**

Create `rTerm/HyperlinkScheme.swift`:

```swift
//
//  HyperlinkScheme.swift
//  rTerm
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

import Foundation

/// Allowlist for OSC 8 hyperlink opening. Phase 3 decision:
/// `http(s)`, `file`, `mailto` only. Expand in a future phase if
/// a concrete need surfaces.
public enum HyperlinkScheme {
    private static let allowed: Set<String> = [
        "http", "https", "file", "mailto",
    ]

    /// Return the URL if `uri` parses, has an allowed scheme, and is
    /// safe to pass to `NSWorkspace.open(_:)`. Nil otherwise.
    public static func validated(_ uri: String) -> URL? {
        guard let url = URL(string: uri) else { return nil }
        guard let scheme = url.scheme?.lowercased(),
              allowed.contains(scheme) else { return nil }
        return url
    }
}
```

- [ ] **Step 2: Test allowlist**

Create `rTermTests/HyperlinkSchemeTests.swift`:

```swift
import Foundation
import Testing
@testable import rTerm

@Suite("Hyperlink scheme allowlist")
struct HyperlinkSchemeTests {

    @Test("http / https / file / mailto pass")
    func test_allowed() {
        #expect(HyperlinkScheme.validated("http://x")?.absoluteString == "http://x")
        #expect(HyperlinkScheme.validated("https://example.com/path") != nil)
        #expect(HyperlinkScheme.validated("file:///tmp/x") != nil)
        #expect(HyperlinkScheme.validated("mailto:a@b") != nil)
    }

    @Test("javascript / data / ftp are blocked")
    func test_blocked() {
        #expect(HyperlinkScheme.validated("javascript:alert(1)") == nil)
        #expect(HyperlinkScheme.validated("data:text/html,hi") == nil)
        #expect(HyperlinkScheme.validated("ftp://x/y") == nil)
    }

    @Test("Malformed URIs rejected")
    func test_malformed() {
        #expect(HyperlinkScheme.validated("") == nil)
        #expect(HyperlinkScheme.validated("   ") == nil)
    }

    @Test("Uppercase scheme normalized")
    func test_case_insensitive_scheme() {
        #expect(HyperlinkScheme.validated("HTTPS://example") != nil)
    }
}
```

- [ ] **Step 3: Add hover tracking to `TerminalMTKView`**

**API note (see appendix — `rTerm/RenderCoordinator.swift`, `rTerm/GlyphAtlas.swift`):** `RenderCoordinator` exposes no `glyphMetrics` accessor today; per-atlas cell metrics live on `GlyphAtlas.cellWidth` / `cellHeight`. All four atlas variants share the metrics (same monospace face + size). Landing a `cellSize: CGSize` accessor on `RenderCoordinator` that reads from `regularAtlas` is a prerequisite sub-step — the hover math depends on it.

Add to `RenderCoordinator` (e.g., near the existing `screenModelForView` accessor around line 72):

```swift
/// Per-cell pixel geometry used by hover-to-cell mapping. All four atlas
/// variants share metrics; read from `regularAtlas` as the canonical source.
var cellSize: CGSize {
    CGSize(width: regularAtlas.cellWidth, height: regularAtlas.cellHeight)
}
```

Then extend `TerminalMTKView` with `hoveredCell: (row: Int, col: Int)?` and override `mouseMoved(with:)`:

```swift
override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    let opts: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect]
    addTrackingArea(NSTrackingArea(rect: bounds, options: opts, owner: self, userInfo: nil))
}

override func mouseMoved(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let cell = cellCoordinate(at: point)
    if cell?.row != hoveredCell?.row || cell?.col != hoveredCell?.col {
        hoveredCell = cell
        coordinator?.setHoveredCell(cell, view: self)
        needsDisplay = true
    }
}

private func cellCoordinate(at point: NSPoint) -> (row: Int, col: Int)? {
    // Pixel-to-cell using the coordinator's exposed cellSize.
    guard let metrics = coordinator?.cellSize,
          metrics.width > 0, metrics.height > 0 else { return nil }
    let col = Int(point.x / metrics.width)
    let row = Int((bounds.height - point.y) / metrics.height)
    return (row, col)
}
```

Expose `RenderCoordinator.setHoveredCell(_:view:)` which stashes the hovered cell for the next draw pass.

- [ ] **Step 4: Render hover underline**

In `RenderCoordinator.draw(in:)`, after drawing all base passes:

```swift
if let hovered = hoveredCell,
   let row = snapshotRow(hovered.row, snapshot: snapshot),
   hovered.col < snapshot.cols {
    let cell = row < rows ? snapshot[hovered.row, hovered.col] : Cell(character: " ")
    if let link = cell.style.hyperlink {
        // Emit a bright underline across ALL cells that share this link's id
        // (or just this cell if id is nil). Use the existing underline pass
        // with a hover-color uniform.
        emitHoverUnderline(for: link, snapshot: snapshot)
    }
}
```

Implement `emitHoverUnderline` to walk the snapshot looking for cells with matching `link.id` (or exactly the hovered cell if `id == nil`), emitting underline-pass vertices with the hover color.

- [ ] **Step 5: Click handling**

Override `mouseDown` in `TerminalMTKView`:

```swift
override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard let cell = cellCoordinate(at: point),
          let onHyperlinkClick = onHyperlinkClick else {
        super.mouseDown(with: event)
        return
    }
    if let link = snapshotHyperlink(at: cell) {
        onHyperlinkClick(link.uri)
        return
    }
    super.mouseDown(with: event)
}
```

Add `onHyperlinkClick: ((String) -> Void)?` to the view's closure properties. Wire in `makeNSView`:

```swift
view.onHyperlinkClick = { uri in
    guard let url = HyperlinkScheme.validated(uri) else {
        os_log(.error, "OSC 8: refused to open uri '%{public}@' (scheme not allowlisted)", uri)
        return
    }
    NSWorkspace.shared.open(url)
}
```

- [ ] **Step 6: Build + manual test**

```bash
xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build -quiet
```

Manual test:

```bash
printf '\033]8;id=1;https://apple.com\033\\Apple\033]8;;\033\\\n'
```

Expected: "Apple" is underlined; hover highlights; click opens `https://apple.com`.

- [ ] **Step 7: Commit**

```bash
git add rTerm/HyperlinkScheme.swift \
        rTerm/TermView.swift \
        rTerm/RenderCoordinator.swift \
        rTermTests/HyperlinkSchemeTests.swift
git commit -m "feat(rTerm): OSC 8 hyperlink hover + click

Mouse tracking emits hovered-cell updates to RenderCoordinator; cells
whose style.hyperlink is non-nil receive a hover-color underline that
spans the id-linked group (or just the cell, if id is nil). Click on
a hyperlinked cell passes the uri through HyperlinkScheme.validated
(http/https/file/mailto only) and opens via NSWorkspace. Invalid
scheme is logged and ignored."
```

---

## Task 10: OSC 52 clipboard set path

**Spec reference:** §8 Phase 3 Track A — OSC 52 clipboard (set only, query deferred to Phase 4 per answered Q1).

**Goal:** Parser promotes OSC 52 into typed `OSCCommand.setClipboard(targets: ClipboardTargets, base64Payload: String)`. Task 10 grows the Task 1 `ScreenModelOutput` enum with a new `.clipboardWrite(targets:base64Payload:)` case (the `ClipboardTargets` type that case references is defined in Step 1 of this same task, so the new case compiles at Task 10's commit boundary). Model routes the payload via `emitOutput(.clipboardWrite(...))`. Daemon's existing switch in `Session.startOutputHandler()` grows one arm to fan out via `DaemonResponse.clipboardWrite`. Client app writes to `NSPasteboard.general` under a user-consent gate (OSC 52 is not a user-triggered action, so surface a prompt on every fire).

**Files:**
- Modify: `TermCore/OSCCommand.swift`
- Create: `TermCore/ClipboardTargets.swift`
- Modify: `TermCore/ScreenModelOutput.swift` (grow enum with `.clipboardWrite` case — depends on `ClipboardTargets` created in Step 1)
- Modify: `TermCore/TerminalParser.swift`
- Modify: `TermCore/DaemonProtocol.swift` (new `DaemonResponse` case)
- Modify: `TermCore/ScreenModel.swift` (handle in `handleOSC` → `emitOutput(.clipboardWrite(...))`)
- Modify: `rtermd/Session.swift` (grow the unified switch with the concrete `.clipboardWrite` arm)
- Modify: `rTerm/ContentView.swift` (receive + consent prompt + NSPasteboard write)
- Create: `TermCoreTests/ClipboardTests.swift`

### Steps

- [ ] **Step 1: Create `ClipboardTargets`**

**VT semantics — verified against xterm ctlseqs' "Manipulate Selection Data" (OSC 52) grammar** (per the consensus behavior across xterm, tmux, kitty, WezTerm, Alacritty): the `<target>` parameter is a **string of characters**, not a single character. Each character selects one pasteboard slot. xterm defines these letters:

| Char | Target         |
|------|----------------|
| `c`  | clipboard (macOS: `NSPasteboard.general`) |
| `p`  | primary (X11 primary selection; no macOS equivalent) |
| `q`  | secondary (rarely used) |
| `s`  | "select" — bracket around whichever of primary/clipboard applies |
| `0`–`7` | cut buffers (xterm-only; no macOS equivalent) |

Shells commonly send `"cs"` (clipboard + select) or `""` (use default `s0`). The Phase 3 scope is the set-path only; any `target` set that includes `c` routes to `NSPasteboard.general`, and the other letters are logged for completeness (macOS has no separate primary selection, so `p`/`q`/`s`/`0`-`7` all collapse to the same pasteboard).

Create `TermCore/ClipboardTargets.swift`:

```swift
//
//  ClipboardTargets.swift
//  TermCore
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

/// OSC 52 target selector. xterm's `<target>` is a STRING — each char
/// selects one slot. We model this as an `OptionSet` so a payload
/// `"cs"` becomes `[.clipboard, .select]` and a payload `""` becomes
/// the default `.select`. Routing in `ContentView` collapses every
/// member to `NSPasteboard.general` on macOS (the only pasteboard
/// that exists), but the shape preserves the xterm semantics so
/// upstream code can't silently lose information.
public struct ClipboardTargets: OptionSet, Sendable, Equatable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let clipboard = ClipboardTargets(rawValue: 1 << 0)  // 'c'
    public static let primary   = ClipboardTargets(rawValue: 1 << 1)  // 'p'
    public static let secondary = ClipboardTargets(rawValue: 1 << 2)  // 'q'
    public static let select    = ClipboardTargets(rawValue: 1 << 3)  // 's'
    public static let cutBuffer = ClipboardTargets(rawValue: 1 << 4)  // '0'..'7'

    /// Parse xterm's `<target>` string into a target set. An empty
    /// string yields the xterm default of `.select` (which on macOS
    /// collapses to `NSPasteboard.general` just like `.clipboard`).
    public static func parse(_ s: String) -> ClipboardTargets {
        if s.isEmpty { return .select }
        var out: ClipboardTargets = []
        for ch in s {
            switch ch {
            case "c": out.insert(.clipboard)
            case "p": out.insert(.primary)
            case "q": out.insert(.secondary)
            case "s": out.insert(.select)
            case "0", "1", "2", "3", "4", "5", "6", "7":
                out.insert(.cutBuffer)
            default:
                // Unknown letter — skip. xterm ignores unknown targets.
                continue
            }
        }
        return out
    }
}
```

- [ ] **Step 2: Add to `OSCCommand`**

```swift
case setClipboard(targets: ClipboardTargets, base64Payload: String)
```

Phase 3 carries the base64-encoded payload verbatim across the XPC boundary; decoding happens on the client side just before the pasteboard write. This keeps `TermCore` from taking an `NSPasteboard` dependency (it's AppKit-only, not framework-safe).

- [ ] **Step 3: Parse OSC 52**

In `mapOSC`:

```swift
case 52:
    // Format: "<target-string>;<base64-payload>"
    // <target-string> is a string of target letters (c/p/q/s/0-7),
    // not a single character — see ClipboardTargets.parse.
    guard let sep = pt.firstIndex(of: ";") else {
        return .unknown(ps: 52, pt: pt)
    }
    let targetStr = String(pt[..<sep])
    let payload = String(pt[pt.index(after: sep)...])
    // Query form ("?") is OSC 52's query path — deferred to Phase 4.
    // Treat as unknown for now.
    if payload == "?" {
        return .unknown(ps: 52, pt: pt)
    }
    let targets = ClipboardTargets.parse(targetStr)
    return .setClipboard(targets: targets, base64Payload: payload)
```

- [ ] **Step 4: Add `DaemonResponse.clipboardWrite`**

In `TermCore/DaemonProtocol.swift`:

```swift
case clipboardWrite(sessionID: SessionID, targets: ClipboardTargets, base64Payload: String)
```

- [ ] **Step 5: Extend `ScreenModelOutput` with `.clipboardWrite`, then emit from `handleOSC`**

Task 1 intentionally shipped `ScreenModelOutput` single-case (`.ptyWriteback` only) because `ClipboardTargets` didn't exist yet. Now that Step 1 of this task has defined `ClipboardTargets`, grow the enum in `TermCore/ScreenModelOutput.swift`:

```swift
public enum ScreenModelOutput: Sendable {
    /// PTY-writeback bytes (DA1/DA2/CPR today; DSR / XtSmGraphics /
    /// terminal parameters / focus events in later phases).
    case ptyWriteback(Data)

    /// OSC 52 clipboard set. `base64Payload` is the raw payload
    /// verbatim — the daemon fans out to clients who decode + prompt +
    /// write to `NSPasteboard.general`.
    case clipboardWrite(targets: ClipboardTargets, base64Payload: String)
}
```

No new sink property, no new install method — just handle `.setClipboard` in `handleOSC` by calling `emitOutput`:

```swift
case .setClipboard(let targets, let payload):
    emitOutput(.clipboardWrite(targets: targets, base64Payload: payload))
    return false  // pure side effect; no snapshot bump
```

- [ ] **Step 6: Daemon fan-out — grow the switch**

Task 1 shipped a single-arm switch in `Session.startOutputHandler()`'s `installOutputSink` closure (only `.ptyWriteback`). Now that Step 5 has grown the enum, grow the switch with the matching arm so it stays exhaustive:

```swift
screenModel.assumeIsolated { model in
    model.installOutputSink { [weak self] event in
        guard let self else { return }
        switch event {
        case .ptyWriteback(let bytes):
            self.write(bytes)
            self.broadcast(.writeback(sessionID: self.id, data: bytes))

        case .clipboardWrite(let targets, let base64Payload):
            // Fan out to attached clients; each client decodes base64,
            // prompts for consent, and writes to NSPasteboard.general.
            self.broadcast(.clipboardWrite(sessionID: self.id,
                                            targets: targets,
                                            base64Payload: base64Payload))
        }
    }
}
```

No additional `assumeIsolated` hop needed — the one installed at `startOutputHandler()` handles every output kind.

- [ ] **Step 7: Client consent + pasteboard write**

In `rTerm/ContentView.swift`'s response handler:

```swift
case .clipboardWrite(_, let targets, let base64):
    Task { @MainActor in
        guard let data = Data(base64Encoded: base64),
              let text = String(data: data, encoding: .utf8) else {
            log.warning("OSC 52: ignoring undecodable payload")
            return
        }
        // On macOS, every OSC 52 target letter routes to
        // NSPasteboard.general (no separate primary/cut-buffer).
        // We still log the full target set so users/debuggers can see
        // what the shell asked for.
        log.info("OSC 52: targets=\(String(describing: targets)) len=\(text.count)")
        if await clipboardConsent(for: targets, preview: text) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
```

Define `clipboardConsent(for:preview:)` using `beginSheetModal(for:completionHandler:)` wrapped in `withCheckedContinuation`. Do NOT use `NSAlert.runModal()` — per Apple docs (https://developer.apple.com/documentation/appkit/nsalert/runmodal) `runModal()` spins a nested modal event loop that blocks the calling thread, which would freeze the renderer and all XPC message handling every time the shell sends an OSC 52. A shell that spams `printf '\033]52;c;...\007'` in a loop would make the app unusable with `runModal()`.

```swift
@MainActor
private func clipboardConsent(for targets: ClipboardTargets, preview: String) async -> Bool {
    // Sheet-modal — non-blocking. Needs a host window; the MainActor
    // context of the response handler gives us access to NSApp's
    // keyWindow (or the first main window if none is key).
    guard let host = NSApp.keyWindow ?? NSApp.mainWindow else {
        // No window to present a sheet on — deny the write silently.
        // Alternative: fall back to a borderless panel; defer to
        // Phase 4.
        return false
    }
    let alert = NSAlert()
    alert.messageText = "Terminal app requests clipboard write"
    let snippet = preview.count > 80 ? String(preview.prefix(80)) + "…" : preview
    alert.informativeText = "About to write to the clipboard:\n\n\(snippet)"
    alert.addButton(withTitle: "Allow")
    alert.addButton(withTitle: "Deny")
    return await withCheckedContinuation { continuation in
        alert.beginSheetModal(for: host) { response in
            continuation.resume(returning: response == .alertFirstButtonReturn)
        }
    }
}
```

**Coalescing:** to prevent stacked prompts when a shell rapidly fires OSC 52, also track a `pendingClipboardPrompt: Bool` on the MainActor view state; if a new consent call arrives while one is pending, skip it (log "dropped OSC 52; prior prompt still open"). Phase 3 keeps this simple — one prompt at a time per session.

- [ ] **Step 8: Tests**

Create `TermCoreTests/ClipboardTests.swift`:

```swift
import Foundation
import Testing
@testable import TermCore

@Suite("OSC 52 clipboard (set)")
struct ClipboardTests {

    @Test("OSC 52 ; c ; <base64> ST parses to setClipboard(.clipboard, payload)")
    func test_osc52_clipboard() {
        var p = TerminalParser()
        let payload = "aGVsbG8="  // "hello"
        let events = p.parse(.osc(52, "c;\(payload)"))
        #expect(events == [.osc(.setClipboard(targets: .clipboard, base64Payload: payload))])
    }

    @Test("OSC 52 ; cs ; <base64> ST parses multi-target set")
    func test_osc52_multi_target() {
        // Per xterm grammar, <target> is a string: 'cs' = clipboard + select.
        var p = TerminalParser()
        let payload = "aGk="
        let events = p.parse(.osc(52, "cs;\(payload)"))
        let expected: ClipboardTargets = [.clipboard, .select]
        #expect(events == [.osc(.setClipboard(targets: expected, base64Payload: payload))])
    }

    @Test("OSC 52 ; ; <base64> ST (empty target) defaults to .select")
    func test_osc52_empty_target_default() {
        // Empty target per xterm = 's0' default; rTerm collapses to .select.
        var p = TerminalParser()
        let payload = "aGk="
        let events = p.parse(.osc(52, ";\(payload)"))
        #expect(events == [.osc(.setClipboard(targets: .select, base64Payload: payload))])
    }

    @Test("OSC 52 query form routes to unknown (Phase 3 set-only)")
    func test_osc52_query_is_unknown() {
        var p = TerminalParser()
        // OSC 52 ; c ; ? ST
        let events = p.parse(.osc(52, "c;?"))
        if case .osc(.unknown(let ps, _)) = events[0] {
            #expect(ps == 52)
        } else {
            Issue.record("expected .osc(.unknown(52, ...))")
        }
    }

    @Test("Model emits clipboard write via sink")
    func test_model_emits_clipboard_sink() async {
        let model = ScreenModel(cols: 80, rows: 24)
        let received = LockedAccumulator<(ClipboardTargets, String)>()
        await model.installOutputSink { event in
            if case .clipboardWrite(let targets, let payload) = event {
                received.append((targets, payload))
            }
        }
        await model.apply([.osc(.setClipboard(targets: .clipboard, base64Payload: "aGk="))])
        let all = received.all()
        #expect(all.count == 1)
        #expect(all[0].0 == .clipboard)
        #expect(all[0].1 == "aGk=")
    }
}

// `LockedAccumulator` + `Data.osc` come from `TermCoreTests/TestHelpers.swift`
// (Track B Task 0).
```

- [ ] **Step 9: Commit**

```bash
git add TermCore/ClipboardTargets.swift \
        TermCore/OSCCommand.swift \
        TermCore/ScreenModelOutput.swift \
        TermCore/TerminalParser.swift \
        TermCore/DaemonProtocol.swift \
        TermCore/ScreenModel.swift \
        rtermd/Session.swift \
        rTerm/ContentView.swift \
        TermCoreTests/ClipboardTests.swift
git commit -m "feat: OSC 52 clipboard set path (Phase 3 — query deferred)

Parser promotes OSC 52 set variant to setClipboard(targets:,
base64Payload:). ClipboardTargets models xterm's target-string
grammar as an OptionSet. Grows the Task 1 ScreenModelOutput enum
with a new .clipboardWrite case (ClipboardTargets is defined in the
same task so the case compiles at this commit boundary) and extends
Session.startOutputHandler's switch with the matching arm. Daemon
fans out via DaemonResponse.clipboardWrite XPC case. Client decodes
base64 on the MainActor, prompts for consent, writes to
NSPasteboard.general.

Query form (OSC 52 ; <target> ; ? ST) routes to .osc(.unknown) — Phase
4 adds the query path (requires client→daemon byte injection)."
```

---

## Task 11: Palette chooser UI

**Spec reference:** §8 Phase 3 Track A — Palette chooser UI.

**Goal:** SwiftUI settings pane lets the user pick from the built-in `TerminalPalette` presets (xterm, solarized-dark, solarized-light; check the actual preset list in `TermCore/TerminalPalette.swift`). Persists via `@AppStorage`. `ContentView` reads the current selection and passes it to `RenderCoordinator`.

**Files:**
- Modify: `rTerm/TerminalPalette.swift` (add `solarizedDark` / `solarizedLight` presets + `preset(named:)` + `allPresetNames`)
- Create: `rTerm/SettingsView.swift`
- Modify: `rTerm/rTermApp.swift` (add `Settings` scene)
- Modify: `rTerm/AppSettings.swift` (add `@AppStorage`-backed `paletteName` that mutates the existing `palette`)
- Modify: `rTerm/ContentView.swift` (observe + propagate)
- Modify: `rTerm/RenderCoordinator.swift` (add palette-identity-compare in `draw(in:)` if missing)

### Steps

- [ ] **Step 1: Plan-time palette-infrastructure snapshot (see appendix)**

Pre-verified (snapshot 2026-05-02, see appendix):
- `TerminalPalette.xtermDefault` at `rTerm/TerminalPalette.swift:100` is the ONLY preset currently defined — no `solarizedDark`, no `solarizedLight`, no `xterm` alias. Step 2 below lands the missing presets.
- `AppSettings` at `rTerm/AppSettings.swift:30` is `@Observable @MainActor public final class` with `public var palette: TerminalPalette = .xtermDefault`. Step 2 extends it; no replacement needed.
- `RenderCoordinator.init` at `rTerm/RenderCoordinator.swift:91` takes the `settings: AppSettings` reference and caches `derivedPalette256` from `settings.palette` (line 105). The existing Phase 2 code already recomputes the 256-color table when `palette` changes; re-verify Step 5 uses that hook rather than bypassing it.

No implementer-side grep needed — the findings are recorded. Jump to Step 2.

- [ ] **Step 2: Add `paletteName` to settings**

**API note (see appendix — `rTerm/TerminalPalette.swift`):** the only preset currently defined is `TerminalPalette.xtermDefault` (line 100). `.solarizedDark` and `.solarizedLight` do not exist. This step lands the new presets **before** the settings surface wires them up, so `TerminalPalette.preset(named:)` has something to dispatch on.

Add the two Solarized presets to `rTerm/TerminalPalette.swift` — RGB values are the canonical 16-slot mapping from Ethan Schoonover's Solarized palette, with "base" colors in ANSI slots 0 and 15 (dark variant inverts which base is foreground vs. background; light variant uses the opposite):

```swift
public extension TerminalPalette {

    /// Solarized Dark — Ethan Schoonover's canonical 16-slot mapping.
    /// Background = base03 (#002b36); foreground = base0 (#839496); cursor = base1.
    /// ANSI 0–7 = black/red/green/yellow/blue/magenta/cyan/base2; ANSI 8–15 =
    /// base03/orange/base01/base00/base0/violet/base1/base3.
    nonisolated static let solarizedDark: TerminalPalette = {
        let ansi: ContiguousArray<RGBA> = [
            RGBA(7,   54,  66),   // 0  base02 (black)
            RGBA(220, 50,  47),   // 1  red
            RGBA(133, 153, 0),    // 2  green
            RGBA(181, 137, 0),    // 3  yellow
            RGBA(38,  139, 210),  // 4  blue
            RGBA(211, 54,  130),  // 5  magenta
            RGBA(42,  161, 152),  // 6  cyan
            RGBA(238, 232, 213),  // 7  base2 (white)
            RGBA(0,   43,  54),   // 8  base03 (bright black)
            RGBA(203, 75,  22),   // 9  orange (bright red)
            RGBA(88,  110, 117),  // 10 base01 (bright green)
            RGBA(101, 123, 131),  // 11 base00 (bright yellow)
            RGBA(131, 148, 150),  // 12 base0 (bright blue)
            RGBA(108, 113, 196),  // 13 violet (bright magenta)
            RGBA(147, 161, 161),  // 14 base1 (bright cyan)
            RGBA(253, 246, 227),  // 15 base3 (bright white)
        ]
        return TerminalPalette(
            ansi: ansi,
            defaultForeground: RGBA(131, 148, 150),   // base0
            defaultBackground: RGBA(0, 43, 54),       // base03
            cursor: RGBA(147, 161, 161))               // base1
    }()

    /// Solarized Light — same 16 slots as Dark; fg/bg swap to light bases.
    /// Background = base3 (#fdf6e3); foreground = base00 (#657b83); cursor = base01.
    nonisolated static let solarizedLight: TerminalPalette = {
        // Same `ansi` table as solarizedDark per the Schoonover spec — the
        // palette is symmetric; only defaultForeground/Background/cursor differ.
        let ansi: ContiguousArray<RGBA> = solarizedDark.ansi
        return TerminalPalette(
            ansi: ansi,
            defaultForeground: RGBA(101, 123, 131),   // base00
            defaultBackground: RGBA(253, 246, 227),   // base3
            cursor: RGBA(88, 110, 117))                // base01
    }()
}
```

Then add the stable-identifier lookup:

```swift
public extension TerminalPalette {
    /// Resolve a preset by its stable identifier. Returns nil for
    /// unknown names; callers should fall back to `.xtermDefault`.
    static func preset(named name: String) -> TerminalPalette? {
        switch name {
        case "xterm":            return .xtermDefault
        case "solarized-dark":   return .solarizedDark
        case "solarized-light":  return .solarizedLight
        default:                 return nil
        }
    }

    static let allPresetNames: [String] = [
        "xterm", "solarized-dark", "solarized-light",
    ]
}
```

In `rTerm/AppSettings.swift` (or the nearest equivalent — verified to be `rTerm/AppSettings.swift:30`, already `@Observable @MainActor`), add the palette-name binding. The existing `AppSettings` already has a mutable `palette: TerminalPalette = .xtermDefault` property — add a persistent `paletteName` layer on top that drives it:

```swift
// In rTerm/AppSettings.swift, inside the @Observable @MainActor class:
@ObservationIgnored
@AppStorage("paletteName") private var storedPaletteName: String = "xterm"

var paletteName: String {
    get { storedPaletteName }
    set {
        storedPaletteName = newValue
        palette = TerminalPalette.preset(named: newValue) ?? .xtermDefault
    }
}
```

Setting `paletteName` mutates both the stored string AND the existing `palette` property, so observers of `AppSettings.palette` (e.g., the renderer) pick up the change without extra wiring.

- [ ] **Step 3: Build settings view**

Create `rTerm/SettingsView.swift`:

```swift
import SwiftUI
import TermCore

struct SettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Picker("Color palette", selection: $settings.paletteName) {
                ForEach(TerminalPalette.allPresetNames, id: \.self) { name in
                    Text(name.replacingOccurrences(of: "-", with: " ").capitalized).tag(name)
                }
            }
            .pickerStyle(.inline)
        }
        .padding()
        .frame(minWidth: 320, minHeight: 180)
    }
}
```

- [ ] **Step 4: Register the Settings scene**

In `rTerm/rTermApp.swift`:

```swift
@main
struct rTermApp: App {
    @State private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
        }
        Settings {
            SettingsView(settings: settings)
        }
    }
}
```

If `ContentView` constructs its own `AppSettings`, migrate the construction to `rTermApp` so both scenes share the instance.

- [ ] **Step 5: Propagate to renderer**

**API note (see appendix — `rTerm/RenderCoordinator.swift`):** `RenderCoordinator` already caches `palette256Source: TerminalPalette` and recomputes `derivedPalette256` when the palette changes. Use the existing mechanism to pick up settings changes — do **not** add a separate `palette` property on `RenderCoordinator` that duplicates `settings.palette`.

In `rTerm/ContentView.swift`:

```swift
@Environment(AppSettings.self) private var settings

var body: some View {
    TermView(
        screenModel: session.screenModel,
        settings: settings,
        onInput: { session.sendInput($0) },
        onPaste: { session.paste($0) }
    )
    .navigationTitle(session.windowTitle ?? "rTerm")
    ...
}
```

In `TermView.updateNSView`, trigger a redraw when the palette name changes. The existing `RenderCoordinator.draw(in:)` already reads `settings.palette` indirectly via `palette256Source` comparison — bumping `view.needsDisplay` is sufficient to force the recompute on the next frame:

```swift
// Inside updateNSView(_:context:):
view.needsDisplay = true
```

If the renderer does not currently invalidate `palette256Source` when `settings.palette` changes identity, add a cheap equality check at the top of `draw(in:)`:

```swift
if settings.palette != palette256Source {
    palette256Source = settings.palette
    derivedPalette256 = ColorProjection.derivePalette256(from: settings.palette)
}
```

`TerminalPalette` conforms to `Equatable`, so `!=` is synthesized.

- [ ] **Step 6: Manual visual test + commit**

Open the app, go to Settings, switch between palettes, confirm the live terminal view updates immediately.

```bash
git add rTerm/SettingsView.swift \
        rTerm/rTermApp.swift \
        rTerm/AppSettings.swift \
        rTerm/ContentView.swift \
        rTerm/RenderCoordinator.swift \
        rTerm/TerminalPalette.swift
git commit -m "feat(rTerm): palette chooser Settings scene

Settings scene lets the user pick among built-in TerminalPalette
presets (xterm, solarized-dark, solarized-light). Persisted via
@AppStorage('paletteName'). TermCore gains solarizedDark and
solarizedLight preset statics (canonical Schoonover 16-slot mapping),
plus TerminalPalette.preset(named:) + allPresetNames for stable-id
lookup. AppSettings.paletteName setter updates both the stored string
and the existing AppSettings.palette property, so the renderer's
existing palette256Source compare-and-recompute path picks up changes
on the next draw — no session restart required."
```

---

## Track A completion checklist

After Task 11 lands, verify:

- [ ] `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test` — all green (expect ≥ 240 tests, up from Track B's ~230).
- [ ] `xcodebuild -project rTerm.xcodeproj -scheme rTermTests test` — all green (expect ≥ 62 tests).
- [ ] Manual: shell integration test
  - `printf '\033]0;hello\007'` updates window title (Phase 1 regression check).
  - `printf '\033[5mHELLO\033[0m\n'` blinks "HELLO" (Task 5).
  - `printf '\033]8;id=1;https://apple.com\033\\Apple\033]8;;\033\\\n'` renders "Apple" as a hyperlink; hover highlights; click opens Safari (Task 8+9).
  - `printf '\033[4 q'` changes cursor to steady underline (Task 3).
  - In vim, `:q` should work without stuck states (DA1/DA2/CPR responses work — Task 2).
  - `tput setaf 4; echo foo` still colors correctly (Phase 1 regression check).
- [ ] OSC 52 prompt fires once per session on `printf '\033]52;c;aGVsbG8=\007'`; "Allow" writes "hello" to the macOS clipboard; "Deny" is silently ignored.
- [ ] Settings → palette switch applies live.
- [ ] No new `xcodebuild` warnings (deprecation warnings from intentional Track B deprecations are expected; no others).
- [ ] PR description enumerates Track A features and links to the spec §8 Track A section.

**Self-review note:**
- Every §8 Track A item has a task.
- DECOM (Task 6) and DECCOLM (Task 7) both route through `handleSetMode` — confirm `DECPrivateMode.init(rawParam:)` has both `.originMode` and `.column132` entries after Task 7 lands.
- OSC 52 query path is deliberately routed to `.unknown` per the Phase 3 scope answer; the Phase 4 plan will revisit.
- Fixture corpus completion (spec §8 bullet "Integration fixture corpus completion") was delivered in Track B Task 2, not here — verify the bullet isn't duplicated.
- `cursorShape` flows through `TerminalState` (from Track B Task 4 convenience init). Task 3 (DECSCUSR) + Task 4 (snapshot-field exposure) in Track A depend on the Track B convenience init existing.

If any gap surfaces during implementation, insert a sub-task rather than dropping the feature. No TODOs in production code.

---

## Appendix: Source-tree verification snapshot (2026-05-02)

Plan-time facts verified against `/Users/ronny/rdev/rTerm/` (branch `phase-2-control-chars`). Steps above that previously carried inline `**API note — verified against …:**` blocks reference this appendix; the facts live here to reduce per-step noise. Matches the Phase 1 `**Verified toolchain**` idiom.

### `TermCore/ScreenModel.swift`
- `public actor ScreenModel` at line 49.
- `active` is a get-only computed property at lines 191–193; mutations route through `mutateActive { buf in … }`.
- `scrollRegion` is a `ScrollRegion?` field on `Buffer` (line 158), **not** on `ScreenModel`; `ScrollRegion.top: Int` is non-optional.
- Existing handlers for `.cursorPosition`, `.cursorHorizontalAbsolute`, `.verticalPositionAbsolute` go through `mutateActive { buf in … clampCursor(in: &buf) … }` — Task 6 (DECOM) preserves this pattern and adds DECOM-aware offsets inside the closure.
- Two `Cursor(row: 0, col: 0)` sites (lines 162, 922) — migrated to `Cursor.zero` in Track B Task 4.

### `rtermd/Session.swift`
- `broadcast(_:)` at line 216 takes a typed `DaemonResponse`. No method named `fanOutResponse`; `fanOutToClients(_:)` wraps raw bytes — Task 1 uses `broadcast` for the typed writeback fan-out.
- `Session.init` (line 111) runs before `startOutputHandler()` on a different thread than the daemon queue — it is NOT safe to call `assumeIsolated` from `init`. Install the output sink lazily inside `startOutputHandler()`.
- `Session.write(_:)` at line 272 performs the full-write loop against `primaryFD`. Task 1's output-sink closure calls `self.write(bytes)` directly.
- Current `ScreenModel` construction site at line 123: `ScreenModel(cols: Int(cols), rows: Int(rows), queue: queue)` — Track B Task 5 retypes the `queue` parameter.

### `TermCore/TerminalParser.swift`
- `csiParam` / `csiIntermediate` states (lines 42, 43, 112, 122) already carry `intermediates: [UInt8]` into `mapCSI`.
- Private-mode markers (`<`, `=`, `>`, `?`) are stashed in intermediates at line 278.
- Tasks 2 + 3 + 4 extend `mapCSI` with new final-byte arms (`c`, `n`, `q`); the intermediates threading is already in place.

### `rTerm/RenderCoordinator.swift`
- `RenderCoordinator.init` at line 91 takes a `settings: AppSettings` reference and caches `derivedPalette256` from `settings.palette` (line 105). The Phase 2 code recomputes the 256-color table when `palette` changes — Task 11 (palette chooser) hooks into that existing path rather than adding a duplicate `palette` property.
- `RenderCoordinator` already caches `palette256Source: TerminalPalette` and recomputes `derivedPalette256` on identity change — Task 11 reuses this mechanism.
- No existing `maxBuffersInFlight` constant; no existing `DispatchSemaphore`. Track B Task 7 introduces both with `count = 3` (Apple triple-buffer canonical).
- `cellAt(row:col:)` at line 197 is `@inline(__always)` with `let historyRow = history[historyRowIdx]` read inside the closure (line 200). Track B Task 8 hoists the read to the outer row loop; Efficiency research noted LLVM LICM may already hoist — Task 8 adds a measurement step before the restructure.

### `rTerm/GlyphAtlas.swift`
- `GlyphAtlas.cellWidth: CGFloat` (line 66) and `GlyphAtlas.cellHeight: CGFloat` (line 68). All four atlas variants share identical cell metrics because they share the same monospace font face + size.
- Task 9 (OSC 8 renderer hover) adds a `cellSize: CGSize` computed property on `RenderCoordinator` reading from `regularAtlas.cellWidth/cellHeight` — the canonical accessor for pixel-to-cell mapping.

### `rTerm/TerminalPalette.swift`
- `TerminalPalette.xtermDefault` at line 100 is the only preset defined. No `solarizedDark`, `solarizedLight`, `xterm` alias. File lives in the **rTerm app target**, NOT TermCore — Task 11 corrects the path.

### `rTerm/AppSettings.swift`
- `AppSettings` at line 30 is `@Observable @MainActor public final class`. Existing `public var palette: TerminalPalette = .xtermDefault` is mutated by Task 11's new `paletteName` setter so observers (the renderer) pick up changes without extra wiring.

### `rTerm/TermView.swift`
- Line 148: `view.preferredFramesPerSecond = 60`. The view is NOT on-demand; Task 5 (blink) does not need to add a redraw timer.
