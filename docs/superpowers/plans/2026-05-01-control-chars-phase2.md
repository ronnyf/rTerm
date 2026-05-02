# Control-Characters Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver full TUI compatibility — alt-screen apps (vim, tmux, htop, less, mc) feel native; bounded scrollback survives detach/reattach; arrow keys / Home / End / PgUp / PgDn behave correctly under DECCKM; bracketed paste keeps shells from interpreting paste content as input; renderer activates italic / bold-italic / dim / reverse / strikethrough that Phase 1 already parsed and stored on `Cell.style.attributes`.

**Architecture:** See spec at `/Users/ronny/rdev/rTerm/docs/superpowers/specs/2026-04-30-control-characters-design.md`. This plan implements §8 "Phase 2 — Full TUI + scrollback". All architectural seams are already laid by Phase 1: `BufferKind` and `cursorVisible/activeBuffer` exist on `ScreenSnapshot`; `AttachPayload.recentHistory` exists; `CSICommand.setMode/.setScrollRegion` cases exist; `DECPrivateMode` enum is fully populated; `Cell.style.attributes` carries italic/dim/reverse/strikethrough/blink flags already; `GlyphAtlas.Variant.italic/.boldItalic` are reserved as commented-out cases. Phase 2 wires these up.

**Tech Stack:** Swift 6.0 (strict concurrency, `SWIFT_APPROACHABLE_CONCURRENCY = YES`), Swift Testing (`@Test` / `#expect`), Xcode 16+, macOS 15.0 deployment target, Metal (`MTKView` + CoreText), XPC, AppKit (NSEvent for keyDown / scrollWheel / paste). `import Synchronization` for `Mutex`.

**Execution contract:**
- Every implementer task ends with `git commit`. Implementers **do not run `xcodebuild`** for any reason.
- **Implementer-facing steps** (the `- [ ]` checkboxes) that mention "Run tests", "Build the full project", "Full test suite + build", etc. and contain `xcodebuild …` commands are **skipped by the implementer**. They exist as documentation for the controller's verification pass. The implementer's real work is: write test → write impl → commit. In that order.
- **After each commit**, the controller dispatches `agentic:xcode-build-reporter` (using the `agentic:xcode-build-reporting` skill) to run the relevant tests and verify a clean build. The reporter returns a compact pass/fail report.
- If the report shows failures, the controller re-dispatches the implementer with a fix-focused prompt including the report.
- After the build reporter passes, the controller dispatches spec-compliance and code-quality reviewers per `superpowers:subagent-driven-development`. Only then is the task marked complete and `/simplify` is invoked before the next task.

`xcodebuild` commands assume the repo root working directory.

**Task ordering rationale.** T1 (parser) is independent and unblocks the rest. T2 (dual-buffer refactor without behavior change) is a prerequisite for T4 (alt-screen), T5 (per-buffer scroll region), and T6 (main-only scrollback). T3 (modes) feeds T4 (alt-screen modes), T7 (DECCKM → KeyEncoder), and T8 (bracketed paste). T9 (renderer activation) and T10 (scrollback UI) are the final user-visible deliverables.

**Spec-extending decisions documented here (not separately tracked in the spec):**

- `ScreenSnapshot` grows four fields beyond what spec §4 lines 347-355 enumerates: `cursorKeyApplication`, `bracketedPaste`, `bellCount: UInt64`, `autoWrap`. Rationale: every one of these has to be readable nonisolated by either the input encoder (`KeyEncoder`/`paste`) or the renderer (`bellCount`), and parking them on the snapshot beats adding parallel `Mutex<Box>` accessors. `autoWrap` specifically prevents cold-attach client/daemon divergence (without it the client mirror starts at default-true and renders writes-past-margin differently from a daemon with DECAWM disabled). All four use `decodeIfPresent ?? default` Codable so Phase 1-shaped payloads still parse.
- `DaemonResponse.attachPayload(sessionID:, payload: AttachPayload)` is **already defined** in `TermCore/DaemonProtocol.swift:69` from Phase 1, and `AttachPayload` from Phase 1 already carries `recentHistory: ContiguousArray<Row>` and `historyCapacity: Int` (just both empty/zero). Phase 2 fills them in T6 — no new RPC envelope work.
- `DECPrivateMode` parser dispatch emits one `.csi(.setMode(...))` per param when a compound DECSET is received (e.g. `CSI ? 1 ; 7 ; 25 h` becomes three events). Singular `CSICommand.setMode(_, enabled:)` signature is preserved by looping at the dispatch site rather than restructuring the enum.

**Known Phase 2 limitations (deferred to Phase 3):**

- Cold attach when daemon's `activeBuffer == .alt`: client receives an empty `recentHistory` and starts main-buffer empty. When the user later exits alt, main appears blank with only the (empty) scrollback. Spec §4 acknowledges this; Phase 3 `fetchHistory(sessionID:, rowRange:)` RPC closes the gap.
- Integration-fixture corpus (spec §7.3) covers only `vimStartupSequence`; `ls --color`, `clear`, `top/htop` fixture scaffolding deferred to a follow-up Phase 2.5 if needed (the per-feature tests in T3-T10 cover the same code paths at the unit level).

---

## Task 1: Parser — DEC private modes (`CSI ? Pm h/l`), scroll region (`CSI top;bot r`), and `ESC 7 / ESC 8` save/restore

**Spec reference:** §2 (Parser), §3 (`DECPrivateMode`, `CSICommand.setMode`, `CSICommand.setScrollRegion`).

**Goal:** Phase 1 stashes the `?` private-mode marker into `intermediates` and falls through to `.csi(.unknown(...))`. Phase 2 wires `mapCSI` to recognize `[?] h/l` → `.csi(.setMode(decoded, enabled:))`, `r` (no intermediates) → `.csi(.setScrollRegion(top:bottom:))`, and extends `handleEscapeByte` so `ESC 7` / `ESC 8` emit `.csi(.saveCursor)` / `.csi(.restoreCursor)` (semantically equivalent to `CSI s` / `CSI u`).

`ScreenModel.handleCSI` already returns `false` for `setMode` and `setScrollRegion` (Phase 1 leaves them as no-ops). After this task, the parser emits the structured events but the model still does nothing with them — that lands in T3, T4, T5.

**Files:**
- Modify: `TermCore/TerminalParser.swift` (mapCSI: add `?` intermediate + `r` final handling; handleEscapeByte: add ESC 7/8)
- Modify: `TermCoreTests/TerminalParserTests.swift` (add test cases for the new sequences)

### Steps

- [ ] **Step 1: Write failing tests for DEC private modes**

Append to `TermCoreTests/TerminalParserTests.swift`:

```swift
// MARK: - DEC private modes (Phase 2)

@Test("ESC[?1h emits setMode(cursorKeyApplication, enabled: true)")
func test_csi_decset_cursorKeyApplication_on() {
    var parser = TerminalParser()
    let events = parser.parse(Data([0x1B, 0x5B, 0x3F, 0x31, 0x68]))  // ESC [ ? 1 h
    #expect(events == [.csi(.setMode(.cursorKeyApplication, enabled: true))])
}

@Test("ESC[?1l emits setMode(cursorKeyApplication, enabled: false)")
func test_csi_decreset_cursorKeyApplication_off() {
    var parser = TerminalParser()
    let events = parser.parse(Data([0x1B, 0x5B, 0x3F, 0x31, 0x6C]))  // ESC [ ? 1 l
    #expect(events == [.csi(.setMode(.cursorKeyApplication, enabled: false))])
}

@Test("All known DEC private modes decode to the correct case")
func test_csi_decset_known_modes() {
    let cases: [(payload: [UInt8], mode: DECPrivateMode)] = [
        ([0x37],                     .autoWrap),                 // 7
        ([0x32, 0x35],               .cursorVisible),            // 25
        ([0x34, 0x37],               .alternateScreen47),        // 47
        ([0x31, 0x30, 0x34, 0x37],   .alternateScreen1047),      // 1047
        ([0x31, 0x30, 0x34, 0x38],   .saveCursor1048),           // 1048
        ([0x31, 0x30, 0x34, 0x39],   .alternateScreen1049),      // 1049
        ([0x32, 0x30, 0x30, 0x34],   .bracketedPaste),           // 2004
    ]
    for (payload, expected) in cases {
        var parser = TerminalParser()
        var bytes: [UInt8] = [0x1B, 0x5B, 0x3F]
        bytes.append(contentsOf: payload)
        bytes.append(0x68)  // 'h'
        let events = parser.parse(Data(bytes))
        #expect(events == [.csi(.setMode(expected, enabled: true))],
                "Failed for mode \(expected)")
    }
}

@Test("Unknown DEC mode preserves the parameter")
func test_csi_decset_unknown_mode() {
    var parser = TerminalParser()
    // ESC [ ? 9999 h
    let events = parser.parse(Data([0x1B, 0x5B, 0x3F, 0x39, 0x39, 0x39, 0x39, 0x68]))
    #expect(events == [.csi(.setMode(.unknown(9999), enabled: true))])
}

@Test("Multi-param DEC mode emits one .setMode event per param")
func test_csi_decset_multi_param() {
    var parser = TerminalParser()
    // ESC [ ? 1 ; 7 h — DECSET grammar allows compound mode lists; tmux/vim
    // startup pipelines compound DECSET, so the parser emits one .setMode
    // per param (preserves the singular .setMode(_, enabled:) signature
    // by looping at the dispatch site).
    let events = parser.parse(Data([0x1B, 0x5B, 0x3F, 0x31, 0x3B, 0x37, 0x68]))
    #expect(events == [
        .csi(.setMode(.cursorKeyApplication, enabled: true)),
        .csi(.setMode(.autoWrap, enabled: true)),
    ])
}

@Test("Multi-param DEC mode reset (l) emits one .setMode event per param")
func test_csi_decreset_multi_param() {
    var parser = TerminalParser()
    // ESC [ ? 1 ; 7 ; 25 l — three modes, all reset
    let bytes: [UInt8] = [0x1B, 0x5B, 0x3F, 0x31, 0x3B, 0x37, 0x3B, 0x32, 0x35, 0x6C]
    let events = parser.parse(Data(bytes))
    #expect(events == [
        .csi(.setMode(.cursorKeyApplication, enabled: false)),
        .csi(.setMode(.autoWrap, enabled: false)),
        .csi(.setMode(.cursorVisible, enabled: false)),
    ])
}

@Test("DEC mode set survives byte-boundary chunking (cross-chunk path)")
func test_csi_decset_cross_chunk() {
    var parser = TerminalParser()
    // ESC [ ? 1 0 4 9 h — fed one byte at a time; identical final result.
    let bytes: [UInt8] = [0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x68]
    var events: [TerminalEvent] = []
    for byte in bytes {
        events.append(contentsOf: parser.parse(Data([byte])))
    }
    #expect(events == [.csi(.setMode(.alternateScreen1049, enabled: true))])
}

@Test("CSI?0h emits .setMode(.unknown(0), enabled: true)")
func test_csi_decset_zero_param_unknown() {
    var parser = TerminalParser()
    // Param "0" is not a defined DEC private mode — must round-trip via .unknown.
    let events = parser.parse(Data([0x1B, 0x5B, 0x3F, 0x30, 0x68]))
    #expect(events == [.csi(.setMode(.unknown(0), enabled: true))])
}

// MARK: - DECSTBM scroll region (Phase 2)

@Test("ESC[r resets scroll region (both nil)")
func test_csi_decstbm_reset() {
    var parser = TerminalParser()
    let events = parser.parse(Data([0x1B, 0x5B, 0x72]))  // ESC [ r
    #expect(events == [.csi(.setScrollRegion(top: nil, bottom: nil))])
}

@Test("ESC[5;20r sets top=5 bottom=20 (parser stays VT 1-indexed; ScreenModel shifts)")
func test_csi_decstbm_set() {
    var parser = TerminalParser()
    // ESC [ 5 ; 2 0 r
    let events = parser.parse(Data([0x1B, 0x5B, 0x35, 0x3B, 0x32, 0x30, 0x72]))
    #expect(events == [.csi(.setScrollRegion(top: 5, bottom: 20))])
}

@Test("ESC[;15r sets only bottom (top nil = use top of screen)")
func test_csi_decstbm_only_bottom() {
    var parser = TerminalParser()
    // ESC [ ; 1 5 r
    let events = parser.parse(Data([0x1B, 0x5B, 0x3B, 0x31, 0x35, 0x72]))
    #expect(events == [.csi(.setScrollRegion(top: nil, bottom: 15))])
}

@Test("DECSTBM with top > bottom passes through unchanged (parser doesn't validate)")
func test_csi_decstbm_top_gt_bottom_passes_through() {
    var parser = TerminalParser()
    // ESC [ 6 ; 3 r — parser pass-through; ScreenModel rejects in T5.
    let events = parser.parse(Data([0x1B, 0x5B, 0x36, 0x3B, 0x33, 0x72]))
    #expect(events == [.csi(.setScrollRegion(top: 6, bottom: 3))])
}

// MARK: - ESC 7 / ESC 8 (DECSC / DECRC) — Phase 2

@Test("ESC 7 emits .csi(.saveCursor) (DECSC == CSI s)")
func test_esc_7_decsc() {
    var parser = TerminalParser()
    let events = parser.parse(Data([0x1B, 0x37]))  // ESC 7
    #expect(events == [.csi(.saveCursor)])
}

@Test("ESC 8 emits .csi(.restoreCursor) (DECRC == CSI u)")
func test_esc_8_decrc() {
    var parser = TerminalParser()
    let events = parser.parse(Data([0x1B, 0x38]))  // ESC 8
    #expect(events == [.csi(.restoreCursor)])
}
```

- [ ] **Step 2: Run new tests — expect failures**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests -only-testing TermCoreTests/TerminalParserTests test`

Expected: 10 new tests fail (parser still emits `.csi(.unknown(...))` for `?`-prefix sequences and `.unrecognized(0x37/0x38)` for ESC 7/8).

- [ ] **Step 3: Add `appendCSIEvents` dispatcher + simplified `mapCSI` + `decodeDECPrivateMode` helper**

In `TermCore/TerminalParser.swift`, find the `mapCSI` method. Replace the existing body with this version (keep the `// MARK: - CSI mapping` and doc comment), and add the new `appendCSIEvents` dispatcher + `decodeDECPrivateMode` helper:

```swift
/// Decode a fully-collected CSI into one or more events appended to `events`.
///
/// Most CSI sequences emit a single event. The exception is DEC private
/// mode set/reset (`CSI ? Pm h/l`): the spec grammar allows compound mode
/// lists (`CSI ? 1 ; 7 ; 25 h`), and tmux/vim startup pipelines compound
/// DECSET. Each `Pm` in the list emits its own `.csi(.setMode(...))` so
/// `CSICommand.setMode(_, enabled:)` keeps its singular signature.
private static func appendCSIEvents(params: [Int], intermediates: [UInt8], final: UInt8, into events: inout [TerminalEvent]) {
    // DEC private mode multi-emit: `?` intermediate + h/l final.
    if intermediates == [0x3F], (final == 0x68 || final == 0x6C) {
        let enabled = (final == 0x68)
        let modeParams = params.isEmpty ? [0] : params
        for p in modeParams {
            events.append(.csi(.setMode(decodeDECPrivateMode(p), enabled: enabled)))
        }
        return
    }
    events.append(.csi(mapCSI(params: params, intermediates: intermediates, final: final)))
}

private static func mapCSI(params: [Int], intermediates: [UInt8], final: UInt8) -> CSICommand {
    // VT defaults: a missing numeric parameter counts as 1 for motion,
    // 0 for erase region selectors.
    func p(_ i: Int, default d: Int) -> Int {
        guard i < params.count else { return d }
        return params[i] == 0 ? d : params[i]
    }

    // Any sequence with intermediates falls through to .unknown. The `?`
    // intermediate + h/l combination is intercepted by appendCSIEvents
    // before this function runs, so the only `?`-prefix calls that reach
    // here have a final byte other than h/l (e.g. `CSI ? 6 n` DECDSR or
    // `CSI ? r` DEC restore mode — Phase 3 disambiguates these).
    guard intermediates.isEmpty else {
        return .unknown(params: params, intermediates: intermediates, final: final)
    }

    switch final {
    case 0x41 /* A */: return .cursorUp(p(0, default: 1))
    case 0x42 /* B */: return .cursorDown(p(0, default: 1))
    case 0x43 /* C */: return .cursorForward(p(0, default: 1))
    case 0x44 /* D */: return .cursorBack(p(0, default: 1))
    case 0x47 /* G */: return .cursorHorizontalAbsolute(p(0, default: 1))
    case 0x64 /* d */: return .verticalPositionAbsolute(p(0, default: 1))
    case 0x48, 0x66 /* H, f */:
        let row = p(0, default: 1) - 1
        let col = p(1, default: 1) - 1
        return .cursorPosition(row: max(0, row), col: max(0, col))
    case 0x73 /* s */: return .saveCursor
    case 0x75 /* u */: return .restoreCursor
    case 0x4A /* J */: return .eraseInDisplay(Self.mapEraseRegion(p(0, default: 0)))
    case 0x4B /* K */: return .eraseInLine(Self.mapEraseRegion(p(0, default: 0)))
    case 0x6D /* m */:
        return .sgr(Self.mapSGR(params: params))
    case 0x72 /* r */:
        // DECSTBM: top;bottom. `0` or missing means "use screen edge" (nil).
        // Parser passes through VT 1-indexed values; ScreenModel does the
        // 1→0 conversion so the wire/log format keeps the original value.
        let topRaw = params.count > 0 ? params[0] : 0
        let botRaw = params.count > 1 ? params[1] : 0
        let top: Int? = topRaw > 0 ? topRaw : nil
        let bot: Int? = botRaw > 0 ? botRaw : nil
        return .setScrollRegion(top: top, bottom: bot)
    default:
        return .unknown(params: params, intermediates: intermediates, final: final)
    }
}

/// Map a numeric DEC private mode parameter to its enum case.
private static func decodeDECPrivateMode(_ p: Int) -> DECPrivateMode {
    switch p {
    case 1:    return .cursorKeyApplication
    case 7:    return .autoWrap
    case 25:   return .cursorVisible
    case 47:   return .alternateScreen47
    case 1047: return .alternateScreen1047
    case 1048: return .saveCursor1048
    case 1049: return .alternateScreen1049
    case 2004: return .bracketedPaste
    default:   return .unknown(p)
    }
}
```

- [ ] **Step 4: Update CSI dispatch call sites to call `appendCSIEvents` instead of `mapCSI` directly**

The parser has three sites that emit a CSI event after final-byte detection: `handleCSIEntryByte`, `handleCSIParamByte`, and `handleCSIIntermediateByte`. Replace each `events.append(.csi(Self.mapCSI(...)))` with the new dispatcher.

In `handleCSIEntryByte`:

```swift
// REPLACE:
events.append(.csi(Self.mapCSI(params: [], intermediates: [], final: byte)))
// WITH:
Self.appendCSIEvents(params: [], intermediates: [], final: byte, into: &events)
```

In `handleCSIParamByte` (two replacement sites — the `isCSIIntermediate` branch's flush and the `isCSIFinal` branch):

```swift
// REPLACE the .isCSIFinal branch's final emission:
events.append(.csi(Self.mapCSI(params: flushed, intermediates: intermediates, final: byte)))
// WITH:
Self.appendCSIEvents(params: flushed, intermediates: intermediates, final: byte, into: &events)
```

In `handleCSIIntermediateByte`:

```swift
// REPLACE:
events.append(.csi(Self.mapCSI(params: params, intermediates: intermediates, final: byte)))
// WITH:
Self.appendCSIEvents(params: params, intermediates: intermediates, final: byte, into: &events)
```

After this step, all three dispatch paths route DEC private mode multi-param sequences through the multi-emit loop while every other CSI flows unchanged through `mapCSI`.

- [ ] **Step 5: Wire `ESC 7` / `ESC 8` in `handleEscapeByte`**

Find `handleEscapeByte` in `TermCore/TerminalParser.swift`. Replace the `default` arm of the switch by adding two cases before it:

```swift
private mutating func handleEscapeByte(_ byte: UInt8, events: inout [TerminalEvent]) {
    switch byte {
    case 0x5B:  // '['
        state = .csiEntry
    case 0x5D:  // ']'
        state = .oscString(ps: nil, accumulator: "", pendingST: false)
    case 0x50:  // 'P'
        state = .dcsIgnore(pendingST: false)
    case 0x37:  // '7' — DECSC (save cursor); semantically identical to CSI s.
        events.append(.csi(.saveCursor))
        state = .ground
    case 0x38:  // '8' — DECRC (restore cursor); semantically identical to CSI u.
        events.append(.csi(.restoreCursor))
        state = .ground
    case 0x18, 0x1A:  // CAN, SUB
        state = .ground
    case 0x1B:  // ESC restart
        state = .escape
    default:
        events.append(.unrecognized(byte))
        state = .ground
    }
}
```

- [ ] **Step 6: Run new tests — expect pass**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests -only-testing TermCoreTests/TerminalParserTests test`

Expected: all new tests pass (single-param + multi-param + cross-chunk + DECSTBM + ESC 7/8); all previously-passing tests still pass.

- [ ] **Step 7: Commit**

```bash
git add TermCore/TerminalParser.swift TermCoreTests/TerminalParserTests.swift
git commit -m "parser: DEC private modes (multi-emit), DECSTBM, ESC 7/8 (Phase 2 T1)

New appendCSIEvents dispatcher handles the multi-event case:
- '?' intermediate + h/l → emit one .csi(.setMode(...)) per param.
  DECSET grammar allows compound mode lists (CSI?1;7;25h); tmux/vim
  startup pipelines compound DECSET. Singular .setMode(_, enabled:)
  signature preserved by looping at the dispatch site.

mapCSI handles the single-event path:
- 'r' final (no intermediates) → .setScrollRegion(top:Int?, bottom:Int?)
  — VT 1-indexed; ScreenModel does the 1→0 shift on apply
- '?'-prefix non-h/l finals (e.g., CSI?6n DECDSR, CSI?r DEC restore-mode)
  fall through to .unknown — Phase 3 disambiguates

handleEscapeByte adds:
- ESC 7 (DECSC) → .csi(.saveCursor)
- ESC 8 (DECRC) → .csi(.restoreCursor)
  (semantically identical to CSI s / CSI u)

decodeDECPrivateMode maps 1, 7, 25, 47, 1047, 1048, 1049, 2004 to enum
cases; unknown params wrap as .unknown(p).

ScreenModel handleCSI still returns false for .setMode/.setScrollRegion
— behavior wiring lands in Phase 2 T3/T4/T5."
```

---

## Task 2: ScreenModel — dual-buffer refactor (no behavior change)

**Spec reference:** §4 ("State layout" — `Buffer` struct, `main`, `alt`, `activeKind`).

**Goal:** Refactor `ScreenModel` so all per-buffer mutable state (grid, cursor, savedCursor, scrollRegion) lives inside a `Buffer` value-type, with `main: Buffer` + `alt: Buffer` + `activeKind: BufferKind`. Every existing handler operates against the **active** buffer via a single `mutateActive { … }` helper. No external-visible behavior changes — `activeKind` stays `.main`, alt buffer is allocated but never written. All ~30 existing `ScreenModelTests` continue to pass unchanged.

This task lays the storage shape so T4 (alt-screen modes) and T5 (DECSTBM scroll region) become localized changes.

**Why a separate refactor task:** the dual-buffer change touches every handler. Doing it without behavior change keeps the diff reviewable. Compiling tests still green proves we didn't regress.

**Files:**
- Modify: `TermCore/ScreenModel.swift` (Buffer struct, mutateActive helper, handler rewrites, snapshot/restore updates)

### Steps

- [ ] **Step 1: Read existing `ScreenModel.swift` to confirm starting state**

Implementer reads `/Users/ronny/rdev/rTerm/TermCore/ScreenModel.swift`. Note the four pieces of per-buffer state currently held as top-level actor properties: `grid`, `cursor`, `savedCursor`. The `pen`, `windowTitle`, `iconName`, `version`, `cols`, `rows`, `_latestSnapshot`, `executorQueue`, `log` are terminal-wide (or infra) and stay at the actor level.

- [ ] **Step 2: Introduce `ScrollRegion` and nested `Buffer` types**

In `TermCore/ScreenModel.swift`, immediately above `public actor ScreenModel {`, add:

```swift
/// Inclusive 0-indexed row range that limits where natural scrolls move data.
/// `nil` `scrollRegion` on a `Buffer` means full-screen (default).
struct ScrollRegion: Sendable, Equatable {
    var top: Int       // 0-indexed inclusive
    var bottom: Int    // 0-indexed inclusive
}
```

Inside the actor body (after the `// MARK: - Custom executor` block, before `// MARK: - Initialization`), add the nested `Buffer` struct:

```swift
// MARK: - Buffer

/// Per-buffer mutable state. Both `main` and `alt` are full instances;
/// `activeKind` selects which one event handlers mutate.
private struct Buffer: Sendable {
    var grid: ContiguousArray<Cell>
    var cursor: Cursor
    var savedCursor: Cursor?
    var scrollRegion: ScrollRegion?

    init(rows: Int, cols: Int) {
        self.grid = ContiguousArray(repeating: .empty, count: rows * cols)
        self.cursor = Cursor(row: 0, col: 0)
        self.savedCursor = nil
        self.scrollRegion = nil
    }
}
```

- [ ] **Step 3: Replace per-buffer state with `main` / `alt` / `activeKind`**

In `ScreenModel`, replace the existing per-buffer field declarations:

```swift
// REMOVE these lines:
private var grid: ContiguousArray<Cell>
private var cursor: Cursor
private var savedCursor: Cursor?
```

with:

```swift
private var main: Buffer
private var alt: Buffer
private var activeKind: BufferKind = .main
```

- [ ] **Step 4: Rewrite the initializer to allocate both buffers**

Replace the existing `public init(cols: Int = 80, rows: Int = 24, queue: DispatchQueue? = nil)` body with:

```swift
public init(cols: Int = 80, rows: Int = 24, queue: DispatchQueue? = nil) {
    let q = queue ?? DispatchQueue(label: "com.ronnyf.TermCore.ScreenModel")
    // swiftlint:disable:next force_cast
    self.executorQueue = q as! DispatchSerialQueue
    self.cols = cols
    self.rows = rows
    let main = Buffer(rows: rows, cols: cols)
    let alt = Buffer(rows: rows, cols: cols)
    self.main = main
    self.alt = alt
    let initial = ScreenSnapshot(
        activeCells: main.grid,
        cols: cols,
        rows: rows,
        cursor: main.cursor,
        cursorVisible: true,
        activeBuffer: .main,
        windowTitle: nil,
        version: 0
    )
    self._latestSnapshot = Mutex(SnapshotBox(initial))
}
```

- [ ] **Step 5: Add `mutateActive` and `readActive` helpers**

Add this region near the top of the actor body (just under the `Buffer` struct):

```swift
// MARK: - Active-buffer access

/// Yields an inout reference to whichever buffer is currently active.
/// All event handlers that mutate per-buffer state route through here.
private func mutateActive<R>(_ body: (inout Buffer) -> R) -> R {
    switch activeKind {
    case .main: return body(&main)
    case .alt:  return body(&alt)
    }
}

/// Read-only view of the currently active buffer.
private var active: Buffer {
    activeKind == .main ? main : alt
}
```

- [ ] **Step 6: Rewrite `handlePrintable`, `handleC0`, `handleCSI`, `clampCursor`, erase helpers, and `scrollUp` to use `mutateActive`**

Replace the implementations as follows. Keep all existing doc comments.

```swift
private func handlePrintable(_ char: Character) -> Bool {
    let pen = self.pen
    return mutateActive { buf in
        if buf.cursor.col >= cols {
            buf.cursor.col = 0
            buf.cursor.row += 1
            if buf.cursor.row >= rows { Self.scrollUp(in: &buf, cols: cols, rows: rows) }
        }
        buf.grid[buf.cursor.row * cols + buf.cursor.col] = Cell(character: char, style: pen)
        buf.cursor.col += 1
        return true
    }
}

private func handleC0(_ control: C0Control) -> Bool {
    switch control {
    case .nul, .bell, .shiftOut, .shiftIn, .delete:
        return false
    case .backspace:
        return mutateActive { buf in
            guard buf.cursor.col > 0 else { return false }
            buf.cursor.col -= 1
            return true
        }
    case .horizontalTab:
        return mutateActive { buf in
            let next = min(cols - 1, ((buf.cursor.col / 8) + 1) * 8)
            guard next != buf.cursor.col else { return false }
            buf.cursor.col = next
            return true
        }
    case .lineFeed, .verticalTab, .formFeed:
        return mutateActive { buf in
            buf.cursor.col = 0
            buf.cursor.row += 1
            if buf.cursor.row >= rows { Self.scrollUp(in: &buf, cols: cols, rows: rows) }
            return true
        }
    case .carriageReturn:
        return mutateActive { buf in
            guard buf.cursor.col != 0 else { return false }
            buf.cursor.col = 0
            return true
        }
    }
}

private func clampCursor(in buf: inout Buffer) {
    buf.cursor.row = max(0, min(rows - 1, buf.cursor.row))
    buf.cursor.col = max(0, min(cols - 1, buf.cursor.col))
}

private func handleCSI(_ cmd: CSICommand) -> Bool {
    switch cmd {
    case .cursorUp(let n):
        return mutateActive { buf in
            buf.cursor.row -= max(1, n)
            clampCursor(in: &buf)
            return true
        }
    case .cursorDown(let n):
        return mutateActive { buf in
            buf.cursor.row += max(1, n)
            clampCursor(in: &buf)
            return true
        }
    case .cursorForward(let n):
        return mutateActive { buf in
            buf.cursor.col += max(1, n)
            clampCursor(in: &buf)
            return true
        }
    case .cursorBack(let n):
        return mutateActive { buf in
            buf.cursor.col -= max(1, n)
            clampCursor(in: &buf)
            return true
        }
    case .cursorPosition(let r, let c):
        return mutateActive { buf in
            buf.cursor.row = r
            buf.cursor.col = c
            clampCursor(in: &buf)
            return true
        }
    case .cursorHorizontalAbsolute(let n):
        return mutateActive { buf in
            buf.cursor.col = max(0, n - 1)
            clampCursor(in: &buf)
            return true
        }
    case .verticalPositionAbsolute(let n):
        return mutateActive { buf in
            buf.cursor.row = max(0, n - 1)
            clampCursor(in: &buf)
            return true
        }
    case .saveCursor:
        return mutateActive { buf in
            buf.savedCursor = buf.cursor
            return false   // pure cursor state — no visible change.
        }
    case .restoreCursor:
        return mutateActive { buf in
            guard let saved = buf.savedCursor else { return false }
            buf.cursor = saved
            clampCursor(in: &buf)
            return true
        }
    case .eraseInDisplay(let region):
        eraseInDisplay(region)
        return true
    case .eraseInLine(let region):
        eraseInLine(region)
        return true
    case .sgr(let attrs):
        applySGR(attrs)
        return false   // pen change — grid unchanged.
    case .setMode, .setScrollRegion, .unknown:
        return false   // T3, T4, T5 wire these.
    }
}

private func eraseInDisplay(_ region: EraseRegion) {
    mutateActive { buf in
        let idx = buf.cursor.row * cols + buf.cursor.col
        switch region {
        case .toEnd:
            for i in idx..<(rows * cols) { buf.grid[i] = .empty }
        case .toBegin:
            for i in 0...idx where i < rows * cols { buf.grid[i] = .empty }
        case .all, .scrollback:
            // .scrollback is handled in T6 once history exists; for now treat as .all.
            for i in 0..<(rows * cols) { buf.grid[i] = .empty }
        }
    }
}

private func eraseInLine(_ region: EraseRegion) {
    mutateActive { buf in
        let rowStart = buf.cursor.row * cols
        switch region {
        case .toEnd:
            for c in buf.cursor.col..<cols { buf.grid[rowStart + c] = .empty }
        case .toBegin:
            for c in 0...buf.cursor.col where c < cols { buf.grid[rowStart + c] = .empty }
        case .all, .scrollback:
            for c in 0..<cols { buf.grid[rowStart + c] = .empty }
        }
    }
}

/// Shifts all rows in `buf` up by one, discarding the top row and clearing the
/// last row. Cursor row clamped to `rows - 1`. Static so handlers can call it
/// inside a `mutateActive` closure without re-entering the helper.
///
/// T6 will add a history-feed path: when `buf` is the main buffer, the evicted
/// row gets pushed to scrollback. For T2 we just discard, matching Phase 1.
private static func scrollUp(in buf: inout Buffer, cols: Int, rows: Int) {
    let stride = cols
    for dstRow in 0 ..< (rows - 1) {
        let srcStart = (dstRow + 1) * stride
        let dstStart = dstRow * stride
        for col in 0 ..< stride {
            buf.grid[dstStart + col] = buf.grid[srcStart + col]
        }
    }
    let lastRowStart = (rows - 1) * stride
    for col in 0 ..< stride {
        buf.grid[lastRowStart + col] = .empty
    }
    buf.cursor.row = rows - 1
}
```

- [ ] **Step 7: Update `publishSnapshot`, `snapshot`, `restore`, `snapshotCursor`, `applyAndCurrentTitle` to read from active buffer**

Replace the existing `publishSnapshot`, `snapshot`, `restore`, and `snapshotCursor` implementations with:

```swift
private func publishSnapshot() {
    let snap = ScreenSnapshot(
        activeCells: active.grid,
        cols: cols,
        rows: rows,
        cursor: snapshotCursor(),
        cursorVisible: true,         // T3 reads modes.cursorVisible
        activeBuffer: activeKind,
        windowTitle: windowTitle,
        version: version
    )
    _latestSnapshot.withLock { $0 = SnapshotBox(snap) }
}

public func snapshot() -> ScreenSnapshot {
    ScreenSnapshot(
        activeCells: active.grid,
        cols: cols,
        rows: rows,
        cursor: snapshotCursor(),
        cursorVisible: true,
        activeBuffer: activeKind,
        windowTitle: windowTitle,
        version: version
    )
}

public func restore(from snapshot: ScreenSnapshot) {
    precondition(
        snapshot.cols == cols && snapshot.rows == rows,
        "Cannot restore from snapshot with dimensions \(snapshot.cols)x\(snapshot.rows) "
        + "into model with dimensions \(cols)x\(rows)"
    )
    precondition(
        snapshot.activeCells.count == snapshot.rows * snapshot.cols,
        "Snapshot has \(snapshot.activeCells.count) cells; expected \(snapshot.rows * snapshot.cols)"
    )
    // Restore into the buffer indicated by the snapshot. The other buffer is
    // reset to a fresh empty state — when the daemon hasn't recorded alt
    // contents (Phase 2 doesn't carry alt grids over the wire), starting alt
    // from blank is the only safe default.
    let restored = Buffer(rows: rows, cols: cols)
    var seeded = restored
    seeded.grid = snapshot.activeCells
    seeded.cursor = snapshot.cursor
    switch snapshot.activeBuffer {
    case .main:
        self.main = seeded
        self.alt = Buffer(rows: rows, cols: cols)
    case .alt:
        self.alt = seeded
        self.main = Buffer(rows: rows, cols: cols)
    }
    self.activeKind = snapshot.activeBuffer
    self.windowTitle = snapshot.windowTitle
    self.version = snapshot.version
    publishSnapshot()
}

private func snapshotCursor() -> Cursor {
    let c = active.cursor
    guard c.col >= cols else { return c }
    let nextRow = c.row + 1
    if nextRow >= rows { return Cursor(row: rows - 1, col: 0) }
    return Cursor(row: nextRow, col: 0)
}
```

`buildAttachPayload()` and `applyAndCurrentTitle()` keep their Phase 1 bodies — they call `latestSnapshot()` / `apply` / `windowTitle`, all of which still work.

- [ ] **Step 8: Run all existing TermCore tests — expect pass (no behavior change)**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test`

Expected: every previously-passing test still passes. Phase 1 has full coverage of cursor motion, erase, SGR, snapshot, attach payload — those exercise every handler that just got rewritten.

If any test fails, the most likely cause is a `&` / `=` typo in one of the rewritten handlers (e.g., assigning instead of mutating buf.cursor.row). Fix and re-run.

- [ ] **Step 9: Commit**

```bash
git add TermCore/ScreenModel.swift
git commit -m "model: dual-buffer ScreenModel refactor (Phase 2 T2)

Per-buffer state (grid, cursor, savedCursor, scrollRegion) moves into
a nested Buffer value-type. ScreenModel now owns main + alt buffers
plus activeKind: BufferKind. All handlers route through a
mutateActive { buf in ... } helper that yields an inout to whichever
buffer is currently active.

No external behavior change: activeKind stays .main, alt is allocated
but never written. publishSnapshot reads from the active buffer's
grid / cursor and reports activeBuffer = activeKind. restore(from:)
seeds the snapshot's activeBuffer (main or alt) and resets the other
to fresh empty state — alt grids do not cross the XPC wire in Phase 2.

scrollUp becomes a static helper taking inout Buffer + cols + rows so
handlers can invoke it from inside mutateActive without re-entering.

Storage shape now matches spec §4 — T3 (modes), T4 (alt screen), T5
(DECSTBM), T6 (scrollback) plug in as localized changes."
```

---

## Task 3: ScreenModel — `TerminalModes` + DECAWM / DECTCEM / DECCKM / bracketed paste, snapshot extension

**Spec reference:** §3 (`DECPrivateMode` cases), §4 ("Terminal-wide state — persists across buffer swap": `pen`, `modes`, `windowTitle`).

**Goal:** Introduce a `TerminalModes` value type holding the four bool flags Phase 2 needs at the model layer (autoWrap, cursorVisible, cursorKeyApplication, bracketedPaste) plus a `bellCount: UInt64` on the snapshot for visual/audible bell. Implement `handleCSI(.setMode(...))` for these four modes and ring the bell from `handleC0(.bell)`. Extend `ScreenSnapshot` with the new fields; alt-screen modes (1047 / 1048 / 1049 / 47) are still ignored — those land in T4.

`KeyEncoder` (T7) and the paste path (T8) read the new snapshot fields via `latestSnapshot()` — no actor hop on the input/render hot path.

**Files:**
- Create: `TermCore/TerminalModes.swift`
- Modify: `TermCore/ScreenSnapshot.swift` (add `cursorKeyApplication`, `bracketedPaste`, `bellCount` with backward-compat decoders)
- Modify: `TermCore/ScreenModel.swift` (modes field, bellCount, setMode handling, autoWrap-aware handlePrintable, publishSnapshot reads modes + bellCount)
- Modify: `TermCoreTests/ScreenModelTests.swift` (mode toggles + autoWrap behavior + bell count)
- Modify: `TermCoreTests/CodableTests.swift` (snapshot Codable round-trip with new fields; back-compat decode without them)

### Steps

- [ ] **Step 1: Create `TerminalModes`**

Create `TermCore/TerminalModes.swift`:

```swift
//
//  TerminalModes.swift
//  TermCore
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

/// Terminal-wide mode flags that persist across alt-screen buffer swaps.
///
/// `autoWrap` and `cursorVisible` default `true` (the standard VT power-on state).
/// `cursorKeyApplication` and `bracketedPaste` default `false`.
@frozen public struct TerminalModes: Sendable, Equatable, Codable {
    public var autoWrap: Bool
    public var cursorVisible: Bool
    public var cursorKeyApplication: Bool
    public var bracketedPaste: Bool

    public init(autoWrap: Bool = true,
                cursorVisible: Bool = true,
                cursorKeyApplication: Bool = false,
                bracketedPaste: Bool = false) {
        self.autoWrap = autoWrap
        self.cursorVisible = cursorVisible
        self.cursorKeyApplication = cursorKeyApplication
        self.bracketedPaste = bracketedPaste
    }

    public static let `default` = TerminalModes()
}
```

- [ ] **Step 2: Extend `ScreenSnapshot` with the four new fields (with backward-compat decoders)**

In `TermCore/ScreenSnapshot.swift`, modify the struct:

1. Add four stored properties in this order, after `windowTitle`:

```swift
public let cursorKeyApplication: Bool
public let bracketedPaste: Bool
public let bellCount: UInt64
public let autoWrap: Bool
```

`autoWrap` is on the snapshot so the client mirror's first frame after cold attach matches the daemon's actual DECAWM state — without it the client would default to autoWrap=true and render writes-past-margin differently from the daemon until the next DECAWM byte streamed through (could be never for paused apps).

2. Update the initializer:

```swift
public init(activeCells: ContiguousArray<Cell>,
            cols: Int,
            rows: Int,
            cursor: Cursor,
            cursorVisible: Bool = true,
            activeBuffer: BufferKind = .main,
            windowTitle: String? = nil,
            cursorKeyApplication: Bool = false,
            bracketedPaste: Bool = false,
            bellCount: UInt64 = 0,
            autoWrap: Bool = true,
            version: UInt64) {
    self.activeCells = activeCells
    self.cols = cols
    self.rows = rows
    self.cursor = cursor
    self.cursorVisible = cursorVisible
    self.activeBuffer = activeBuffer
    self.windowTitle = windowTitle
    self.cursorKeyApplication = cursorKeyApplication
    self.bracketedPaste = bracketedPaste
    self.bellCount = bellCount
    self.autoWrap = autoWrap
    self.version = version
}
```

3. Update `CodingKeys` to include the new keys:

```swift
private enum CodingKeys: String, CodingKey {
    case activeCells, cols, rows, cursor, cursorVisible, activeBuffer,
         windowTitle, cursorKeyApplication, bracketedPaste, bellCount,
         autoWrap, version
}
```

4. Update `init(from:)` — keep the dimension-validation block as-is, then add the four new field decodes with `decodeIfPresent ?? default`:

Replace the trailing portion of `init(from:)` (everything after the `cursor` decode) with:

```swift
self.cursor = try container.decode(Cursor.self, forKey: .cursor)
self.cursorVisible = try container.decode(Bool.self, forKey: .cursorVisible)
self.activeBuffer = try container.decode(BufferKind.self, forKey: .activeBuffer)
self.windowTitle = try container.decodeIfPresent(String.self, forKey: .windowTitle)
self.cursorKeyApplication = try container.decodeIfPresent(Bool.self, forKey: .cursorKeyApplication) ?? false
self.bracketedPaste = try container.decodeIfPresent(Bool.self, forKey: .bracketedPaste) ?? false
self.bellCount = try container.decodeIfPresent(UInt64.self, forKey: .bellCount) ?? 0
self.autoWrap = try container.decodeIfPresent(Bool.self, forKey: .autoWrap) ?? true
self.version = try container.decode(UInt64.self, forKey: .version)
```

The `decodeIfPresent` defaults give us backward compat with any in-flight Phase 1 messages and let tests construct snapshots without specifying every new field.

- [ ] **Step 3: Add `modes`, `bellCount` fields to ScreenModel + plumb into snapshot construction**

In `TermCore/ScreenModel.swift`:

1. Near the existing `pen`, `windowTitle`, `iconName` declarations, add:

```swift
/// DEC private modes (DECAWM / DECTCEM / DECCKM / bracketed paste).
/// Persists across buffer swap (T4); set via `handleCSI(.setMode(...))`.
private var modes: TerminalModes = .default

/// Monotonic count of `BEL` (0x07) events received. Renderer side (T9)
/// observes deltas and triggers `NSSound.beep()` on the MainActor.
private var bellCount: UInt64 = 0
```

2. Update `publishSnapshot` to include the new fields:

```swift
private func publishSnapshot() {
    let snap = ScreenSnapshot(
        activeCells: active.grid,
        cols: cols,
        rows: rows,
        cursor: snapshotCursor(),
        cursorVisible: modes.cursorVisible,
        activeBuffer: activeKind,
        windowTitle: windowTitle,
        cursorKeyApplication: modes.cursorKeyApplication,
        bracketedPaste: modes.bracketedPaste,
        bellCount: bellCount,
        autoWrap: modes.autoWrap,
        version: version
    )
    _latestSnapshot.withLock { $0 = SnapshotBox(snap) }
}
```

3. Apply the same field set to the actor-isolated `snapshot()` method (mirror change).

4. Update the initializer's `initial` snapshot construction to include the new fields with their defaults — `cursorKeyApplication: false, bracketedPaste: false, bellCount: 0, autoWrap: true`.

- [ ] **Step 4: Wire `handleC0(.bell)` to bump `bellCount`**

Replace the `.nul, .bell, .shiftOut, .shiftIn, .delete` arm in `handleC0` with:

```swift
case .nul, .shiftOut, .shiftIn, .delete:
    return false
case .bell:
    bellCount &+= 1
    return true   // snapshot includes bellCount; renderer observes delta.
```

- [ ] **Step 5: Implement `handleSetMode(_:enabled:)` for DECAWM / DECTCEM / DECCKM / bracketed paste**

In `handleCSI`, change the `case .setMode, .setScrollRegion, .unknown:` arm so `.setMode` dispatches to a new helper. The other two stay as no-ops for now (T4, T5):

```swift
case .setMode(let mode, let enabled):
    return handleSetMode(mode, enabled: enabled)
case .setScrollRegion, .unknown:
    return false   // T5 wires .setScrollRegion.
```

Add the helper at the end of the actor body:

```swift
/// Apply a `CSI ? Pm h/l` mode change. Returns `true` when the change is
/// snapshot-visible (cursorVisible toggle, cursorKeyApplication toggle,
/// bracketedPaste toggle); returns `false` when the change is invisible
/// (autoWrap toggle — affects future handlePrintable behavior but not the
/// current snapshot).
///
/// Alt-screen modes (47 / 1047 / 1048 / 1049) are dispatched to `handleAltScreen`
/// in T4; in this task they fall through to `false` (no-op).
private func handleSetMode(_ mode: DECPrivateMode, enabled: Bool) -> Bool {
    switch mode {
    case .autoWrap:
        guard modes.autoWrap != enabled else { return false }
        modes.autoWrap = enabled
        return true   // snapshot.autoWrap reflects the change → bump version.
    case .cursorVisible:
        guard modes.cursorVisible != enabled else { return false }
        modes.cursorVisible = enabled
        return true
    case .cursorKeyApplication:
        guard modes.cursorKeyApplication != enabled else { return false }
        modes.cursorKeyApplication = enabled
        return true
    case .bracketedPaste:
        guard modes.bracketedPaste != enabled else { return false }
        modes.bracketedPaste = enabled
        return true
    case .alternateScreen47, .alternateScreen1047,
         .alternateScreen1049, .saveCursor1048:
        // T4 wires these.
        return false
    case .unknown:
        return false
    }
}
```

- [ ] **Step 6: Make `handlePrintable` honor `modes.autoWrap`**

Replace `handlePrintable` (added in T2) with:

```swift
private func handlePrintable(_ char: Character) -> Bool {
    let pen = self.pen
    let autoWrap = modes.autoWrap
    return mutateActive { buf in
        if buf.cursor.col >= cols {
            if autoWrap {
                buf.cursor.col = 0
                buf.cursor.row += 1
                if buf.cursor.row >= rows { Self.scrollUp(in: &buf, cols: cols, rows: rows) }
            } else {
                // DECAWM off: writes overwrite the last column without wrapping.
                buf.cursor.col = cols - 1
            }
        }
        buf.grid[buf.cursor.row * cols + buf.cursor.col] = Cell(character: char, style: pen)
        buf.cursor.col += 1
        return true
    }
}
```

- [ ] **Step 7: Update `restore(from:)` to seed mode flags + bellCount from the snapshot**

In `restore(from snapshot:)`, after `self.windowTitle = snapshot.windowTitle`, add:

```swift
self.modes = TerminalModes(
    autoWrap: snapshot.autoWrap,
    cursorVisible: snapshot.cursorVisible,
    cursorKeyApplication: snapshot.cursorKeyApplication,
    bracketedPaste: snapshot.bracketedPaste
)
self.bellCount = snapshot.bellCount
```

(All four mode flags now ride on the snapshot — `autoWrap` was added in Step 2 specifically so the client mirror's first frame matches the daemon's actual DECAWM state.)

- [ ] **Step 8: Write failing tests for mode behavior + snapshot fields + bell**

Append to `TermCoreTests/ScreenModelTests.swift`:

```swift
// MARK: - DEC private modes (Phase 2 T3)

@Test("DECAWM disable: writing past last column overwrites the last cell")
func test_decawm_off_overwrites_last_column() async {
    let model = ScreenModel(cols: 5, rows: 3)
    // Disable autoWrap.
    await model.apply([.csi(.setMode(.autoWrap, enabled: false))])
    // Fill the row past its end.
    let chars: [TerminalEvent] = "abcdefg".map { .printable($0) }
    await model.apply(chars)
    let snap = model.latestSnapshot()
    // Row 0: "abcdg" — the first 4 cells hold abcd; the last cell holds the
    // most-recently-written byte (g) because each subsequent write overwrites.
    let row0: String = (0..<5).map { String(snap[0, $0].character) }.joined()
    #expect(row0 == "abcdg")
    // Cursor stayed on row 0; no wrap occurred.
    #expect(snap.cursor.row == 0)
}

@Test("DECTCEM disable: snapshot.cursorVisible reflects the change")
func test_dectcem_off() async {
    let model = ScreenModel(cols: 80, rows: 24)
    await model.apply([.csi(.setMode(.cursorVisible, enabled: false))])
    let snap = model.latestSnapshot()
    #expect(snap.cursorVisible == false)
}

@Test("DECCKM enable: snapshot.cursorKeyApplication = true")
func test_decckm_on() async {
    let model = ScreenModel(cols: 80, rows: 24)
    await model.apply([.csi(.setMode(.cursorKeyApplication, enabled: true))])
    #expect(model.latestSnapshot().cursorKeyApplication == true)
}

@Test("Bracketed paste enable: snapshot.bracketedPaste = true")
func test_bracketed_paste_on() async {
    let model = ScreenModel(cols: 80, rows: 24)
    await model.apply([.csi(.setMode(.bracketedPaste, enabled: true))])
    #expect(model.latestSnapshot().bracketedPaste == true)
}

@Test("Mode toggle to same value does not bump version")
func test_mode_toggle_idempotent() async {
    let model = ScreenModel(cols: 80, rows: 24)
    await model.apply([.csi(.setMode(.cursorKeyApplication, enabled: true))])
    let v1 = model.latestSnapshot().version
    await model.apply([.csi(.setMode(.cursorKeyApplication, enabled: true))])
    let v2 = model.latestSnapshot().version
    #expect(v1 == v2, "Idempotent mode set should not bump version")
}

// MARK: - Bell (Phase 2 T3)

@Test("BEL increments bellCount and bumps version")
func test_bell_increments_count() async {
    let model = ScreenModel(cols: 80, rows: 24)
    let v0 = model.latestSnapshot().version
    let b0 = model.latestSnapshot().bellCount
    await model.apply([.c0(.bell)])
    let snap = model.latestSnapshot()
    #expect(snap.bellCount == b0 + 1)
    #expect(snap.version == v0 + 1)
}

@Test("Three BELs in one batch increment bellCount by 3")
func test_bell_batch_count() async {
    let model = ScreenModel(cols: 80, rows: 24)
    await model.apply([.c0(.bell), .c0(.bell), .c0(.bell)])
    #expect(model.latestSnapshot().bellCount == 3)
}

// MARK: - Restore preserves modes + bellCount

@Test("restore(from:) re-seeds cursorKeyApplication, bracketedPaste, bellCount")
func test_restore_preserves_modes_and_bell() async {
    let original = ScreenModel(cols: 80, rows: 24)
    await original.apply([
        .csi(.setMode(.cursorKeyApplication, enabled: true)),
        .csi(.setMode(.bracketedPaste, enabled: true)),
        .c0(.bell), .c0(.bell)
    ])
    let snap = original.latestSnapshot()
    let restored = ScreenModel(cols: 80, rows: 24)
    await restored.restore(from: snap)
    let restoredSnap = restored.latestSnapshot()
    #expect(restoredSnap.cursorKeyApplication == true)
    #expect(restoredSnap.bracketedPaste == true)
    #expect(restoredSnap.bellCount == 2)
}
```

- [ ] **Step 9: Append a back-compat decode test for `ScreenSnapshot`**

Append to `TermCoreTests/CodableTests.swift`:

```swift
@Test("ScreenSnapshot decodes a Phase 1-shaped JSON payload (missing new fields)")
func test_snapshot_decodes_phase1_payload() throws {
    // A minimal Phase 1-shaped snapshot — no cursorKeyApplication / bracketedPaste / bellCount / autoWrap.
    let json = """
    {
        "activeCells": [],
        "cols": 0,
        "rows": 0,
        "cursor": {"row": 0, "col": 0},
        "cursorVisible": true,
        "activeBuffer": "main",
        "version": 0
    }
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(ScreenSnapshot.self, from: json)
    #expect(decoded.cursorKeyApplication == false)
    #expect(decoded.bracketedPaste == false)
    #expect(decoded.bellCount == 0)
    #expect(decoded.autoWrap == true,
            "autoWrap defaults to true to match VT power-on state")
}

@Test("ScreenSnapshot Codable round-trip preserves all Phase 2 fields")
func test_snapshot_roundtrip_phase2_fields() throws {
    let original = ScreenSnapshot(
        activeCells: ContiguousArray(repeating: .empty, count: 6),
        cols: 3, rows: 2,
        cursor: Cursor(row: 1, col: 2),
        cursorVisible: false,
        activeBuffer: .alt,
        windowTitle: "vim",
        cursorKeyApplication: true,
        bracketedPaste: true,
        bellCount: 42,
        autoWrap: false,
        version: 7
    )
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ScreenSnapshot.self, from: encoded)
    #expect(decoded == original)
}
```

- [ ] **Step 10: Run all TermCore tests — expect pass**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test`

Expected: all Phase 1 tests still pass; all 9 new tests pass.

- [ ] **Step 11: Commit**

```bash
git add TermCore/TerminalModes.swift TermCore/ScreenSnapshot.swift TermCore/ScreenModel.swift \
        TermCoreTests/ScreenModelTests.swift TermCoreTests/CodableTests.swift
git commit -m "model: TerminalModes + DECAWM/DECTCEM/DECCKM/bracketed paste + bell (Phase 2 T3)

New TermCore/TerminalModes.swift holds the four Phase 2 mode flags:
autoWrap (default true), cursorVisible (default true),
cursorKeyApplication (default false), bracketedPaste (default false).

ScreenSnapshot grows four fields: cursorKeyApplication, bracketedPaste,
bellCount: UInt64, autoWrap. All four use decodeIfPresent ?? default
for back-compat with Phase 1-shaped payloads. autoWrap on the snapshot
prevents cold-attach client/daemon divergence — without it, the client
mirror would default to autoWrap=true and render writes-past-margin
differently from a daemon with DECAWM disabled until the next DECAWM
byte streamed through (could be never for paused apps).

ScreenModel.handleSetMode wires the four user-facing modes:
- DECAWM toggle → handlePrintable overwrites the last column without
  wrapping; snapshot.autoWrap mirrors and bumps version
- DECTCEM disable → snapshot.cursorVisible = false
- DECCKM toggle → snapshot.cursorKeyApplication mirrors (T7 reads it
  from KeyEncoder via latestSnapshot())
- Bracketed paste toggle → snapshot.bracketedPaste mirrors (T8 reads it
  from the paste handler)

handleC0(.bell) increments bellCount and bumps version. Snapshot
publishes the count; T9 will observe deltas on MainActor and call
NSSound.beep() (rate-limited).

Alt-screen modes (47 / 1047 / 1048 / 1049) still no-op — T4 wires those.
DECSTBM (.setScrollRegion) still no-op — T5 wires that.

restore(from:) re-seeds modes.autoWrap / cursorVisible /
cursorKeyApplication / bracketedPaste / bellCount from the snapshot."
```

---

## Task 4: ScreenModel — alt-screen modes 1049 / 1047 / 47 + saveCursor 1048

**Spec reference:** §4 ("Alt-screen semantics"): modes 1049 / 1047 / 47 / 1048; pen and modes persist across swap; history untouched by alt activity.

**Goal:** Implement the four alt-screen-related DEC private modes. `mode 1049 enter` saves the main cursor, switches `activeKind` to `.alt`, clears the alt grid, moves alt cursor to origin. `mode 1049 exit` clears alt, switches back to main, restores the saved cursor. `1047` is alt-with-clear, `47` is legacy alt-no-save, `1048` saves cursor only (no buffer switch). After this task vim / less / htop work.

**Files:**
- Modify: `TermCore/ScreenModel.swift` (handleAltScreen helper, hook from handleSetMode)
- Modify: `TermCoreTests/ScreenModelTests.swift` (vim-style alt-screen transition tests)
- Modify: `TermCoreTests/TerminalIntegrationTests.swift` (extend `vimStartupSequence` test to assert state lands in alt buffer)

### Steps

- [ ] **Step 1: Write failing tests for alt-screen behavior**

Append to `TermCoreTests/ScreenModelTests.swift`:

```swift
// MARK: - Alt-screen modes (Phase 2 T4)

@Test("Mode 1049 enter saves main cursor, switches to alt (cleared), pen persists")
func test_alt_screen_1049_enter() async {
    let model = ScreenModel(cols: 5, rows: 3)
    // Write some main-buffer content; move cursor to (1, 2).
    let main: [TerminalEvent] = [
        .printable("a"), .printable("b"), .printable("c"),
        .c0(.lineFeed),
        .printable("d"), .printable("e"),
    ]
    await model.apply(main)
    // Set a non-default pen so we can verify it persists across swap.
    await model.apply([.csi(.sgr([.bold]))])
    // Enter alt screen.
    await model.apply([.csi(.setMode(.alternateScreen1049, enabled: true))])
    let snap = model.latestSnapshot()
    #expect(snap.activeBuffer == .alt)
    #expect(snap.cursor == Cursor(row: 0, col: 0))
    // Alt grid is cleared.
    for r in 0..<3 {
        for c in 0..<5 {
            #expect(snap[r, c].character == " ")
        }
    }
    // Pen persistence — write a char and verify it has bold.
    await model.apply([.printable("x")])
    let after = model.latestSnapshot()
    #expect(after[0, 0].character == "x")
    #expect(after[0, 0].style.attributes.contains(.bold))
}

@Test("Mode 1049 exit returns to main with cursor restored, alt cleared")
func test_alt_screen_1049_exit_restores_main() async {
    let model = ScreenModel(cols: 5, rows: 3)
    await model.apply([
        .printable("a"), .printable("b"),
        .c0(.lineFeed),
    ])
    // Cursor is now at (1, 0). Enter alt.
    await model.apply([.csi(.setMode(.alternateScreen1049, enabled: true))])
    // Write to alt.
    await model.apply([.printable("z")])
    // Exit alt.
    await model.apply([.csi(.setMode(.alternateScreen1049, enabled: false))])
    let snap = model.latestSnapshot()
    #expect(snap.activeBuffer == .main)
    // Main content is intact.
    #expect(snap[0, 0].character == "a")
    #expect(snap[0, 1].character == "b")
    // Cursor restored to where main was when 1049-enter happened.
    #expect(snap.cursor == Cursor(row: 1, col: 0))
    // Re-enter alt and verify it's cleared (1049 enter clears every time).
    await model.apply([.csi(.setMode(.alternateScreen1049, enabled: true))])
    let after = model.latestSnapshot()
    for r in 0..<3 {
        for c in 0..<5 {
            #expect(after[r, c].character == " ")
        }
    }
}

@Test("Mode 1047 enter switches + clears alt; exit clears alt + switches back; alt cursor persists across re-entry")
func test_alt_screen_1047_cursor_persists_across_re_entry() async {
    let model = ScreenModel(cols: 4, rows: 2)
    await model.apply([
        .printable("a"), .printable("b"),
        .c0(.lineFeed),
        .printable("c"),
    ])
    // Cursor at (1, 1) on main.
    await model.apply([.csi(.setMode(.alternateScreen1047, enabled: true))])
    let snap = model.latestSnapshot()
    #expect(snap.activeBuffer == .alt)
    // Move alt cursor away from origin so we can verify it persists.
    await model.apply([
        .csi(.cursorPosition(row: 1, col: 3)),
        .printable("Z"),
    ])
    // Cursor on alt is now (1, 3) just past 'Z'.
    await model.apply([.csi(.setMode(.alternateScreen1047, enabled: false))])
    let exited = model.latestSnapshot()
    #expect(exited.activeBuffer == .main)
    // Main cursor was wherever it was when we entered alt — 1047 doesn't save/restore.
    // Re-enter alt: grid is cleared, but cursor persisted from last visit.
    await model.apply([.csi(.setMode(.alternateScreen1047, enabled: true))])
    let reentered = model.latestSnapshot()
    #expect(reentered.activeBuffer == .alt)
    // Grid is cleared (xterm 1047 clears on enter).
    for r in 0..<2 {
        for c in 0..<4 {
            #expect(reentered[r, c].character == " ", "Alt grid is cleared on re-entry")
        }
    }
    // Cursor persisted from last alt visit — distinguishes "1047 leaves alt
    // cursor alone" from "alt was freshly allocated at origin". The previous
    // alt visit left cursor at (1, 3) just past 'Z'.
    #expect(reentered.cursor.row == 1)
    #expect(reentered.cursor.col == 3)
}

@Test("Mode 47 toggles buffer without clear or cursor save (legacy)")
func test_alt_screen_47_legacy() async {
    let model = ScreenModel(cols: 3, rows: 2)
    await model.apply([.printable("x")])
    await model.apply([.csi(.setMode(.alternateScreen47, enabled: true))])
    let snap = model.latestSnapshot()
    #expect(snap.activeBuffer == .alt)
    // Mode 47 does NOT clear alt — but our alt was empty anyway.
    // Write to alt, swap out, verify alt persists across swap.
    await model.apply([.printable("y")])
    await model.apply([.csi(.setMode(.alternateScreen47, enabled: false))])
    #expect(model.latestSnapshot().activeBuffer == .main)
    // Re-enter alt — y should still be there.
    await model.apply([.csi(.setMode(.alternateScreen47, enabled: true))])
    #expect(model.latestSnapshot()[0, 0].character == "y")
}

@Test("Mode 1048 saves cursor without buffer switch")
func test_save_cursor_1048() async {
    let model = ScreenModel(cols: 5, rows: 3)
    await model.apply([
        .printable("a"), .printable("b"), .printable("c"),
    ])
    // Cursor at (0, 3). Save it via 1048.
    await model.apply([.csi(.setMode(.saveCursor1048, enabled: true))])
    // Move cursor; verify still on main.
    await model.apply([.csi(.cursorPosition(row: 2, col: 4))])
    #expect(model.latestSnapshot().activeBuffer == .main)
    #expect(model.latestSnapshot().cursor == Cursor(row: 2, col: 4))
    // Restore via 1048 disable.
    await model.apply([.csi(.setMode(.saveCursor1048, enabled: false))])
    #expect(model.latestSnapshot().cursor == Cursor(row: 0, col: 3))
}

@Test("Mode 1048 save/restore is per-buffer (alt and main keep independent slots)")
func test_save_cursor_1048_per_buffer() async {
    let model = ScreenModel(cols: 5, rows: 3)
    // On main: move to (0, 2) and 1048-save.
    await model.apply([
        .csi(.cursorPosition(row: 0, col: 2)),
        .csi(.setMode(.saveCursor1048, enabled: true)),
    ])
    // Switch to alt (mode 1049 takes us to alt at origin).
    await model.apply([.csi(.setMode(.alternateScreen1049, enabled: true))])
    // On alt: move to (2, 4) and 1048-save.
    await model.apply([
        .csi(.cursorPosition(row: 2, col: 4)),
        .csi(.setMode(.saveCursor1048, enabled: true)),
    ])
    // Move cursor on alt elsewhere, then 1048-restore — must land at (2, 4),
    // alt's saved slot, NOT main's (0, 2).
    await model.apply([
        .csi(.cursorPosition(row: 1, col: 0)),
        .csi(.setMode(.saveCursor1048, enabled: false)),
    ])
    let altRestored = model.latestSnapshot()
    #expect(altRestored.activeBuffer == .alt)
    #expect(altRestored.cursor == Cursor(row: 2, col: 4),
            "1048 restore on alt uses alt.savedCursor, not main's")
    // Exit alt back to main; main's 1048 save is still in main.savedCursor.
    await model.apply([.csi(.setMode(.alternateScreen1049, enabled: false))])
    // Move main cursor elsewhere, then 1048-restore — must land at (0, 2),
    // main's saved slot.
    await model.apply([
        .csi(.cursorPosition(row: 1, col: 4)),
        .csi(.setMode(.saveCursor1048, enabled: false)),
    ])
    let mainRestored = model.latestSnapshot()
    #expect(mainRestored.activeBuffer == .main)
    #expect(mainRestored.cursor == Cursor(row: 0, col: 2),
            "1048 restore on main uses main.savedCursor, not alt's")
}

@Test("CSI s + writes + CSI u restores cursor (per active buffer)")
func test_save_restore_cursor_csi_s_u() async {
    let model = ScreenModel(cols: 5, rows: 3)
    await model.apply([.printable("a"), .printable("b")])
    // Cursor (0, 2). Save.
    await model.apply([.csi(.saveCursor)])
    await model.apply([
        .csi(.cursorPosition(row: 2, col: 4)),
        .printable("z"),                           // grid mutation → version bump
        .csi(.restoreCursor),
    ])
    let snap = model.latestSnapshot()
    #expect(snap.cursor == Cursor(row: 0, col: 2))
}

@Test("ESC 7 / ESC 8 (DECSC / DECRC) behave the same as CSI s / CSI u")
func test_esc_7_8_save_restore() async {
    let model = ScreenModel(cols: 5, rows: 3)
    var parser = TerminalParser()
    // Write 'a', save via ESC 7, move, write, restore via ESC 8.
    let bytes: [UInt8] = [
        0x61,                               // 'a'
        0x1B, 0x37,                          // ESC 7 — save
        0x1B, 0x5B, 0x33, 0x3B, 0x35, 0x48,  // CSI 3;5 H — move (1-indexed)
        0x7A,                                // 'z'
        0x1B, 0x38                           // ESC 8 — restore
    ]
    await model.apply(parser.parse(Data(bytes)))
    let snap = model.latestSnapshot()
    #expect(snap.cursor == Cursor(row: 0, col: 1))   // back to (0, col-after-'a')
}

@Test("Save/restore is per-buffer: alt and main keep separate saved cursors")
func test_save_restore_per_buffer() async {
    let model = ScreenModel(cols: 5, rows: 3)
    // Save main cursor at (0, 0) (origin).
    await model.apply([.csi(.saveCursor)])
    // Move main cursor.
    await model.apply([.csi(.cursorPosition(row: 1, col: 2))])
    // Enter alt — writes go to alt. Save alt cursor (origin).
    await model.apply([
        .csi(.setMode(.alternateScreen1049, enabled: true)),
        .csi(.saveCursor),
    ])
    // Move alt cursor.
    await model.apply([.csi(.cursorPosition(row: 2, col: 3))])
    // Restore alt cursor → back to (0, 0) on alt.
    await model.apply([.csi(.restoreCursor)])
    #expect(model.latestSnapshot().cursor == Cursor(row: 0, col: 0))
    #expect(model.latestSnapshot().activeBuffer == .alt)
    // Exit alt back to main — main cursor restored from 1049 save (which was
    // (1, 2) at the moment of 1049 enter).
    await model.apply([.csi(.setMode(.alternateScreen1049, enabled: false))])
    #expect(model.latestSnapshot().cursor == Cursor(row: 1, col: 2))
    // Restore main cursor (saved at origin).
    await model.apply([.csi(.restoreCursor)])
    #expect(model.latestSnapshot().cursor == Cursor(row: 0, col: 0))
}
```

- [ ] **Step 2: Run new tests — expect failures**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test -only-testing TermCoreTests/ScreenModelTests`

Expected: 8 new tests fail. T3 left alt-screen modes as no-ops; the per-buffer save/restore from T2 already works for `csi(.saveCursor)/.restoreCursor`, but multi-buffer integration tests will fail.

- [ ] **Step 3: Implement `handleAltScreen` in `ScreenModel`**

Add at the end of the actor body:

```swift
/// Handle the alt-screen-related DEC private modes (47 / 1047 / 1048 / 1049).
/// Returns `true` for any operation that changes visible state.
private func handleAltScreen(_ mode: DECPrivateMode, enabled: Bool) -> Bool {
    switch mode {
    case .saveCursor1048:
        // Save / restore main's saved cursor without buffer switch.
        // (Stored on the active buffer's `savedCursor` slot — when alt is active,
        // 1048 still works against alt; matches xterm.)
        if enabled {
            mutateActive { buf in buf.savedCursor = buf.cursor }
            return false   // no visible change
        } else {
            return mutateActive { buf in
                guard let saved = buf.savedCursor else { return false }
                buf.cursor = saved
                clampCursor(in: &buf)
                return true
            }
        }

    case .alternateScreen47:
        // Legacy: switch buffers without save/restore and without clearing.
        let target: BufferKind = enabled ? .alt : .main
        guard activeKind != target else { return false }
        activeKind = target
        return true

    case .alternateScreen1047:
        // Switch + clear-on-leave (per xterm). No cursor save/restore wrap;
        // alt's cursor persists across re-entry within a session.
        if enabled {
            guard activeKind != .alt else { return false }
            activeKind = .alt
            clearAltGrid()
            return true
        } else {
            guard activeKind == .alt else { return false }
            // Clear alt before switching so it's blank on next entry.
            // Do NOT touch alt.cursor — xterm leaves it where it is so
            // re-entry keeps the prior position even though grid was cleared.
            clearAltGrid()
            activeKind = .main
            return true
        }

    case .alternateScreen1049:
        // Save main cursor on enter; restore on exit. Always clears alt on enter.
        if enabled {
            guard activeKind != .alt else { return false }
            main.savedCursor = main.cursor
            activeKind = .alt
            clearAltGrid()
            alt.cursor = Cursor(row: 0, col: 0)
            return true
        } else {
            guard activeKind == .alt else { return false }
            // Clear alt grid; alt.cursor will be reset on the next 1049 enter
            // so we don't bother resetting it here.
            clearAltGrid()
            activeKind = .main
            if let saved = main.savedCursor {
                main.cursor = saved
                clampCursor(in: &main)
            }
            return true
        }

    default:
        return false   // Not an alt-screen mode.
    }
}

/// Clear the alt buffer grid in place. Cursor is left untouched (callers reset).
private func clearAltGrid() {
    let total = rows * cols
    for i in 0..<total { alt.grid[i] = .empty }
}
```

- [ ] **Step 4: Hook `handleAltScreen` into `handleSetMode`**

Replace the `case .alternateScreen47, .alternateScreen1047, .alternateScreen1049, .saveCursor1048:` arm in `handleSetMode` with:

```swift
case .alternateScreen47, .alternateScreen1047,
     .alternateScreen1049, .saveCursor1048:
    return handleAltScreen(mode, enabled: enabled)
```

- [ ] **Step 5: Extend the existing `vimStartupSequence` integration test**

Open `TermCoreTests/TerminalIntegrationTests.swift`, find the test that uses `vimStartupSequence`, and replace the body's snapshot assertion to assert alt-screen activation. Locate this:

```swift
let snap = model.latestSnapshot()
#expect(snap.cursor == Cursor(row: 0, col: 0))
```

Change to:

```swift
let snap = model.latestSnapshot()
#expect(snap.cursor == Cursor(row: 0, col: 0))
#expect(snap.activeBuffer == .alt, "vim startup should land in alt buffer (mode 1049)")
```

- [ ] **Step 6: Run all TermCore tests — expect pass**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test`

Expected: all tests green.

- [ ] **Step 7: Commit**

```bash
git add TermCore/ScreenModel.swift TermCoreTests/ScreenModelTests.swift TermCoreTests/TerminalIntegrationTests.swift
git commit -m "model: alt-screen modes 1049/1047/47 + saveCursor 1048 (Phase 2 T4)

handleAltScreen wires the four alt-screen-related DEC private modes:

- 1049 enter: save main cursor → switch to alt → clear alt → cursor origin
- 1049 exit:  clear alt → switch to main → restore main cursor
- 1047 enter: switch to alt → clear alt → cursor origin (no main-cursor save)
- 1047 exit:  clear alt → switch to main → cursor origin
- 47   enter/exit: bare buffer toggle (legacy; alt content persists)
- 1048 set:   save cursor on active buffer (no switch)
- 1048 reset: restore cursor on active buffer (no switch)

Pen and TerminalModes flags persist across buffer swap (no special
handling needed — they're on the actor, not the Buffer struct).

Save/restore via CSI s / CSI u (and ESC 7 / ESC 8 from T1) operates
on the active buffer's savedCursor slot — alt and main keep
independent saved-cursor positions.

vim/htop/less/tmux now feel native: alt-screen swap is clean,
return-to-shell preserves the original cursor position.

Scrollback (T6) is intentionally not yet wired — alt-screen activity
must not feed history. The current scrollUp helper just discards
top rows, which is correct for both buffers; T6 will add a
\"main-only\" history-feed branch."
```

---

## Task 5: ScreenModel — DECSTBM scroll region

**Spec reference:** §4 ("Scrollback integration": "Scroll-region-internal scrolls discard without feeding history.").

**Goal:** Implement `handleCSI(.setScrollRegion(top:bottom:))` per active buffer (the field is already on `Buffer` from T2). When DECSTBM is set, natural line-feeds at `region.bottom` scroll only the rows inside `[region.top, region.bottom]`. Cursor positioning (`CSI H` / `CUP` etc.) is **unaffected** by the region — that's correct VT behavior; the region only constrains where data scrolls. After this task, `less` / `vim` status lines work without smearing.

**Files:**
- Modify: `TermCore/ScreenModel.swift` (handleSetScrollRegion, region-aware scrollUp helpers, lineFeed/printable use them)
- Modify: `TermCoreTests/ScreenModelTests.swift` (region behavior tests)

### Steps

- [ ] **Step 1: Write failing tests for DECSTBM behavior**

Append to `TermCoreTests/ScreenModelTests.swift`:

```swift
// MARK: - DECSTBM scroll region (Phase 2 T5)

@Test("CSI 2;4 r sets scroll region rows 1..3 (0-indexed inclusive)")
func test_decstbm_set_region() async {
    let model = ScreenModel(cols: 4, rows: 6)
    // Fill rows with row numbers (0..5).
    for r in 0..<6 {
        await model.apply([
            .csi(.cursorPosition(row: r, col: 0)),
            .printable(Character(String(r)))
        ])
    }
    // CSI 2;4 r → top=1 bottom=3 after 1→0 shift.
    await model.apply([.csi(.setScrollRegion(top: 2, bottom: 4))])
    // Move cursor to last row of region (row 3) and emit LF — region scrolls.
    await model.apply([
        .csi(.cursorPosition(row: 3, col: 0)),
        .c0(.lineFeed),
    ])
    let snap = model.latestSnapshot()
    // Rows outside the region must be untouched.
    #expect(snap[0, 0].character == "0")
    #expect(snap[5, 0].character == "5")
    // Inside the region: row 1 was "1", scrolled out; rows 1/2 now hold what
    // was previously rows 2/3; row 3 is blank (newly cleared bottom).
    #expect(snap[1, 0].character == "2")
    #expect(snap[2, 0].character == "3")
    #expect(snap[3, 0].character == " ")
}

@Test("CSI r (no params) resets scroll region to full screen")
func test_decstbm_reset() async {
    let model = ScreenModel(cols: 3, rows: 4)
    await model.apply([.csi(.setScrollRegion(top: 2, bottom: 3))])
    await model.apply([.csi(.setScrollRegion(top: nil, bottom: nil))])
    // Fill row 0 then trigger full-screen scroll from the bottom.
    await model.apply([
        .printable("a"), .printable("b"), .printable("c"),
        .csi(.cursorPosition(row: 3, col: 0)),
        .c0(.lineFeed),
    ])
    // With region reset, the full screen scrolled — row 0 ("abc") evicted.
    let snap = model.latestSnapshot()
    #expect(snap[0, 0].character != "a", "Region reset should allow full-screen scroll")
}

@Test("Cursor positioning ignores scroll region (CSI H is free movement)")
func test_decstbm_cursor_position_unbounded() async {
    let model = ScreenModel(cols: 3, rows: 5)
    await model.apply([.csi(.setScrollRegion(top: 2, bottom: 4))])  // rows 1..3
    // CUP to (4, 2) — row 4 is OUTSIDE the region but still a valid screen row.
    await model.apply([.csi(.cursorPosition(row: 4, col: 2))])
    #expect(model.latestSnapshot().cursor == Cursor(row: 4, col: 2))
    // Equally valid above the region.
    await model.apply([.csi(.cursorPosition(row: 0, col: 0))])
    #expect(model.latestSnapshot().cursor == Cursor(row: 0, col: 0))
}

@Test("LF below the scroll region triggers full-screen scroll (xterm behavior)")
func test_decstbm_lf_below_region_does_full_screen_scroll() async {
    let model = ScreenModel(cols: 2, rows: 5)
    // Fill row 1 (will be inside region) so we can observe scroll motion.
    await model.apply([
        .csi(.cursorPosition(row: 1, col: 0)),
        .printable("X"),
    ])
    await model.apply([.csi(.setScrollRegion(top: 2, bottom: 4))])  // rows 1..3 (0-indexed)
    // Cursor at row 4 (BELOW region), then LF. Per xterm: full-screen
    // scroll happens; region-internal content rides along; top row evicts.
    await model.apply([
        .csi(.cursorPosition(row: 4, col: 0)),
        .c0(.lineFeed),
    ])
    let snap = model.latestSnapshot()
    // 'X' was at row 1 → after one full-screen scroll, it's at row 0.
    #expect(snap[0, 0].character == "X",
            "Row containing 'X' shifted up by one full-screen scroll")
    // Cursor stays clamped at last row.
    #expect(snap.cursor.row == 4)
}

@Test("Setting region with bottom < top is rejected (region stays unchanged)")
func test_decstbm_invalid_range() async {
    let model = ScreenModel(cols: 2, rows: 5)
    await model.apply([.csi(.setScrollRegion(top: 4, bottom: 2))])
    // Subsequent LF at the last row scrolls the full screen (region was rejected).
    await model.apply([
        .csi(.cursorPosition(row: 0, col: 0)),
        .printable("a"),
        .csi(.cursorPosition(row: 4, col: 0)),
        .c0(.lineFeed),
    ])
    // Row 0 'a' must have evicted (full-screen scroll happened).
    #expect(model.latestSnapshot()[0, 0].character != "a")
}
```

- [ ] **Step 2: Run new tests — expect failures**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test -only-testing TermCoreTests/ScreenModelTests`

Expected: 5 tests fail. Phase 1 + T2 don't honor `Buffer.scrollRegion`.

- [ ] **Step 3: Implement `handleSetScrollRegion` and a region-aware `scrollUp`**

In `ScreenModel`, replace the existing `case .setMode, ...` arm in `handleCSI` (last touched in T3) with:

```swift
case .setMode(let mode, let enabled):
    return handleSetMode(mode, enabled: enabled)
case .setScrollRegion(let top, let bottom):
    return handleSetScrollRegion(top: top, bottom: bottom)
case .unknown:
    return false
```

Add the helper at the end of the actor body:

```swift
/// Apply DECSTBM. `top` and `bottom` are 1-indexed VT values straight from
/// the parser (or nil for "use screen edge"). After validation, store on the
/// active buffer's `scrollRegion` as 0-indexed inclusive bounds. Invalid ranges
/// (top >= bottom, out of [0..<rows]) are rejected silently — the existing
/// region stays in place. Returns `false` because the change is not visible
/// in the current snapshot (it only affects future scroll behavior).
private func handleSetScrollRegion(top: Int?, bottom: Int?) -> Bool {
    let topZero  = (top ?? 1)    - 1                  // VT 1-indexed → 0-indexed
    let botZero  = (bottom ?? rows) - 1
    // nil/nil = reset to full screen.
    if top == nil && bottom == nil {
        mutateActive { $0.scrollRegion = nil }
        return false
    }
    // Validate.
    guard topZero >= 0, botZero < rows, topZero < botZero else {
        return false
    }
    mutateActive { $0.scrollRegion = ScrollRegion(top: topZero, bottom: botZero) }
    return false
}
```

- [ ] **Step 4: Replace the call sites of `Self.scrollUp(in:cols:rows:)` with a region-aware helper**

`handlePrintable` and `handleC0(.lineFeed/.verticalTab/.formFeed)` currently call `Self.scrollUp(in: &buf, cols: cols, rows: rows)` whenever cursor.row goes past the last row. Replace those call sites with a call to a new `Self.scrollUpRespectingRegion` helper that knows about `buf.scrollRegion`:

In `handlePrintable`, change:

```swift
if buf.cursor.row >= rows { Self.scrollUp(in: &buf, cols: cols, rows: rows) }
```

to:

```swift
if buf.cursor.row >= rows {
    Self.scrollWithinActiveBounds(in: &buf, cols: cols, rows: rows)
}
```

Same change in `handleC0` for `.lineFeed, .verticalTab, .formFeed`.

Replace the existing `Self.scrollUp(in:cols:rows:)` static helper with:

```swift
/// Full-screen scroll: shift rows 1..<rows up by one, clear the last row.
/// T6 will hook this for history feeds (main buffer only).
static func scrollUp(in buf: inout Buffer, cols: Int, rows: Int) {
    let stride = cols
    for dstRow in 0 ..< (rows - 1) {
        let srcStart = (dstRow + 1) * stride
        let dstStart = dstRow * stride
        for col in 0 ..< stride {
            buf.grid[dstStart + col] = buf.grid[srcStart + col]
        }
    }
    let lastRowStart = (rows - 1) * stride
    for col in 0 ..< stride {
        buf.grid[lastRowStart + col] = .empty
    }
    buf.cursor.row = rows - 1
}

/// Region-aware scroll: when `buf.scrollRegion` is non-nil and the cursor
/// just stepped past `region.bottom`, scroll only `region.top ... region.bottom`.
/// When the cursor stepped past the last screen row outside any region, do a
/// full-screen scroll. When cursor went past the screen but is OUTSIDE the
/// active region, clamp to last row without scrolling (matches xterm behavior).
static func scrollWithinActiveBounds(in buf: inout Buffer, cols: Int, rows: Int) {
    if let region = buf.scrollRegion {
        // Cursor is at row == rows (one past last); the LF/wrap that took us
        // here was inside the region only if buf.cursor.row - 1 == region.bottom.
        if buf.cursor.row - 1 == region.bottom {
            scrollRegionUp(in: &buf, cols: cols, region: region)
            buf.cursor.row = region.bottom
        } else {
            // Cursor went past last screen row but the LF was outside the region.
            // Clamp without scrolling (preserves region content).
            buf.cursor.row = rows - 1
        }
    } else {
        scrollUp(in: &buf, cols: cols, rows: rows)
    }
}

/// Scroll only the rows inside `region`. Top row of region evicted (discarded —
/// region scrolls do not feed history per spec §4); bottom row of region cleared.
private static func scrollRegionUp(in buf: inout Buffer, cols: Int, region: ScrollRegion) {
    let stride = cols
    for dstRow in region.top ..< region.bottom {
        let srcStart = (dstRow + 1) * stride
        let dstStart = dstRow * stride
        for col in 0 ..< stride {
            buf.grid[dstStart + col] = buf.grid[srcStart + col]
        }
    }
    let bottomStart = region.bottom * stride
    for col in 0 ..< stride {
        buf.grid[bottomStart + col] = .empty
    }
}
```

- [ ] **Step 5: Run all TermCore tests — expect pass**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test`

Expected: all green. The new region tests pass; existing scroll-related tests (which don't set a region) still pass via the full-screen path.

- [ ] **Step 6: Commit**

```bash
git add TermCore/ScreenModel.swift TermCoreTests/ScreenModelTests.swift
git commit -m "model: DECSTBM scroll region (Phase 2 T5)

handleSetScrollRegion stores top/bottom on the active buffer's
scrollRegion field as 0-indexed inclusive bounds. nil/nil resets
to full screen; invalid ranges (top >= bottom, out of [0..<rows])
are silently rejected per spec.

The static scrollUp helper from T2 is split:
- scrollUp: full-screen shift, evicts top row (T6 will hook this for
  main-buffer history feed)
- scrollRegionUp: scrolls only region.top...region.bottom, discards
  evicted top-of-region row (region scrolls never feed history per spec)
- scrollWithinActiveBounds: dispatcher called by handlePrintable +
  handleC0(LF/VT/FF). When cursor steps past the last row INSIDE the
  region, scroll the region. When OUTSIDE, clamp without scrolling
  (matches xterm).

Cursor positioning (CSI H, CUP, CUU/D/F/B, CHA, VPA) is intentionally
NOT clamped to the region — DECSTBM only constrains scroll behavior,
free movement is unaffected.

After this task: vim/less/htop status lines stay anchored without
smearing when the body scrolls."
```

---

## Task 6: ScreenModel — scrollback history + `recentHistory` in attach payload + history-aware restore

**Spec reference:** §4 ("Scrollback integration", "Snapshot shapes — render vs. wire"), §6 ("AttachPayload (cold attach): … history ≈ 1.3 MB at 80 cols").

**Goal:** Add a bounded scrollback history (`Row = ContiguousArray<Cell>`) to `ScreenModel`. When the main buffer scrolls naturally (full-screen scroll, no `scrollRegion` constraining the LF), the evicted top row is pushed to history. Alt buffer never feeds history. Region-internal scrolls never feed history. `buildAttachPayload()` populates `recentHistory` with the last 500 rows of history when `activeKind == .main`; `recentHistory` is empty when alt is active. The restore path takes a full `AttachPayload` so the client mirror seeds its history from the daemon's. Renderer-side nonisolated history access is added so T10 can render scrolled-back rows without `await`.

**Files:**
- Create: `TermCore/ScrollbackHistory.swift` (value-type wrapper around `CircularCollection<Row>` + valid-count tracking)
- Modify: `TermCore/ScreenModel.swift` (history field, scroll-feed hook, buildAttachPayload, restore(from:AttachPayload), nonisolated history accessor)
- Modify: `TermCore/AttachPayload.swift` (add convenience `init(snapshot:)` if not already; ensure existing public init accepts the rows)
- Create: `TermCoreTests/ScrollbackHistoryTests.swift` (pure-value-type tests)
- Modify: `TermCoreTests/ScreenModelTests.swift` (history feed, alt-buffer suppression, region suppression, attach payload contents)

### Steps

- [ ] **Step 1: Create `ScrollbackHistory` wrapper**

Create `TermCore/ScrollbackHistory.swift`:

```swift
//
//  ScrollbackHistory.swift
//  TermCore
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

import Foundation

/// Bounded scrollback buffer of rendered rows. Evictions are O(1) via the
/// underlying `CircularCollection<Row>` ring buffer, with `validCount`
/// distinguishing "real history" from the pre-allocated empty slots.
///
/// Spec §4 names `CircularCollection<Row>` as the storage shape; this wrapper
/// adds the count-of-valid-rows semantics needed for "starts empty, grows up
/// to capacity, evicts oldest beyond capacity".
public struct ScrollbackHistory: Sendable {

    /// Single rendered row of cells (matches `AttachPayload.Row`).
    public typealias Row = ContiguousArray<Cell>

    /// Maximum number of rows retained. Excess rows evict the oldest.
    public let capacity: Int

    /// Underlying ring buffer. Always `capacity`-sized; `validCount`
    /// determines how many of the slots hold real (non-placeholder) rows.
    @usableFromInline
    var ring: CircularCollection<ContiguousArray<Row>>

    /// Number of real rows currently held (`0 ... capacity`).
    public private(set) var validCount: Int = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "ScrollbackHistory capacity must be > 0")
        self.capacity = capacity
        self.ring = CircularCollection(ContiguousArray(repeating: Row(), count: capacity))
    }

    /// Number of real rows held (alias for `validCount`; kept for ergonomics).
    public var count: Int { validCount }

    /// Push a row to the tail. Once `validCount == capacity`, oldest row evicts.
    ///
    /// **Invariant:** rows are stored by whole-row replacement. The underlying
    /// `CircularCollection.append` overwrites the slot wholesale; existing
    /// row buffers are never mutated in place. This is what lets the
    /// renderer hold a published `HistoryBox.rows` snapshot whose row buffers
    /// share storage with the actor's `ring.elements[i]` via CoW — the
    /// actor's next push drops its reference to the prior row, but the
    /// reader's reference keeps the buffer alive. A future "patch a row in
    /// place" optimization would silently break this assumption.
    public mutating func push(_ row: Row) {
        ring.append(row)
        if validCount < capacity { validCount += 1 }
    }

    /// Snapshot of the most recent `n` rows (or all rows if `n > validCount`),
    /// in chronological order (oldest first → newest last).
    public func tail(_ n: Int) -> ContiguousArray<Row> {
        guard validCount > 0, n > 0 else { return [] }
        let take = Swift.min(n, validCount)
        var result = ContiguousArray<Row>()
        result.reserveCapacity(take)
        // CircularCollection iterates oldest → newest after the most recent
        // append. We want the LAST `take` of `validCount` real rows, where
        // "real" rows occupy the most-recently-written `validCount` slots.
        // Iterate and skip the first (validCount - take) real rows.
        let skip = validCount - take
        var seen = 0
        for (i, row) in ring.enumerated() {
            // Only the first `validCount` slots from the tail are real, but
            // CircularCollection iteration order already aligns with
            // append-order. Skip the (capacity - validCount) leading
            // placeholder slots.
            if i < (capacity - validCount) { continue }
            if seen < skip { seen += 1; continue }
            result.append(row)
        }
        return result
    }

    /// Snapshot of every real row in chronological order.
    public func all() -> ContiguousArray<Row> { tail(validCount) }
}
```

- [ ] **Step 2: Tests for `ScrollbackHistory`**

Create `TermCoreTests/ScrollbackHistoryTests.swift`:

```swift
//
//  ScrollbackHistoryTests.swift
//  TermCoreTests
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

import Testing
@testable import TermCore

@Suite("ScrollbackHistory")
struct ScrollbackHistoryTests {

    typealias Row = ScrollbackHistory.Row

    private func row(_ s: String) -> Row {
        ContiguousArray(s.map { Cell(character: $0) })
    }

    @Test("Empty history returns count = 0 and tail returns empty")
    func test_empty() {
        let h = ScrollbackHistory(capacity: 10)
        #expect(h.count == 0)
        #expect(h.tail(5) == [])
        #expect(h.all() == [])
    }

    @Test("Push grows count up to capacity")
    func test_push_grows() {
        var h = ScrollbackHistory(capacity: 3)
        h.push(row("a"))
        #expect(h.count == 1)
        h.push(row("b"))
        h.push(row("c"))
        #expect(h.count == 3)
        let all = h.all()
        #expect(all.count == 3)
        #expect(all[0] == row("a"))
        #expect(all[1] == row("b"))
        #expect(all[2] == row("c"))
    }

    @Test("Push beyond capacity evicts the oldest row")
    func test_push_evicts() {
        var h = ScrollbackHistory(capacity: 3)
        h.push(row("a"))
        h.push(row("b"))
        h.push(row("c"))
        h.push(row("d"))
        #expect(h.count == 3, "Capacity-bound count")
        let all = h.all()
        #expect(all == [row("b"), row("c"), row("d")])
    }

    @Test("tail(n) returns the last n rows in chronological order")
    func test_tail() {
        var h = ScrollbackHistory(capacity: 5)
        for c in "abcde" { h.push(row(String(c))) }
        let last2 = h.tail(2)
        #expect(last2 == [row("d"), row("e")])
    }

    @Test("tail(n) caps at validCount when n > validCount")
    func test_tail_caps() {
        var h = ScrollbackHistory(capacity: 10)
        h.push(row("x"))
        h.push(row("y"))
        let t = h.tail(100)
        #expect(t == [row("x"), row("y")])
    }
}
```

- [ ] **Step 3: Add `history` field + nonisolated history publication mutex to `ScreenModel`**

In `TermCore/ScreenModel.swift`:

1. Add at the actor level (near `_latestSnapshot`):

```swift
/// Bounded scrollback history (main buffer only). Mutated in place when the
/// main buffer scrolls naturally; alt activity never touches this.
private var history: ScrollbackHistory

/// Capacity (also seeds the history container at init).
public let historyCapacity: Int

/// Heap-boxed nonisolated mirror of the most-recent `publishedHistoryTailSize`
/// rows. Updated whenever `history` grows. Renderer reads via
/// `latestHistoryTail()` without an actor hop.
private final class HistoryBox: Sendable {
    let rows: ContiguousArray<ScrollbackHistory.Row>
    init(_ rows: ContiguousArray<ScrollbackHistory.Row>) { self.rows = rows }
}
private let _latestHistoryTail: Mutex<HistoryBox>

/// Number of most-recent history rows kept in the published nonisolated tail.
/// 1000 rows × 80 cols × ~32 B ≈ 2.5 MB. Phase 3's fetchHistory RPC can
/// expand this to deep backscroll without growing the published tail.
private static let publishedHistoryTailSize = 1000
```

2. Initialize `history` and `_latestHistoryTail` in the existing initializer. Update its signature to optionally accept `historyCapacity`:

```swift
public init(cols: Int = 80, rows: Int = 24,
            historyCapacity: Int = 10_000,
            queue: DispatchQueue? = nil) {
    let q = queue ?? DispatchQueue(label: "com.ronnyf.TermCore.ScreenModel")
    // swiftlint:disable:next force_cast
    self.executorQueue = q as! DispatchSerialQueue
    self.cols = cols
    self.rows = rows
    self.historyCapacity = historyCapacity
    self.history = ScrollbackHistory(capacity: historyCapacity)
    let main = Buffer(rows: rows, cols: cols)
    let alt = Buffer(rows: rows, cols: cols)
    self.main = main
    self.alt = alt
    let initial = ScreenSnapshot(
        activeCells: main.grid,
        cols: cols,
        rows: rows,
        cursor: main.cursor,
        cursorVisible: true,
        activeBuffer: .main,
        windowTitle: nil,
        cursorKeyApplication: false,
        bracketedPaste: false,
        bellCount: 0,
        version: 0
    )
    self._latestSnapshot = Mutex(SnapshotBox(initial))
    self._latestHistoryTail = Mutex(HistoryBox([]))
}
```

3. Add a publication helper near `publishSnapshot`:

```swift
/// Publish the most recent N history rows to the nonisolated mutex so the
/// renderer can read them without `await`. Called whenever a row is pushed
/// to history.
private func publishHistoryTail() {
    let tail = history.tail(Self.publishedHistoryTailSize)
    _latestHistoryTail.withLock { $0 = HistoryBox(tail) }
}
```

4. Add a nonisolated accessor near `latestSnapshot`:

```swift
/// Returns the published history tail (most recent rows, chronological order).
///
/// `nonisolated`, lock-protected pointer load — safe from any thread including
/// the render thread. Returns at most `publishedHistoryTailSize` rows.
nonisolated public func latestHistoryTail() -> ContiguousArray<ScrollbackHistory.Row> {
    _latestHistoryTail.withLock { $0.rows }
}
```

- [ ] **Step 4: Hook the history feed into the scroll path**

The static `scrollUp(in:cols:rows:)` static helper from T5 evicts a row but doesn't know whether the buffer is main vs alt. Replace it with a single static helper that returns the evicted top row when applicable, and have handlers collect + queue the row for batched publish at end of `apply(_:)`.

**Concurrency rationale.** Two design choices reduce the published-history-vs-published-snapshot race window to sub-microsecond:

1. *Defer* `publishHistoryTail()` to the end of `apply(_:)` (after all events in the batch process), and run it *before* `publishSnapshot()`. A renderer reading both nonisolated mutexes between those two calls sees history newer than snapshot — the lesser evil (briefly-duplicate row at `scrollOffset > 0`) versus the alternative (briefly-missing row).
2. The helper is `static` so it cannot accidentally read `self.history` / `self.activeKind` / `self.main` / `self.alt` from inside the `mutateActive { … }` closure (which already holds an inout to one of `self.main`/`self.alt`). Helpers that operate purely on the inout `Buffer` (`clampCursor(in: &buf)`, etc.) are safe inside `mutateActive` — Swift's exclusivity rule is only violated when a helper would alias the same actor storage already mutably-borrowed by the closure.

Add a per-actor flag for deferred history publish:

```swift
/// Set by handlers when a row is pushed to `history`; consumed at end of
/// `apply(_:)` to publish a fresh history tail to `_latestHistoryTail`
/// **before** the snapshot is published. Coupling the two publishes in
/// strict order keeps render-thread reads coherent without a combined lock.
private var pendingHistoryPublish: Bool = false
```

Add the static dispatcher (drops the now-unused T5 `scrollUp` and `scrollWithinActiveBounds` static helpers — `scrollAndMaybeEvict` subsumes them):

```swift
/// Scroll the active buffer and return the evicted top row when applicable
/// for history feed (main buffer + scroll covered the full screen).
/// Returns nil when:
/// - alt buffer (history feed disabled)
/// - region-internal scroll (region scrolls don't feed history)
private static func scrollAndMaybeEvict(in buf: inout Buffer, cols: Int, rows: Int, isMain: Bool) -> ScrollbackHistory.Row? {
    let stride = cols
    if let region = buf.scrollRegion {
        // Cursor is at row == rows (one past last); the LF/wrap that took us
        // here was inside the region only if buf.cursor.row - 1 == region.bottom.
        if buf.cursor.row - 1 == region.bottom {
            // Region scroll up — discard top-of-region row (region scrolls
            // never feed history per spec §4).
            for dstRow in region.top ..< region.bottom {
                let srcStart = (dstRow + 1) * stride
                let dstStart = dstRow * stride
                for col in 0 ..< stride {
                    buf.grid[dstStart + col] = buf.grid[srcStart + col]
                }
            }
            let bottomStart = region.bottom * stride
            for col in 0 ..< stride {
                buf.grid[bottomStart + col] = .empty
            }
            buf.cursor.row = region.bottom
            return nil
        }
        // Cursor was below the region (region.bottom < rows - 1) and stepped
        // past the last screen row — per xterm, this still triggers a
        // full-screen scroll. The pre-region rows ride along and the top
        // row of the screen evicts. When main, that evicted row feeds history.
        // (Pre-Phase 1 simplicity also lands us here when there's no region.)
        // Fall through to the full-screen branch below.
    }
    // Full-screen scroll.
    var evicted: ScrollbackHistory.Row? = nil
    if isMain {
        var top = ScrollbackHistory.Row()
        top.reserveCapacity(stride)
        for col in 0 ..< stride {
            top.append(buf.grid[col])
        }
        evicted = top
    }
    for dstRow in 0 ..< (rows - 1) {
        let srcStart = (dstRow + 1) * stride
        let dstStart = dstRow * stride
        for col in 0 ..< stride {
            buf.grid[dstStart + col] = buf.grid[srcStart + col]
        }
    }
    let lastRowStart = (rows - 1) * stride
    for col in 0 ..< stride {
        buf.grid[lastRowStart + col] = .empty
    }
    buf.cursor.row = rows - 1
    return evicted
}
```

Update the call sites in `handlePrintable` and `handleC0`:

```swift
private func handlePrintable(_ char: Character) -> Bool {
    let pen = self.pen
    let autoWrap = modes.autoWrap
    let isMain = (activeKind == .main)
    var evictedRow: ScrollbackHistory.Row? = nil
    mutateActive { buf in
        if buf.cursor.col >= cols {
            if autoWrap {
                buf.cursor.col = 0
                buf.cursor.row += 1
                if buf.cursor.row >= rows {
                    evictedRow = Self.scrollAndMaybeEvict(in: &buf, cols: cols, rows: rows, isMain: isMain)
                }
            } else {
                buf.cursor.col = cols - 1
            }
        }
        buf.grid[buf.cursor.row * cols + buf.cursor.col] = Cell(character: char, style: pen)
        buf.cursor.col += 1
    }
    if let evictedRow {
        history.push(evictedRow)
        pendingHistoryPublish = true
    }
    return true
}
```

For `handleC0` LF/VT/FF:

```swift
case .lineFeed, .verticalTab, .formFeed:
    let isMain = (activeKind == .main)
    var evictedRow: ScrollbackHistory.Row? = nil
    mutateActive { buf in
        buf.cursor.col = 0
        buf.cursor.row += 1
        if buf.cursor.row >= rows {
            evictedRow = Self.scrollAndMaybeEvict(in: &buf, cols: cols, rows: rows, isMain: isMain)
        }
    }
    if let evictedRow {
        history.push(evictedRow)
        pendingHistoryPublish = true
    }
    return true
```

Update `apply(_:)` (Phase 1 baseline) to drain `pendingHistoryPublish` *before* `publishSnapshot()`:

```swift
public func apply(_ events: [TerminalEvent]) {
    log.debug("Applying \(events.count) events")
    var changed = false
    for event in events {
        switch event {
        case .printable(let c): changed = handlePrintable(c) || changed
        case .c0(let control):  changed = handleC0(control) || changed
        case .csi(let cmd):     changed = handleCSI(cmd) || changed
        case .osc(let cmd):     changed = handleOSC(cmd) || changed
        case .unrecognized:     break
        }
    }
    if changed {
        version &+= 1
        // Publish history FIRST so a renderer reading both nonisolated
        // mutexes between these two calls sees history newer than snapshot
        // (briefly-duplicate row at scrollOffset > 0 is the lesser evil
        // versus a briefly-missing row).
        if pendingHistoryPublish {
            publishHistoryTail()
            pendingHistoryPublish = false
        }
        publishSnapshot()
    }
}
```

- [ ] **Step 5: Update `buildAttachPayload` to populate `recentHistory` from main history**

Replace the existing `buildAttachPayload` body with:

```swift
nonisolated public func buildAttachPayload() -> AttachPayload {
    let snap = _latestSnapshot.withLock { $0.snapshot }
    // recentHistory is main-buffer only per spec §4. When alt is active, the
    // history mirror still holds main rows but we don't include it (the
    // attaching client renders the alt buffer; main history is only useful
    // when the user later exits alt).
    let rows: ContiguousArray<ScrollbackHistory.Row>
    if snap.activeBuffer == .main {
        let tail = _latestHistoryTail.withLock { $0.rows }
        let last500 = tail.count > 500 ? ContiguousArray(tail.suffix(500)) : tail
        rows = last500
    } else {
        rows = []
    }
    return AttachPayload(
        snapshot: snap,
        recentHistory: rows,
        historyCapacity: historyCapacity
    )
}
```

- [ ] **Step 6: Add a history-aware restore that takes the full attach payload**

Add to `ScreenModel`:

```swift
/// Restore from a full attach payload. Live state comes from `payload.snapshot`
/// (same shape as `restore(from snapshot:)`); the local history is seeded with
/// `payload.recentHistory` so the user's scrollback survives detach/reattach.
public func restore(from payload: AttachPayload) {
    // Clear the published history tail BEFORE the live restore. Without this,
    // the renderer can briefly composite an alien (pre-restore) history tail
    // above a freshly-restored live grid. Publishing an empty tail first
    // ensures the renderer either sees an empty tail (drawn live-only) or
    // the new tail (drawn correctly) — never a stale-mixed frame.
    _latestHistoryTail.withLock { $0 = HistoryBox([]) }
    restore(from: payload.snapshot)
    self.history = ScrollbackHistory(capacity: payload.historyCapacity > 0 ? payload.historyCapacity : historyCapacity)
    for row in payload.recentHistory {
        history.push(row)
    }
    publishHistoryTail()
}
```

- [ ] **Step 7: Update `ContentView` (TerminalSession) to use the payload-taking restore**

`TerminalSession.connect()` and the response handler currently call `restore(from: payload.snapshot)` (Phase 1 — only the live snapshot). Switch to the new payload-taking overload so the client mirror's history is seeded from `payload.recentHistory`.

In `rTerm/ContentView.swift`, find both occurrences of `await screenModel.restore(from: payload.snapshot)` and change each to:

```swift
await screenModel.restore(from: payload)
```

(Two call sites: one inside `connect()` after `.attach` reply; one inside the `installResponseHandler` push handler.)

- [ ] **Step 8: Tests for history feed + attach payload + restore**

Append to `TermCoreTests/ScreenModelTests.swift`:

```swift
// MARK: - Scrollback history (Phase 2 T6)

@Test("Main-buffer LF at last row pushes evicted top row to history")
func test_history_feed_main_buffer() async {
    let model = ScreenModel(cols: 4, rows: 3, historyCapacity: 100)
    // Fill row 0 with 'aaaa', then move cursor to last row + LF to scroll.
    await model.apply([
        .printable("a"), .printable("a"), .printable("a"), .printable("a"),
        .csi(.cursorPosition(row: 2, col: 0)),
        .c0(.lineFeed),
    ])
    let tail = model.latestHistoryTail()
    #expect(tail.count == 1)
    #expect(tail[0].count == 4)
    #expect(tail[0].allSatisfy { $0.character == "a" })
}

@Test("Alt-buffer LF at last row does NOT push to history")
func test_history_feed_alt_buffer_suppressed() async {
    let model = ScreenModel(cols: 4, rows: 3, historyCapacity: 100)
    await model.apply([.csi(.setMode(.alternateScreen1049, enabled: true))])
    await model.apply([
        .printable("z"), .printable("z"), .printable("z"), .printable("z"),
        .csi(.cursorPosition(row: 2, col: 0)),
        .c0(.lineFeed),
    ])
    #expect(model.latestHistoryTail().count == 0)
}

@Test("DECSTBM region scroll does NOT push to history")
func test_history_feed_region_scroll_suppressed() async {
    let model = ScreenModel(cols: 4, rows: 5, historyCapacity: 100)
    // Set region 1..3, write top-of-region row, then LF inside region.
    await model.apply([.csi(.setScrollRegion(top: 2, bottom: 4))])  // rows 1..3
    await model.apply([
        .csi(.cursorPosition(row: 1, col: 0)),
        .printable("X"),
        .csi(.cursorPosition(row: 3, col: 0)),
        .c0(.lineFeed),
    ])
    #expect(model.latestHistoryTail().count == 0)
}

@Test("History grows to capacity then evicts oldest")
func test_history_capacity_evicts_oldest() async {
    let model = ScreenModel(cols: 1, rows: 2, historyCapacity: 3)
    // Each LF at row 1 evicts row 0 to history.
    for letter in "abcdef" {
        await model.apply([
            .printable(Character(String(letter))),
            .csi(.cursorPosition(row: 1, col: 0)),
            .c0(.lineFeed),
        ])
    }
    let tail = model.latestHistoryTail()
    #expect(tail.count == 3, "Capacity-bound history")
    // Last 3 evicted rows are 'd', 'e', 'f' (in chronological order).
    let chars = tail.map { $0.first?.character ?? " " }
    #expect(chars == ["d", "e", "f"])
}

@Test("buildAttachPayload populates recentHistory with last 500 rows when main active")
func test_attach_payload_populates_history() async {
    let model = ScreenModel(cols: 1, rows: 2, historyCapacity: 1000)
    for _ in 0..<10 {
        await model.apply([.printable("x"), .csi(.cursorPosition(row: 1, col: 0)), .c0(.lineFeed)])
    }
    let payload = model.buildAttachPayload()
    #expect(payload.recentHistory.count == 10)
    #expect(payload.historyCapacity == 1000)
}

@Test("buildAttachPayload returns empty recentHistory when alt active")
func test_attach_payload_empty_history_in_alt() async {
    let model = ScreenModel(cols: 1, rows: 2, historyCapacity: 1000)
    // Build up some history in main first.
    for _ in 0..<5 {
        await model.apply([.printable("x"), .csi(.cursorPosition(row: 1, col: 0)), .c0(.lineFeed)])
    }
    // Switch to alt.
    await model.apply([.csi(.setMode(.alternateScreen1049, enabled: true))])
    let payload = model.buildAttachPayload()
    #expect(payload.recentHistory.isEmpty)
    #expect(payload.snapshot.activeBuffer == .alt)
}

@Test("restore(from payload:) seeds local history from payload.recentHistory")
func test_restore_payload_seeds_history() async {
    // Build source model with some history.
    let source = ScreenModel(cols: 1, rows: 2, historyCapacity: 1000)
    for c in "abc" {
        await source.apply([.printable(Character(String(c))), .csi(.cursorPosition(row: 1, col: 0)), .c0(.lineFeed)])
    }
    let payload = source.buildAttachPayload()
    // Restore into a fresh client mirror.
    let mirror = ScreenModel(cols: 1, rows: 2, historyCapacity: 1000)
    await mirror.restore(from: payload)
    let tail = mirror.latestHistoryTail()
    #expect(tail.count == 3)
    let chars = tail.map { $0.first?.character ?? " " }
    #expect(chars == ["a", "b", "c"])
}

@Test("latestHistoryTail caps at publishedHistoryTailSize (1000)")
func test_history_tail_publication_cap() async {
    let model = ScreenModel(cols: 1, rows: 2, historyCapacity: 5000)
    for _ in 0..<1500 {
        await model.apply([.printable("x"), .csi(.cursorPosition(row: 1, col: 0)), .c0(.lineFeed)])
    }
    // Internal history holds all 1500; published tail caps at 1000.
    #expect(model.latestHistoryTail().count == 1000)
}
```

- [ ] **Step 9: Run all TermCore tests — expect pass**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test`

Expected: all green. Phase 1 + earlier T2-T5 tests still pass; new history tests pass.

- [ ] **Step 10: Commit**

```bash
git add TermCore/ScrollbackHistory.swift TermCore/ScreenModel.swift \
        TermCoreTests/ScrollbackHistoryTests.swift TermCoreTests/ScreenModelTests.swift \
        rTerm/ContentView.swift
git commit -m "model: scrollback history + attach-payload + restore (Phase 2 T6)

ScrollbackHistory wraps CircularCollection<Row> with validCount-tracking
so 'starts empty, grows to capacity, evicts oldest' semantics work.
Push is O(1); tail(n) is O(capacity) but bounded.

ScreenModel:
- history: ScrollbackHistory  — main-buffer-only, capacity 10K rows default
- _latestHistoryTail: Mutex<HistoryBox>  — nonisolated mirror for renderer
- publishedHistoryTailSize = 1000 rows (~2.5 MB at 80 cols)
- scrollAndMaybeEvict: single static helper consolidates T5's scroll
  helpers and returns the evicted top row when (isMain && no region scroll)

Hot-path discipline: handlePrintable / handleC0(LF/VT/FF) collect the
evicted row inside the mutateActive closure (no aliasing of self.main
/ self.alt) and push to history outside the closure. This avoids
exclusive-access conflicts under Swift 6 strict concurrency.

buildAttachPayload populates recentHistory with last 500 rows when
activeKind == .main; empty when alt active (matches spec §4).
historyCapacity travels in the payload so the client mirror can size
its own buffer.

restore(from payload:) seeds the local history from recentHistory so
detach/reattach preserves user-visible scrollback.

latestHistoryTail() — nonisolated, lock-protected pointer load — gives
the renderer access to history rows without an actor hop. T10 wires
the scrollback UI on top of it."
```

---

## Task 7: KeyEncoder — arrow keys / Home / End / PgUp / PgDn + DECCKM application-mode toggle

**Spec reference:** §3 (`DECPrivateMode.cursorKeyApplication`); spec §8 Phase 2 in-scope item ("DECCKM (1) with `KeyEncoder` hook").

**Goal:** Phase 1's `KeyEncoder` only emits ctrl-letter, Return, Backspace, Tab, and printable characters. Add arrow keys (left/right/up/down), Home, End, PgUp, PgDn, and Insert/Delete-forward — the keys vim/less/etc. expect. Encoding for cursor keys depends on DECCKM mode: normal mode emits `ESC [ A/B/C/D`, application mode emits `ESC O A/B/C/D`. KeyEncoder stays a stateless `Sendable` value type — the mode is passed as a per-call parameter.

`TerminalMTKView.keyDown` reads `screenModel.latestSnapshot().cursorKeyApplication` (nonisolated, no `await`) and passes it to `KeyEncoder.encode`.

**Files:**
- Modify: `rTerm/KeyEncoder.swift` (CursorKeyMode enum, expanded encode)
- Modify: `rTerm/TermView.swift` (keyDown reads mode from snapshot, passes to encoder)
- Modify: `rTermTests/KeyEncoderTests.swift` (arrow / Home / End / PgUp / PgDn in both modes; existing tests already cover ctrl-letter + Return + Backspace + Tab)

### Steps

- [ ] **Step 1: Read current KeyEncoder + KeyEncoderTests**

Implementer reads `/Users/ronny/rdev/rTerm/rTerm/KeyEncoder.swift` and `/Users/ronny/rdev/rTerm/rTermTests/KeyEncoderTests.swift` to confirm the starting test surface.

- [ ] **Step 2: Write failing tests**

Append to `rTermTests/KeyEncoderTests.swift`:

```swift
// MARK: - Arrow keys (Phase 2 T7)

@Test("Up arrow normal-mode → ESC [ A")
@MainActor
func test_arrow_up_normal_mode() {
    // keyCode 126 = up arrow
    let event = mockKeyDown(keyCode: 126)
    let encoded = KeyEncoder().encode(event, cursorKeyMode: .normal)
    #expect(encoded == Data([0x1B, 0x5B, 0x41]))
}

@Test("Up arrow application-mode → ESC O A")
@MainActor
func test_arrow_up_application_mode() {
    let event = mockKeyDown(keyCode: 126)
    let encoded = KeyEncoder().encode(event, cursorKeyMode: .application)
    #expect(encoded == Data([0x1B, 0x4F, 0x41]))
}

@Test("All four arrows match VT/xterm: A=up B=down C=right D=left")
@MainActor
func test_all_arrows_normal_mode() {
    let cases: [(keyCode: UInt16, suffix: UInt8)] = [
        (126, 0x41),  // up    → A
        (125, 0x42),  // down  → B
        (124, 0x43),  // right → C
        (123, 0x44),  // left  → D
    ]
    for (keyCode, suffix) in cases {
        let event = mockKeyDown(keyCode: keyCode)
        let encoded = KeyEncoder().encode(event, cursorKeyMode: .normal)
        #expect(encoded == Data([0x1B, 0x5B, suffix]),
                "keyCode \(keyCode) normal-mode")
    }
}

@Test("All four arrows in application mode use ESC O")
@MainActor
func test_all_arrows_application_mode() {
    let cases: [(keyCode: UInt16, suffix: UInt8)] = [
        (126, 0x41), (125, 0x42), (124, 0x43), (123, 0x44),
    ]
    for (keyCode, suffix) in cases {
        let event = mockKeyDown(keyCode: keyCode)
        let encoded = KeyEncoder().encode(event, cursorKeyMode: .application)
        #expect(encoded == Data([0x1B, 0x4F, suffix]),
                "keyCode \(keyCode) application-mode")
    }
}

// MARK: - Home / End (Phase 2 T7)

@Test("Home key → ESC [ H")
@MainActor
func test_home_key() {
    // keyCode 115 = Home (fn + left arrow on Mac compact keyboards)
    let event = mockKeyDown(keyCode: 115)
    let encoded = KeyEncoder().encode(event, cursorKeyMode: .normal)
    #expect(encoded == Data([0x1B, 0x5B, 0x48]))
}

@Test("End key → ESC [ F")
@MainActor
func test_end_key() {
    let event = mockKeyDown(keyCode: 119)
    let encoded = KeyEncoder().encode(event, cursorKeyMode: .normal)
    #expect(encoded == Data([0x1B, 0x5B, 0x46]))
}

// MARK: - PgUp / PgDn (Phase 2 T7)

@Test("Page Up → ESC [ 5 ~")
@MainActor
func test_page_up() {
    let event = mockKeyDown(keyCode: 116)
    let encoded = KeyEncoder().encode(event, cursorKeyMode: .normal)
    #expect(encoded == Data([0x1B, 0x5B, 0x35, 0x7E]))
}

@Test("Page Down → ESC [ 6 ~")
@MainActor
func test_page_down() {
    let event = mockKeyDown(keyCode: 121)
    let encoded = KeyEncoder().encode(event, cursorKeyMode: .normal)
    #expect(encoded == Data([0x1B, 0x5B, 0x36, 0x7E]))
}

// MARK: - Forward Delete (Phase 2 T7)

@Test("Forward Delete (fn-Delete) → ESC [ 3 ~")
@MainActor
func test_forward_delete() {
    // keyCode 117 = forward delete on Mac compact keyboards (fn + delete)
    let event = mockKeyDown(keyCode: 117)
    let encoded = KeyEncoder().encode(event, cursorKeyMode: .normal)
    #expect(encoded == Data([0x1B, 0x5B, 0x33, 0x7E]))
}
```

If `mockKeyDown(keyCode:)` does not yet exist in the test file, add this helper near the top (Phase 1 tests likely already use a similar one; reuse it):

```swift
@MainActor
private func mockKeyDown(keyCode: UInt16,
                         characters: String = "",
                         modifierFlags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifierFlags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    )!
}
```

- [ ] **Step 3: Run new tests — expect failures**

Run: `xcodebuild -project rTerm.xcodeproj -scheme rTermTests test -only-testing rTermTests/KeyEncoderTests`

Expected: 9 new tests fail (KeyEncoder.encode signature doesn't take a mode; arrow / Home / End / PgUp / PgDn / fwdDelete unhandled).

- [ ] **Step 4: Extend `KeyEncoder` with `CursorKeyMode` and the new keys**

Replace the body of `rTerm/KeyEncoder.swift` with:

```swift
//
//  KeyEncoder.swift
//  rTerm
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

import AppKit
import Foundation

/// Whether arrow keys (and Home / End) emit application-mode (`ESC O X`) or
/// normal-mode (`ESC [ X`) sequences. Mirrors DECCKM (DEC private mode 1).
@frozen public enum CursorKeyMode: Sendable, Equatable {
    case normal
    case application
}

/// Translates `NSEvent` key events into the byte sequences a terminal shell expects.
public struct KeyEncoder: Sendable {

    public init() {}

    /// Encode a key-down event into the bytes to write to the PTY.
    ///
    /// - Parameter event: The AppKit key-down event.
    /// - Parameter cursorKeyMode: Selects between application and normal cursor
    ///   key sequences. Read from `ScreenModel.latestSnapshot().cursorKeyApplication`
    ///   at call time — KeyEncoder is stateless so the same instance is safe to
    ///   reuse across keystrokes.
    /// - Returns: The encoded bytes, or `nil` for unhandled keys.
    public func encode(_ event: NSEvent, cursorKeyMode: CursorKeyMode = .normal) -> Data? {
        // 1. Special keys by keyCode (handled before printable-character paths).
        switch event.keyCode {
        case 36:  return Data([0x0D])                  // Return / Enter
        case 51:  return Data([0x7F])                  // Delete / Backspace (sends DEL — matches POSIX terminals)
        case 48:  return Data([0x09])                  // Tab

        // Cursor keys — DECCKM-aware.
        case 126: return cursorKey(.up,    mode: cursorKeyMode)
        case 125: return cursorKey(.down,  mode: cursorKeyMode)
        case 124: return cursorKey(.right, mode: cursorKeyMode)
        case 123: return cursorKey(.left,  mode: cursorKeyMode)

        // Home / End. xterm uses ESC [ H / ESC [ F regardless of DECCKM in the
        // most common configurations; some apps also accept ESC O H / ESC O F.
        // We follow xterm's "linux"/"vt220" preset: always CSI form.
        case 115: return Data([0x1B, 0x5B, 0x48])      // Home → ESC [ H
        case 119: return Data([0x1B, 0x5B, 0x46])      // End  → ESC [ F

        // Page Up / Page Down — DEC-style ~ tilde sequences.
        case 116: return Data([0x1B, 0x5B, 0x35, 0x7E])  // PgUp → ESC [ 5 ~
        case 121: return Data([0x1B, 0x5B, 0x36, 0x7E])  // PgDn → ESC [ 6 ~

        // Forward delete (fn-Delete on compact keyboards).
        case 117: return Data([0x1B, 0x5B, 0x33, 0x7E])  // ESC [ 3 ~

        default:
            break
        }

        // 2. Ctrl + letter (a-z) → control byte (Phase 1 behavior, preserved).
        if event.modifierFlags.contains(.control),
           let raw = event.charactersIgnoringModifiers,
           raw.count == 1,
           let scalar = raw.unicodeScalars.first,
           scalar.value >= UInt32(Character("a").asciiValue!),
           scalar.value <= UInt32(Character("z").asciiValue!) {
            let byte = UInt8(scalar.value) &- 0x60
            return Data([byte])
        }

        // 3. Printable characters (handles shift, option-modified glyphs, etc.).
        if let characters = event.characters, !characters.isEmpty {
            return Data(characters.utf8)
        }

        return nil
    }

    private enum CursorKey { case up, down, right, left }

    /// Encode an arrow key. Final byte: A=up, B=down, C=right, D=left.
    private func cursorKey(_ key: CursorKey, mode: CursorKeyMode) -> Data {
        let final: UInt8
        switch key {
        case .up:    final = 0x41
        case .down:  final = 0x42
        case .right: final = 0x43
        case .left:  final = 0x44
        }
        let intro: UInt8 = (mode == .application) ? 0x4F /* O */ : 0x5B /* [ */
        return Data([0x1B, intro, final])
    }
}
```

- [ ] **Step 5: Update `TerminalMTKView.keyDown` to pass cursor key mode from the snapshot**

In `rTerm/TermView.swift`, modify `TerminalMTKView`:

1. Add a property to hold a closure for fetching the current mode (avoids a circular reference to `screenModel`):

```swift
final class TerminalMTKView: MTKView {
    private let log = Logger(subsystem: "rTerm", category: "TerminalMTKView")

    /// Called with the encoded byte sequence for each key-down event.
    var onKeyInput: ((Data) -> Void)?

    /// Called by `keyDown` to fetch the current DECCKM state. Returns
    /// `.normal` when nil. The closure is set by the SwiftUI bridge from
    /// `screenModel.latestSnapshot().cursorKeyApplication` at view-make time.
    var cursorKeyModeProvider: (() -> CursorKeyMode)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        let mode = cursorKeyModeProvider?() ?? .normal
        let encoder = KeyEncoder()
        if let data = encoder.encode(event, cursorKeyMode: mode) {
            log.debug("keyDown: keyCode=\(event.keyCode), encoded \(data.count) bytes")
            onKeyInput?(data)
        } else {
            log.debug("keyDown: keyCode=\(event.keyCode), unhandled")
        }
    }
}
```

2. Update the `TermView.makeNSView` and `updateNSView` to wire `cursorKeyModeProvider` from `screenModel.latestSnapshot()`:

```swift
func makeNSView(context: Context) -> TerminalMTKView {
    let coordinator = context.coordinator
    let view = TerminalMTKView(frame: .zero, device: coordinator.device)
    view.delegate = coordinator
    view.preferredFramesPerSecond = 60
    view.colorPixelFormat = .bgra8Unorm
    view.clearColor = clearColor(for: settings.palette.defaultBackground)
    view.onKeyInput = onInput
    let model = screenModel
    view.cursorKeyModeProvider = {
        // latestSnapshot() is nonisolated and lock-protected — safe from
        // any thread including the AppKit responder chain on MainActor.
        model.latestSnapshot().cursorKeyApplication ? .application : .normal
    }
    return view
}

func updateNSView(_ nsView: TerminalMTKView, context: Context) {
    nsView.onKeyInput = onInput
    nsView.clearColor = clearColor(for: settings.palette.defaultBackground)
    let model = screenModel
    nsView.cursorKeyModeProvider = {
        model.latestSnapshot().cursorKeyApplication ? .application : .normal
    }
}
```

- [ ] **Step 6: Run all tests — expect pass**

Run: `xcodebuild -project rTerm.xcodeproj -scheme rTermTests test -only-testing rTermTests/KeyEncoderTests`

Expected: all KeyEncoder tests pass, including the 9 new ones.

Run: `xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build`

Expected: clean build with no warnings.

- [ ] **Step 7: Commit**

```bash
git add rTerm/KeyEncoder.swift rTerm/TermView.swift rTermTests/KeyEncoderTests.swift
git commit -m "input: arrow keys, Home/End, PgUp/PgDn + DECCKM (Phase 2 T7)

KeyEncoder grows arrow/Home/End/PgUp/PgDn/forward-Delete handling and
takes a CursorKeyMode parameter (.normal | .application) so DECCKM
(DEC private mode 1) selects between ESC[A/B/C/D and ESCO A/B/C/D.

KeyEncoder stays stateless and Sendable — the per-call parameter avoids
plumbing mode state through every keystroke.

TerminalMTKView gains a cursorKeyModeProvider closure that reads
screenModel.latestSnapshot().cursorKeyApplication. The closure runs
on MainActor (responder chain), and latestSnapshot() is nonisolated
and lock-protected so there's no actor hop on the input hot path.

PgUp/PgDn currently encode as DEC ~ sequences and are passed straight
to the shell — T10 will intercept them BEFORE the encoder when scroll
mode is active, to drive scrollback navigation.

Home/End follow xterm's CSI form (ESC[H, ESC[F) regardless of DECCKM —
matches the most common terminfo entries (xterm-256color)."
```

---

## Task 8: Bracketed paste — `TerminalSession.paste(_:)` + `TerminalMTKView.paste(_:)` responder hook

**Spec reference:** §3 (`DECPrivateMode.bracketedPaste`); spec §8 Phase 2 ("bracketed paste (2004)").

**Goal:** When the shell has enabled bracketed paste (mode 2004) and the user pastes via Cmd-V (or the Edit > Paste menu), wrap the pasted text with `ESC [ 2 0 0 ~ ... ESC [ 2 0 1 ~` so the shell can distinguish pasted bytes from typed bytes. When the mode is off, send raw bytes.

The wrapping function `bracketedPasteWrap(_:enabled:)` is a static helper on `TerminalSession` so it's testable without an AppKit responder dance. `TerminalMTKView` overrides `paste(_:)` and `validateMenuItem(_:)` to wire Cmd-V into a closure that calls into the session.

**Files:**
- Modify: `rTerm/TermView.swift` (TerminalMTKView paste(_:) + validateMenuItem(_:) overrides; onPaste closure)
- Modify: `rTerm/ContentView.swift` (TerminalSession.paste(_:) + static helper; wire onPaste in TermView wrapping)
- Create: `rTermTests/BracketedPasteTests.swift` (pure-helper tests)

### Steps

- [ ] **Step 1: Write failing tests for the wrap helper**

Create `rTermTests/BracketedPasteTests.swift`:

```swift
//
//  BracketedPasteTests.swift
//  rTermTests
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

import Foundation
import Testing
@testable import rTerm

@Suite("Bracketed paste")
struct BracketedPasteTests {

    @Test("Wrap when enabled adds ESC[200~ ... ESC[201~ envelope")
    func test_wrap_enabled() {
        let wrapped = TerminalSession.bracketedPasteWrap("hello", enabled: true)
        let expected =
            Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])  // ESC [ 2 0 0 ~
            + "hello".data(using: .utf8)!
            + Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])  // ESC [ 2 0 1 ~
        #expect(wrapped == expected)
    }

    @Test("Wrap when disabled returns raw UTF-8 bytes")
    func test_wrap_disabled() {
        let raw = TerminalSession.bracketedPasteWrap("hello", enabled: false)
        #expect(raw == "hello".data(using: .utf8))
    }

    @Test("Empty string still receives the envelope when enabled")
    func test_wrap_empty_enabled() {
        let wrapped = TerminalSession.bracketedPasteWrap("", enabled: true)
        let expected =
            Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E,
                  0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])
        #expect(wrapped == expected)
    }

    @Test("Multi-byte UTF-8 (emoji + accented chars) is preserved inside the envelope")
    func test_wrap_multibyte_utf8() {
        let wrapped = TerminalSession.bracketedPasteWrap("café 🍰", enabled: true)
        let payload = "café 🍰".data(using: .utf8)!
        #expect(wrapped.starts(with: [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]))
        #expect(wrapped.suffix(6) == Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]))
        let middleStart = 6
        let middleEnd = wrapped.count - 6
        let middle = wrapped.subdata(in: middleStart..<middleEnd)
        #expect(middle == payload)
    }
}
```

- [ ] **Step 2: Run new tests — expect failures**

Run: `xcodebuild -project rTerm.xcodeproj -scheme rTermTests test -only-testing rTermTests/BracketedPasteTests`

Expected: 4 tests fail (TerminalSession.bracketedPasteWrap doesn't exist).

- [ ] **Step 3: Add the wrap helper + paste path to `TerminalSession`**

In `rTerm/ContentView.swift`, inside `TerminalSession`, add:

```swift
// MARK: - Bracketed paste (Phase 2 T8)

/// Wrap pasted text with the bracketed-paste envelope when enabled.
///
/// Shells that have set DEC private mode 2004 expect the envelope so they
/// can distinguish pasted bytes from typed bytes (vim, fish, zsh-with-syntax-
/// highlighting all use this to suppress autoindent and key-binding triggers
/// during paste). When 2004 is off, the raw UTF-8 bytes are sent verbatim.
public static func bracketedPasteWrap(_ text: String, enabled: Bool) -> Data {
    let payload = Data(text.utf8)
    guard enabled else { return payload }
    var data = Data()
    data.reserveCapacity(payload.count + 12)
    data.append(contentsOf: [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])  // ESC [ 2 0 0 ~
    data.append(payload)
    data.append(contentsOf: [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])  // ESC [ 2 0 1 ~
    return data
}

/// Send pasted text to the active session, wrapping if the shell has
/// enabled bracketed paste (mode 2004).
func paste(_ text: String) {
    let enabled = screenModel.latestSnapshot().bracketedPaste
    let data = Self.bracketedPasteWrap(text, enabled: enabled)
    sendInput(data)
}
```

- [ ] **Step 4: Wire `paste(_:)` and `validateMenuItem(_:)` on `TerminalMTKView`**

In `rTerm/TermView.swift`, modify `TerminalMTKView`:

1. Add an `onPaste` closure property:

```swift
/// Called when the user invokes Edit > Paste (Cmd-V). The handler reads
/// the system pasteboard's first plain-text item and forwards it.
var onPaste: ((String) -> Void)?
```

2. Add `paste(_:)` and `validateMenuItem(_:)` overrides at the end of the class:

```swift
@objc
override func paste(_ sender: Any?) {
    let pb = NSPasteboard.general
    guard let str = pb.string(forType: .string), !str.isEmpty else { return }
    log.debug("paste: \(str.count) chars")
    onPaste?(str)
}

override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(NSText.paste(_:)) {
        return NSPasteboard.general.string(forType: .string) != nil
    }
    return super.validateMenuItem(menuItem)
}
```

3. Wire `onPaste` from the SwiftUI bridge — extend `TermView` with an `onPaste` parameter and forward it:

```swift
struct TermView: NSViewRepresentable {

    let screenModel: ScreenModel
    let settings: AppSettings
    var onInput: ((Data) -> Void)?
    var onPaste: ((String) -> Void)?

    // makeCoordinator unchanged.

    func makeNSView(context: Context) -> TerminalMTKView {
        let coordinator = context.coordinator
        let view = TerminalMTKView(frame: .zero, device: coordinator.device)
        view.delegate = coordinator
        view.preferredFramesPerSecond = 60
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = clearColor(for: settings.palette.defaultBackground)
        view.onKeyInput = onInput
        view.onPaste = onPaste
        let model = screenModel
        view.cursorKeyModeProvider = {
            model.latestSnapshot().cursorKeyApplication ? .application : .normal
        }
        return view
    }

    func updateNSView(_ nsView: TerminalMTKView, context: Context) {
        nsView.onKeyInput = onInput
        nsView.onPaste = onPaste
        nsView.clearColor = clearColor(for: settings.palette.defaultBackground)
        let model = screenModel
        nsView.cursorKeyModeProvider = {
            model.latestSnapshot().cursorKeyApplication ? .application : .normal
        }
    }

    private func clearColor(for rgba: RGBA) -> MTLClearColor {
        MTLClearColor(
            red:   Double(rgba.r) / 255.0,
            green: Double(rgba.g) / 255.0,
            blue:  Double(rgba.b) / 255.0,
            alpha: Double(rgba.a) / 255.0
        )
    }
}
```

4. Wire `onPaste` from `ContentView`:

```swift
struct ContentView: View {
    @State private var session = TerminalSession()
    @State private var settings = AppSettings()

    var body: some View {
        TermView(
            screenModel: session.screenModel,
            settings: settings,
            onInput: { data in session.sendInput(data) },
            onPaste: { text in session.paste(text) }
        )
        .navigationTitle(session.windowTitle ?? "rTerm")
        .task {
            do { try Agent().register() } catch { print("ERROR: \(error)") }
            await session.connect()
        }
    }
}
```

- [ ] **Step 5: Run new + full test suite — expect pass**

Run: `xcodebuild -project rTerm.xcodeproj -scheme rTermTests test`

Expected: all rTerm tests pass, including the 4 new BracketedPasteTests.

Run: `xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build`

Expected: clean build.

- [ ] **Step 6: Commit**

```bash
git add rTerm/KeyEncoder.swift rTerm/TermView.swift rTerm/ContentView.swift \
        rTermTests/BracketedPasteTests.swift
git commit -m "input: bracketed paste (Phase 2 T8)

TerminalSession.bracketedPasteWrap(_:enabled:) wraps pasted text with
ESC[200~ ... ESC[201~ when DEC mode 2004 is set, raw UTF-8 otherwise.
Static helper for testability.

TerminalSession.paste(_:) reads bracketedPaste flag from
screenModel.latestSnapshot() (nonisolated, no actor hop), wraps,
and forwards to sendInput.

TerminalMTKView overrides NSResponder.paste(_:) — Cmd-V / Edit menu Paste
fires when an NSPasteboard string is available (validateMenuItem gates
the menu item on pasteboard availability). The view's onPaste closure
calls into TerminalSession.paste.

ContentView wires the onPaste closure when constructing TermView; the
SwiftUI bridge propagates it through makeNSView / updateNSView (alongside
the cursorKeyModeProvider added in T7).

Result: pasting into vim's insert mode no longer triggers cascading
autoindent disasters; fish syntax highlighter / zsh autosuggestions
both correctly bypass keybinding evaluation during paste."
```

---

## Task 9: Renderer — italic + bold-italic atlases; dim / reverse / strikethrough activation; visual bell

**Spec reference:** §5 (Attribute rendering table; "Glyph atlas: family of up-to-four atlases ... Phase 1 ships regular + bold; italic + bold-italic materialize when Phase 2 activates the italic attribute"). Spec §4 C0 table notes bell handling is a "Phase 2 UX detail".

**Goal:** Phase 1 already parses italic / dim / reverse / strikethrough into `Cell.style.attributes` — they're stored on every cell but ignored by the shader. Phase 2 activates them:

- **italic / bold-italic:** materialize the two missing `GlyphAtlas` variants and pick atlas via 4-way switch (regular / bold / italic / bold-italic).
- **dim:** multiply fg alpha by 0.5 at projection time.
- **reverse:** swap fg and bg before quad emission.
- **strikethrough:** overlay quad at cell mid-height (mirrors the underline pass).
- **bell:** track `lastSeenBellCount` on `RenderCoordinator`; when a snapshot's `bellCount` exceeds it, call `NSSound.beep()` and update.

**Files:**
- Modify: `rTerm/GlyphAtlas.swift` (uncomment `.italic` and `.boldItalic` Variant cases; pick `NSFontDescriptor` italic trait)
- Modify: `rTerm/RenderCoordinator.swift` (build all 4 atlases at init; 4-way atlas selection; reverse swap; dim alpha; strikethrough overlay; bell observer)
- Modify: `rTerm/Shaders.metal` — none expected (overlay shader already handles thin quads)
- Create: `rTerm/AttributeProjection.swift` (pure helpers for "given style, fg, bg, return effective fg/bg" — tests target this without Metal)
- Create: `rTermTests/AttributeProjectionTests.swift`

### Steps

- [ ] **Step 1: Add `.italic` and `.boldItalic` to `GlyphAtlas.Variant`**

In `rTerm/GlyphAtlas.swift`, replace the `Variant` enum and the font-selection block:

```swift
enum Variant: Sendable, Equatable {
    case regular
    case bold
    case italic
    case boldItalic
}
```

Replace the existing font-selection in `init`:

```swift
// REMOVE these lines:
let weight: NSFont.Weight = (variant == .bold) ? .bold : .regular
let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: weight)
```

with:

```swift
let weight: NSFont.Weight
switch variant {
case .regular, .italic:         weight = .regular
case .bold, .boldItalic:        weight = .bold
}
let baseFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: weight)
let font: NSFont
switch variant {
case .regular, .bold:
    font = baseFont
case .italic, .boldItalic:
    // Apply italic trait. monospaced system font may not have a true italic
    // glyph variant on all macOS versions; the Cocoa transform falls back
    // to a synthesized oblique. When even the descriptor lookup fails (rare;
    // very old SF Mono builds), we silently fall back to the regular font —
    // log a one-time warning so this is debuggable.
    let italicDescriptor = baseFont.fontDescriptor.withSymbolicTraits(.italic)
    if let italicFont = NSFont(descriptor: italicDescriptor, size: fontSize) {
        font = italicFont
    } else {
        Logger(subsystem: "rTerm", category: "GlyphAtlas")
            .warning("Italic font descriptor lookup failed for variant \(String(describing: variant)) — falling back to regular weight; italic-attributed cells will render as upright glyphs.")
        font = baseFont
    }
}
```

- [ ] **Step 2: Build all 4 atlases at `RenderCoordinator` init**

In `rTerm/RenderCoordinator.swift`, replace:

```swift
private let regularAtlas: GlyphAtlas
private let boldAtlas: GlyphAtlas
```

with:

```swift
private let regularAtlas: GlyphAtlas
private let boldAtlas: GlyphAtlas
private let italicAtlas: GlyphAtlas
private let boldItalicAtlas: GlyphAtlas
```

Update the initializer's atlas-construction block:

```swift
self.regularAtlas    = GlyphAtlas(device: device, variant: .regular)
self.boldAtlas       = GlyphAtlas(device: device, variant: .bold)
self.italicAtlas     = GlyphAtlas(device: device, variant: .italic)
self.boldItalicAtlas = GlyphAtlas(device: device, variant: .boldItalic)
```

(All four built eagerly. Italic atlases are common in real-world prompts and shell themes; lazy materialization adds complexity for marginal gain. ~20 ms one-time cost at app launch is acceptable.)

- [ ] **Step 3: Create `AttributeProjection` (testable pure helpers for reverse + dim)**

Create `rTerm/AttributeProjection.swift`:

```swift
//
//  AttributeProjection.swift
//  rTerm
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

import simd
import TermCore

/// Pure helpers that map a `Cell`'s SGR attributes onto the effective fg/bg
/// SIMD colors the renderer hands to the shader. Kept renderer-adjacent (not
/// shader code) so tests can validate without a Metal device.
enum AttributeProjection {

    /// Apply `dim` (fg RGB × 0.5) and `reverse` (fg/bg swap) to a pair of
    /// already-resolved SIMD colors. Order: dim first, then reverse — matches
    /// xterm `charproc.c` / iTerm2 `iTermTextDrawingHelper`, where SGR 2
    /// (faint) darkens the foreground attribute, and SGR 7 (reverse) is the
    /// final swap of resolved fg/bg colors. Reverse-then-dim would dim the
    /// post-swap fg (i.e., the original bg), which doesn't match either
    /// reference implementation.
    ///
    /// Dim modifies the RGB channels (a darker color), not alpha — `dim` in
    /// xterm renders as a darker foreground color, not a translucent glyph
    /// blended onto whatever happens to be in the background slot.
    static func project(fg: SIMD4<Float>, bg: SIMD4<Float>, attributes: CellAttributes) -> (fg: SIMD4<Float>, bg: SIMD4<Float>) {
        var resultFg = fg
        var resultBg = bg
        if attributes.contains(.dim) {
            resultFg.x *= 0.5
            resultFg.y *= 0.5
            resultFg.z *= 0.5
        }
        if attributes.contains(.reverse) {
            swap(&resultFg, &resultBg)
        }
        return (resultFg, resultBg)
    }

    /// Pick which of the four atlases applies for a given attribute set.
    static func atlasVariant(for attributes: CellAttributes) -> GlyphAtlas.Variant {
        let bold = attributes.contains(.bold)
        let italic = attributes.contains(.italic)
        switch (bold, italic) {
        case (true, true):   return .boldItalic
        case (true, false):  return .bold
        case (false, true):  return .italic
        case (false, false): return .regular
        }
    }
}
```

- [ ] **Step 4: Tests for `AttributeProjection`**

Create `rTermTests/AttributeProjectionTests.swift`:

```swift
//
//  AttributeProjectionTests.swift
//  rTermTests
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

import simd
import Testing
@testable import rTerm
@testable import TermCore

@Suite("AttributeProjection")
struct AttributeProjectionTests {

    private let red:   SIMD4<Float> = SIMD4(1, 0, 0, 1)
    private let blue:  SIMD4<Float> = SIMD4(0, 0, 1, 1)
    private let green: SIMD4<Float> = SIMD4(0, 1, 0, 1)

    @Test("Empty attributes returns inputs unchanged")
    func test_empty_passthrough() {
        let (fg, bg) = AttributeProjection.project(fg: red, bg: blue, attributes: [])
        #expect(fg == red)
        #expect(bg == blue)
    }

    @Test("Reverse swaps fg and bg")
    func test_reverse_swap() {
        let (fg, bg) = AttributeProjection.project(fg: red, bg: blue, attributes: [.reverse])
        #expect(fg == blue)
        #expect(bg == red)
    }

    @Test("Dim multiplies fg RGB by 0.5 (alpha unchanged)")
    func test_dim_rgb() {
        let (fg, bg) = AttributeProjection.project(fg: red, bg: blue, attributes: [.dim])
        #expect(fg.x == 0.5 && fg.y == 0 && fg.z == 0,
                "Dim halves RGB channels — dim red → dark red")
        #expect(fg.w == 1, "Alpha unchanged")
        #expect(bg == blue)
    }

    @Test("Dim + reverse: dim fg first (RGB darken), then reverse (swap with bg)")
    func test_dim_then_reverse() {
        let (fg, bg) = AttributeProjection.project(fg: red, bg: blue, attributes: [.reverse, .dim])
        // After dim: fg = (0.5, 0, 0, 1), bg = (0, 0, 1, 1).
        // After reverse: fg = (0, 0, 1, 1), bg = (0.5, 0, 0, 1).
        #expect(fg == SIMD4<Float>(0, 0, 1, 1), "Reverse moves the original bg into the fg slot")
        #expect(bg == SIMD4<Float>(0.5, 0, 0, 1), "Dim darkens the original fg, which then swaps to bg")
    }

    @Test("Atlas variant: 4-way bold/italic mapping")
    func test_atlas_variant() {
        #expect(AttributeProjection.atlasVariant(for: []) == .regular)
        #expect(AttributeProjection.atlasVariant(for: [.bold]) == .bold)
        #expect(AttributeProjection.atlasVariant(for: [.italic]) == .italic)
        #expect(AttributeProjection.atlasVariant(for: [.bold, .italic]) == .boldItalic)
        #expect(AttributeProjection.atlasVariant(for: [.bold, .underline]) == .bold,
                "Non-atlas attributes don't affect variant selection")
    }
}
```

- [ ] **Step 5: Run AttributeProjection tests — expect pass after Step 3 lands**

Run: `xcodebuild -project rTerm.xcodeproj -scheme rTermTests test -only-testing rTermTests/AttributeProjectionTests`

Expected: 5 tests pass.

- [ ] **Step 6: Wire 4-way atlas selection + reverse + dim + strikethrough into `RenderCoordinator.draw(in:)`**

In `rTerm/RenderCoordinator.swift`, replace the per-cell loop's atlas selection and color resolution. Find:

```swift
let isBold = cell.style.attributes.contains(.bold)
let atlas = isBold ? boldAtlas : regularAtlas
```

Replace the entire per-cell vertex emission block with:

```swift
let variant = AttributeProjection.atlasVariant(for: cell.style.attributes)
let atlas: GlyphAtlas
switch variant {
case .regular:    atlas = regularAtlas
case .bold:       atlas = boldAtlas
case .italic:     atlas = italicAtlas
case .boldItalic: atlas = boldItalicAtlas
}
let uv = atlas.uvRect(for: cell.character)

let resolvedFg = ColorProjection.resolve(
    cell.style.foreground, role: .foreground,
    depth: depth, palette: palette, derivedPalette256: p256
).simdNormalized
let resolvedBg = ColorProjection.resolve(
    cell.style.background, role: .background,
    depth: depth, palette: palette, derivedPalette256: p256
).simdNormalized
let (fg, bg) = AttributeProjection.project(
    fg: resolvedFg,
    bg: resolvedBg,
    attributes: cell.style.attributes
)

let x0 = Float(col)     / Float(cols) * 2.0 - 1.0
let x1 = Float(col + 1) / Float(cols) * 2.0 - 1.0
let y0 = 1.0 - Float(row)     / Float(rows) * 2.0
let y1 = 1.0 - Float(row + 1) / Float(rows) * 2.0

switch variant {
case .regular:
    appendCellQuad(into: &regularVerts, x0: x0, x1: x1, y0: y0, y1: y1, uv: uv, fg: fg, bg: bg)
case .bold:
    appendCellQuad(into: &boldVerts,    x0: x0, x1: x1, y0: y0, y1: y1, uv: uv, fg: fg, bg: bg)
case .italic:
    appendCellQuad(into: &italicVerts,  x0: x0, x1: x1, y0: y0, y1: y1, uv: uv, fg: fg, bg: bg)
case .boldItalic:
    appendCellQuad(into: &boldItalicVerts, x0: x0, x1: x1, y0: y0, y1: y1, uv: uv, fg: fg, bg: bg)
}

if cell.style.attributes.contains(.underline) {
    let cellHeight = y0 - y1
    let thickness = cellHeight * 0.1
    let uy1 = y1 + thickness * 0.4
    let uy0 = uy1 + thickness
    appendOverlayQuad(into: &underlineVerts,
                      x0: x0, x1: x1, y0: uy0, y1: uy1,
                      color: fg)
}

if cell.style.attributes.contains(.strikethrough) {
    // Mid-height thin line.
    let cellHeight = y0 - y1
    let thickness = cellHeight * 0.08
    let mid = (y0 + y1) * 0.5
    let sy0 = mid + thickness * 0.5
    let sy1 = mid - thickness * 0.5
    appendOverlayQuad(into: &strikethroughVerts,
                      x0: x0, x1: x1, y0: sy0, y1: sy1,
                      color: fg)
}
```

Add the two new vertex-collection arrays alongside the existing `regularVerts` / `boldVerts` declarations (just above the per-cell loop):

```swift
var italicVerts = [Float]()
var boldItalicVerts = [Float]()
var strikethroughVerts = [Float]()
italicVerts.reserveCapacity(rows * cols * verticesPerCell * floatsPerCellVertex)
boldItalicVerts.reserveCapacity(rows * cols * verticesPerCell * floatsPerCellVertex)
strikethroughVerts.reserveCapacity(rows * cols * verticesPerCell * floatsPerOverlayVertex)
```

Add italic / bold-italic draw passes alongside the existing regular / bold passes:

```swift
if !italicVerts.isEmpty {
    let buf = device.makeBuffer(
        bytes: italicVerts,
        length: italicVerts.count * MemoryLayout<Float>.size,
        options: .storageModeShared
    )
    if let buf {
        renderEncoder.setVertexBuffer(buf, offset: 0, index: 0)
        renderEncoder.setFragmentTexture(italicAtlas.texture, index: 0)
        renderEncoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: italicVerts.count / floatsPerCellVertex
        )
    }
}

if !boldItalicVerts.isEmpty {
    let buf = device.makeBuffer(
        bytes: boldItalicVerts,
        length: boldItalicVerts.count * MemoryLayout<Float>.size,
        options: .storageModeShared
    )
    if let buf {
        renderEncoder.setVertexBuffer(buf, offset: 0, index: 0)
        renderEncoder.setFragmentTexture(boldItalicAtlas.texture, index: 0)
        renderEncoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: boldItalicVerts.count / floatsPerCellVertex
        )
    }
}
```

Add a strikethrough overlay pass parallel to the existing underline pass:

```swift
if !strikethroughVerts.isEmpty {
    renderEncoder.setRenderPipelineState(overlayPipelineState)
    let buf = device.makeBuffer(
        bytes: strikethroughVerts,
        length: strikethroughVerts.count * MemoryLayout<Float>.size,
        options: .storageModeShared
    )
    if let buf {
        renderEncoder.setVertexBuffer(buf, offset: 0, index: 0)
        renderEncoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: strikethroughVerts.count / floatsPerOverlayVertex
        )
    }
}
```

- [ ] **Step 7: Wire bell observer (rate-limited NSSound.beep on bellCount delta)**

Add stored properties to `RenderCoordinator`:

```swift
/// Last bell count we saw on a snapshot. When the snapshot's bellCount
/// exceeds this AND the rate limiter allows, we play the system beep
/// and update.
private var lastSeenBellCount: UInt64 = 0

/// Wall-clock timestamp of the most recent NSSound.beep() call. Bells
/// arriving within `bellMinInterval` seconds of the last beep collapse
/// silently — protects against runaway BEL spam (e.g. `yes $'\a'` or a
/// program looping on permission errors with bells).
private var lastBeepAt: TimeInterval = 0
private let bellMinInterval: TimeInterval = 0.2
```

In `draw(in view:)`, after the snapshot read (`let snapshot = screenModel.latestSnapshot()`) add:

```swift
if snapshot.bellCount > lastSeenBellCount {
    // Always advance lastSeenBellCount so we don't backlog beeps when
    // multiple BELs arrive between draw frames.
    lastSeenBellCount = snapshot.bellCount
    let now = ProcessInfo.processInfo.systemUptime
    if now - lastBeepAt > bellMinInterval {
        lastBeepAt = now
        NSSound.beep()
    }
}
```

`NSSound` requires AppKit; `RenderCoordinator` already imports MetalKit which transitively pulls AppKit, but make the import explicit:

```swift
import AppKit
```

at the top of the file (alongside the existing `import MetalKit` and `import TermCore`).

- [ ] **Step 8: Run all tests + clean build**

Run: `xcodebuild -project rTerm.xcodeproj -scheme rTermTests test`

Expected: all tests green.

Run: `xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build`

Expected: clean build with no warnings.

Manual smoke test: launch the app; in the shell, run:

```bash
printf '\033[3;31mitalic red\033[0m\n'
printf '\033[1;3mbold italic\033[0m\n'
printf '\033[2;33mdim yellow\033[0m\n'
printf '\033[7mreversed\033[0m\n'
printf '\033[9mstruck-through\033[0m\n'
printf '\007'   # bell — expect macOS system beep
```

All five styles render visibly different from the default. Bell triggers a single beep.

- [ ] **Step 9: Commit**

```bash
git add rTerm/GlyphAtlas.swift rTerm/RenderCoordinator.swift rTerm/AttributeProjection.swift \
        rTermTests/AttributeProjectionTests.swift
git commit -m "renderer: italic + bold-italic + dim + reverse + strikethrough + bell (Phase 2 T9)

GlyphAtlas: .italic and .boldItalic Variant cases activated. Italic
glyphs use NSFontDescriptor.SymbolicTraits.italic on the monospaced
system font (synthesized oblique fallback when the font lacks a true
italic master). When the descriptor lookup fails entirely (rare; very
old SF Mono builds), GlyphAtlas logs a one-time warning and falls
back to the regular font so italic-attributed cells render upright.

RenderCoordinator: builds all four atlases eagerly at init (~20 ms
total). Per-cell loop uses AttributeProjection.atlasVariant to pick
one of four vertex buffers; each gets its own draw call with the
matching atlas texture.

AttributeProjection (new file, fully tested): pure helpers for atlas
selection + dim RGB darken + reverse swap. Composition order matches
xterm/iTerm2: dim darkens fg RGB first (alpha unchanged), reverse
swaps fg/bg as the final step.

dim: fg.xyz × 0.5 (RGB darken, not alpha translucency).
reverse: fg/bg swap. Dim-then-reverse composes to 'darken original
fg, then swap into bg slot' — matches xterm charproc.c.
strikethrough: thin overlay quad at cell mid-height. Same overlay
pipeline as underline; takes its color from the (post-projection) fg.

bell: snapshot.bellCount delta drives NSSound.beep(), rate-limited to
one beep per 200 ms. Advances lastSeenBellCount unconditionally so
bursts between draw frames don't backlog. Tracked on RenderCoordinator's
MainActor; reads the snapshot's nonisolated lock-protected bellCount
on every draw."
```

---

## Task 10: Scrollback UI — `ScrollViewState` + scroll wheel + PgUp/PgDn intercept + history-aware draw

**Spec reference:** §8 Phase 2 ("Scrollback UI: scroll wheel, PgUp/PgDn, scroll-to-bottom-on-new-output").

**Goal:** Wire user-driven scrollback browsing on top of the history surface T6 published. State lives in a standalone `ScrollViewState` value type (testable without Metal). When scroll offset > 0, the renderer composites: top `scrollOffset` rows from history + bottom `(rows - scrollOffset)` rows from the live grid. PgUp / PgDn keystrokes are intercepted in `TerminalMTKView.keyDown` *before* the encoder when scrollback is the user's intent (we use the simple rule: PgUp / PgDn always drive scrollback in main buffer when there's history; in alt buffer we never scroll back, sequence goes through). Auto-anchoring: when scrollOffset > 0 and the snapshot's history grew since last frame, increment scrollOffset by the delta so the same content stays at the same screen row.

**Files:**
- Create: `rTerm/ScrollViewState.swift` (value type — pure logic, testable)
- Create: `rTermTests/ScrollViewStateTests.swift`
- Modify: `rTerm/RenderCoordinator.swift` (state field, history-aware row source, anchor-on-history-grow logic)
- Modify: `rTerm/TermView.swift` (TerminalMTKView.scrollWheel(with:), keyDown intercept of PgUp/PgDn)

### Steps

- [ ] **Step 1: Create `ScrollViewState`**

Create `rTerm/ScrollViewState.swift`:

```swift
//
//  ScrollViewState.swift
//  rTerm
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

import Foundation

/// Value type holding the renderer's scrollback view state. Pure logic;
/// testable without Metal or AppKit.
///
/// `offset` counts rows scrolled back from the bottom of the live grid.
/// `offset == 0` means the user is viewing live output; `offset > 0` means
/// the user has scrolled into history.
///
/// `lastSeenHistoryCount` is what `historyCount` was the last time the
/// renderer drew. When `historyCount` grows by `delta` while `offset > 0`,
/// the renderer increments `offset` by `delta` (clamped) so the same row
/// content stays at the same screen position — the "anchor" behavior.
///
/// `wheelAccumulator` holds the fractional row delta from sub-row trackpad
/// gestures so small precise scrolls don't all round to zero. Trackpads
/// emit dozens of tiny deltas per gesture; without accumulation each one
/// rounds to 0 and the view feels stuck.
struct ScrollViewState: Sendable, Equatable {

    var offset: Int = 0
    var lastSeenHistoryCount: Int = 0
    var wheelAccumulator: CGFloat = 0

    /// Reconcile against a fresh history count. Returns `true` if `offset`
    /// changed (renderer should treat the frame as needing redraw).
    @discardableResult
    mutating func reconcile(historyCount: Int) -> Bool {
        guard offset > 0 else {
            lastSeenHistoryCount = historyCount
            return false
        }
        let delta = historyCount - lastSeenHistoryCount
        lastSeenHistoryCount = historyCount
        guard delta > 0 else { return false }
        let newOffset = min(historyCount, offset + delta)
        let changed = newOffset != offset
        offset = newOffset
        return changed
    }

    /// Apply a wheel delta. Caller passes a "scroll-back-positive" delta —
    /// `TermView.scrollWheel(with:)` is responsible for normalizing AppKit's
    /// raw `event.scrollingDeltaY` (which depends on natural-scroll setting)
    /// into this convention before calling here.
    ///
    /// `historyCount` is the upper bound; `rowsPerNotch` controls scroll speed.
    /// Sub-row deltas accumulate in `wheelAccumulator` so trackpad small
    /// gestures move the view smoothly instead of feeling sticky.
    mutating func handleWheel(rowsBack: CGFloat, historyCount: Int) {
        wheelAccumulator += rowsBack
        let rowDelta = Int(wheelAccumulator.rounded(.towardZero))
        wheelAccumulator -= CGFloat(rowDelta)
        guard rowDelta != 0 else { return }
        offset = max(0, min(historyCount, offset + rowDelta))
    }

    /// Page Up: scroll back by `pageRows - 1` rows. Returns whether offset changed.
    @discardableResult
    mutating func pageUp(pageRows: Int, historyCount: Int) -> Bool {
        let target = min(historyCount, offset + max(1, pageRows - 1))
        let changed = target != offset
        offset = target
        return changed
    }

    /// Page Down: scroll forward by `pageRows - 1` rows. Returns whether offset changed.
    @discardableResult
    mutating func pageDown(pageRows: Int) -> Bool {
        let target = max(0, offset - max(1, pageRows - 1))
        let changed = target != offset
        offset = target
        return changed
    }

    /// Force scroll-to-bottom (e.g., user typed input). Resets the accumulator
    /// so a subsequent gesture starts fresh.
    mutating func scrollToBottom() {
        offset = 0
        wheelAccumulator = 0
    }
}
```

- [ ] **Step 2: Tests for `ScrollViewState`**

Create `rTermTests/ScrollViewStateTests.swift`:

```swift
//
//  ScrollViewStateTests.swift
//  rTermTests
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

import Foundation
import Testing
@testable import rTerm

@Suite("ScrollViewState")
struct ScrollViewStateTests {

    @Test("Default state: offset 0, lastSeenHistoryCount 0")
    func test_default() {
        let s = ScrollViewState()
        #expect(s.offset == 0)
        #expect(s.lastSeenHistoryCount == 0)
    }

    @Test("Reconcile at offset 0 just tracks history count, returns false")
    func test_reconcile_at_bottom() {
        var s = ScrollViewState()
        let changed = s.reconcile(historyCount: 50)
        #expect(changed == false)
        #expect(s.offset == 0)
        #expect(s.lastSeenHistoryCount == 50)
    }

    @Test("Reconcile while scrolled back anchors to history-grow delta")
    func test_reconcile_anchor() {
        var s = ScrollViewState(offset: 10, lastSeenHistoryCount: 100)
        let changed = s.reconcile(historyCount: 105)
        #expect(changed == true)
        #expect(s.offset == 15, "offset += delta to keep the same row anchored")
        #expect(s.lastSeenHistoryCount == 105)
    }

    @Test("Reconcile clamps offset at historyCount")
    func test_reconcile_clamp() {
        var s = ScrollViewState(offset: 95, lastSeenHistoryCount: 100)
        s.reconcile(historyCount: 110)
        #expect(s.offset == 105)   // 95 + 10 = 105, well under 110
        s.reconcile(historyCount: 108)   // shrunk? edge case — delta is -2; offset unchanged.
        #expect(s.offset == 105)
    }

    @Test("Wheel: positive rowsBack scrolls back, clamps at historyCount")
    func test_wheel_positive() {
        var s = ScrollViewState()
        s.handleWheel(rowsBack: 9, historyCount: 50)
        #expect(s.offset == 9)
        s.handleWheel(rowsBack: 1000, historyCount: 50)
        #expect(s.offset == 50, "Clamps at historyCount")
    }

    @Test("Wheel: negative rowsBack scrolls forward, clamps at 0")
    func test_wheel_negative() {
        var s = ScrollViewState(offset: 10, lastSeenHistoryCount: 100, wheelAccumulator: 0)
        s.handleWheel(rowsBack: -9, historyCount: 100)
        #expect(s.offset == 1)
        s.handleWheel(rowsBack: -1000, historyCount: 100)
        #expect(s.offset == 0, "Clamps at 0")
    }

    @Test("Wheel: sub-row deltas accumulate instead of rounding to zero")
    func test_wheel_fractional_accumulator() {
        var s = ScrollViewState()
        // Three 0.4-row deltas should accumulate to 1.2 → emits 1 row, leaves 0.2.
        s.handleWheel(rowsBack: 0.4, historyCount: 100)
        #expect(s.offset == 0, "0.4 alone rounds-to-zero towardZero")
        s.handleWheel(rowsBack: 0.4, historyCount: 100)
        #expect(s.offset == 0, "0.8 still under 1 row")
        s.handleWheel(rowsBack: 0.4, historyCount: 100)
        #expect(s.offset == 1, "1.2 emits 1 row, residue 0.2 stays in accumulator")
    }

    @Test("scrollToBottom resets offset and accumulator")
    func test_scroll_to_bottom() {
        var s = ScrollViewState(offset: 50, lastSeenHistoryCount: 100, wheelAccumulator: 0.7)
        s.scrollToBottom()
        #expect(s.offset == 0)
        #expect(s.wheelAccumulator == 0)
    }

    @Test("Page up scrolls by pageRows - 1, clamps at historyCount")
    func test_page_up() {
        var s = ScrollViewState()
        let changed = s.pageUp(pageRows: 24, historyCount: 100)
        #expect(changed == true)
        #expect(s.offset == 23)
    }

    @Test("Page down scrolls forward by pageRows - 1, clamps at 0")
    func test_page_down() {
        var s = ScrollViewState(offset: 30, lastSeenHistoryCount: 100, wheelAccumulator: 0)
        s.pageDown(pageRows: 24)
        #expect(s.offset == 7)
        s.pageDown(pageRows: 24)
        #expect(s.offset == 0)
    }
}
```

- [ ] **Step 3: Run tests — expect pass**

Run: `xcodebuild -project rTerm.xcodeproj -scheme rTermTests test -only-testing rTermTests/ScrollViewStateTests`

Expected: 9 tests pass.

- [ ] **Step 4: Wire `ScrollViewState` into `RenderCoordinator`**

In `rTerm/RenderCoordinator.swift`:

1. Add the state field:

```swift
/// Scrollback view state. Updated by scrollWheel + PgUp/PgDn handlers in
/// TerminalMTKView. Reconciled against history growth at the start of each
/// draw so anchored-to-history rows stay put when new output arrives.
private(set) var scrollState = ScrollViewState()
```

2. Add scroll-handler methods (called from `TermView` glue):

```swift
/// Apply a scroll-wheel delta. `rowsBack` is positive when the user
/// gestures into history (caller normalizes natural-scroll direction).
/// `view` is needed only for `view.setNeedsDisplay`.
func handleScrollWheel(rowsBack: CGFloat, view: NSView) {
    let history = screenModel.latestHistoryTail()
    scrollState.handleWheel(rowsBack: rowsBack, historyCount: history.count)
    view.needsDisplay = true
}

/// Apply Page Up. Returns `true` if scroll offset changed.
@discardableResult
func handlePageUp(view: NSView) -> Bool {
    let history = screenModel.latestHistoryTail()
    let pageRows = screenModel.latestSnapshot().rows
    let changed = scrollState.pageUp(pageRows: pageRows, historyCount: history.count)
    if changed { view.needsDisplay = true }
    return changed
}

@discardableResult
func handlePageDown(view: NSView) -> Bool {
    let pageRows = screenModel.latestSnapshot().rows
    let changed = scrollState.pageDown(pageRows: pageRows)
    if changed { view.needsDisplay = true }
    return changed
}

/// Force scroll-to-bottom — called when user types into the active session.
func scrollToBottom() {
    scrollState.scrollToBottom()
}
```

3. In `draw(in view:)`, immediately after `let snapshot = screenModel.latestSnapshot()`, add the history reconciliation and override the per-row source:

```swift
let history = screenModel.latestHistoryTail()
scrollState.reconcile(historyCount: history.count)

let rows = snapshot.rows
let cols = snapshot.cols
let liveCells = snapshot.activeCells
let scrollOffset = min(scrollState.offset, history.count)

// `cellAt(row:col:)` returns the cell to render at on-screen position
// (row, col). When scrollback is active, the top `scrollOffset` rows come
// from history (chronological tail-relative), and the bottom rows come
// from the live grid shifted upward. The cursor is suppressed when
// scrolled back so it doesn't appear in a confusing position.
let historyStart = history.count - scrollOffset
@inline(__always) func cellAt(row: Int, col: Int) -> Cell {
    if row < scrollOffset {
        let historyRowIdx = historyStart + row
        let historyRow = history[historyRowIdx]
        guard col < historyRow.count else { return .empty }
        return historyRow[col]
    } else {
        let liveRow = row - scrollOffset
        return liveCells[liveRow * cols + col]
    }
}
```

4. Replace the per-cell read inside the loop:

```swift
// REMOVE:
let cell = snapshot[row, col]
// REPLACE WITH:
let cell = cellAt(row: row, col: col)
```

5. Suppress the cursor draw when scrolled back. Replace the `if snapshot.cursorVisible {` block with:

```swift
if snapshot.cursorVisible && scrollOffset == 0 {
    // ... existing cursor quad emission unchanged.
}
```

- [ ] **Step 5: Wire `scrollWheel(with:)` and PgUp/PgDn intercept on `TerminalMTKView`**

In `rTerm/TermView.swift`, modify `TerminalMTKView`:

1. Add a closure for scroll events handed by SwiftUI bridge:

```swift
/// Called when the user scrolls inside the view (wheel, trackpad).
var onScrollWheel: ((CGFloat) -> Void)?

/// Page Up / Page Down handlers — return `true` if the gesture was consumed
/// for scrollback navigation, `false` if it should fall through to the encoder.
var onPageUp:   (() -> Bool)?
var onPageDown: (() -> Bool)?

/// Called when the user types — RenderCoordinator scrolls back to the
/// bottom of the live grid before the input is sent.
var onActiveInput: (() -> Void)?
```

2. Add a `scrollWheel(with:)` override:

```swift
override func scrollWheel(with event: NSEvent) {
    // event.scrollingDeltaY is gesture-aware: with natural scrolling enabled
    // (macOS default), a two-finger trackpad gesture *up* gives positive
    // scrollingDeltaY — which matches "scroll back into history" intent.
    // With natural scrolling disabled (some Mighty Mouse users), the sign
    // flips to match physical wheel rotation. We pass the value through
    // unchanged; the user's "natural" preference governs both directions.
    let deltaY = event.scrollingDeltaY
    // Convert raw delta into row units. Trackpad emits precise sub-point
    // deltas (typically ~1-3 per gesture step); mouse wheel emits coarse
    // ~1.0 notches. ScrollViewState's accumulator aggregates fractions
    // across calls so trackpad gestures don't all round to zero.
    let rowsPerUnit: CGFloat = event.hasPreciseScrollingDeltas ? 0.05 : 1.0
    onScrollWheel?(deltaY * rowsPerUnit)
}
```

3. In `keyDown(with:)`, intercept PgUp / PgDn before the encoder. PgUp = keyCode 116, PgDn = keyCode 121:

```swift
override func keyDown(with event: NSEvent) {
    // Scrollback navigation hooks — Page Up / Page Down drive the
    // RenderCoordinator's scroll state when we're in the main buffer.
    // The hooks return true when they consume the event; false means
    // pass through to the encoder (and on to the shell).
    switch event.keyCode {
    case 116:
        if let h = onPageUp, h() { return }
    case 121:
        if let h = onPageDown, h() { return }
    default:
        break
    }
    let mode = cursorKeyModeProvider?() ?? .normal
    let encoder = KeyEncoder()
    if let data = encoder.encode(event, cursorKeyMode: mode) {
        onActiveInput?()
        log.debug("keyDown: keyCode=\(event.keyCode), encoded \(data.count) bytes")
        onKeyInput?(data)
    } else {
        log.debug("keyDown: keyCode=\(event.keyCode), unhandled")
    }
}
```

4. Wire the new closures from `TermView.makeNSView` / `updateNSView`:

```swift
func makeNSView(context: Context) -> TerminalMTKView {
    let coordinator = context.coordinator
    let view = TerminalMTKView(frame: .zero, device: coordinator.device)
    view.delegate = coordinator
    view.preferredFramesPerSecond = 60
    view.colorPixelFormat = .bgra8Unorm
    view.clearColor = clearColor(for: settings.palette.defaultBackground)
    view.onKeyInput = onInput
    view.onPaste = onPaste
    let model = screenModel
    view.cursorKeyModeProvider = {
        model.latestSnapshot().cursorKeyApplication ? .application : .normal
    }
    view.onScrollWheel = { [weak view, weak coordinator] rowsBack in
        guard let view, let coordinator else { return }
        coordinator.handleScrollWheel(rowsBack: rowsBack, view: view)
    }
    view.onPageUp = { [weak view, weak coordinator] in
        guard let view, let coordinator else { return false }
        // Only consume PgUp for scrollback when there IS history and we're on main.
        let snap = coordinator.screenModelForView.latestSnapshot()
        guard snap.activeBuffer == .main else { return false }
        let history = coordinator.screenModelForView.latestHistoryTail()
        guard history.count > 0 else { return false }
        return coordinator.handlePageUp(view: view)
    }
    view.onPageDown = { [weak view, weak coordinator] in
        guard let view, let coordinator else { return false }
        let snap = coordinator.screenModelForView.latestSnapshot()
        guard snap.activeBuffer == .main else { return false }
        guard coordinator.scrollState.offset > 0 else { return false }
        return coordinator.handlePageDown(view: view)
    }
    view.onActiveInput = { [weak coordinator] in
        coordinator?.scrollToBottom()
    }
    return view
}

func updateNSView(_ nsView: TerminalMTKView, context: Context) {
    nsView.onKeyInput = onInput
    nsView.onPaste = onPaste
    nsView.clearColor = clearColor(for: settings.palette.defaultBackground)
    let model = screenModel
    nsView.cursorKeyModeProvider = {
        model.latestSnapshot().cursorKeyApplication ? .application : .normal
    }
}
```

`coordinator.screenModelForView` is a small package-visible accessor on `RenderCoordinator` so the closure doesn't capture `screenModel` redundantly. Add to `RenderCoordinator`:

```swift
/// Same screenModel passed to init — exposed so TermView's PgUp/PgDn closures
/// can read snapshot/history without capturing the SwiftUI state separately.
var screenModelForView: ScreenModel { screenModel }
```

- [ ] **Step 6: Run all tests + clean build + manual smoke test**

Run: `xcodebuild -project rTerm.xcodeproj -scheme rTermTests test`

Expected: all green.

Run: `xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build`

Expected: clean build.

Manual smoke:

1. Launch the app. Run `seq 1 200` in the shell. Wheel-scroll up — earlier numbers reappear from history. Wheel-scroll down — return to bottom.
2. Verify scroll direction with **both natural scrolling on and off** (System Settings → Trackpad → Scroll & Zoom → "Natural scrolling"). Two-finger trackpad gesture upward should reveal older history under both settings (the system's natural-scroll setting governs the gesture-to-direction mapping; we pass `event.scrollingDeltaY` through unchanged).
3. Press Page Up — scroll one screen back. Press Page Down — return one screen forward.
4. Type any character while scrolled back — view snaps back to bottom, the typed character appears.
5. Run `vim` — alt screen activates. Try PgUp — vim consumes it as expected (PgUp goes through to the shell because alt buffer is active and the `onPageUp` handler returns false).
6. Run `seq 1 50000` — scroll wheel browses the most recent ~10K rows of history (capacity), older rows evicted.

- [ ] **Step 7: Commit**

```bash
git add rTerm/ScrollViewState.swift rTerm/RenderCoordinator.swift rTerm/TermView.swift \
        rTermTests/ScrollViewStateTests.swift
git commit -m "ui: scrollback view (wheel + PgUp/PgDn + auto-anchor) (Phase 2 T10)

ScrollViewState (new file, fully tested): pure value-type holding
- offset (rows scrolled back from live grid)
- lastSeenHistoryCount (for anchor delta calc)
- wheelAccumulator (sub-row trackpad delta accumulation)

API:
- reconcile(historyCount:) — call at draw-time; auto-increments offset
  by history-grow delta when offset > 0 (anchor behavior)
- handleWheel(rowsBack:historyCount:) — wheel input; caller normalizes
  natural-scroll direction; sub-row gestures accumulate via the
  fractional accumulator instead of all rounding to zero
- pageUp/pageDown(pageRows:historyCount:) — keyboard input
- scrollToBottom() — user typed, snap to live (resets accumulator too)

RenderCoordinator:
- scrollState: ScrollViewState
- handleScrollWheel(rowsBack:) / handlePageUp / handlePageDown / scrollToBottom
- draw() reconciles history count, then renders top scrollOffset rows
  from history + bottom (rows-scrollOffset) rows from live grid
- cursor draw suppressed while scrolled back (avoids confusing position)

TerminalMTKView:
- scrollWheel(with:) override → uses event.scrollingDeltaY (gesture-aware,
  honors natural-scroll setting); converts precise vs coarse deltas at
  different rates (0.05 rows/point for trackpad; 1.0 row/notch for wheel);
  passes through to onScrollWheel(rowsBack:)
- keyDown intercepts PgUp/PgDn → onPageUp/onPageDown returning Bool;
  consumed for scrollback only when (activeBuffer == .main && history > 0)
  — alt-screen apps still see PgUp/PgDn passed through
- onActiveInput hook fires before any input goes to the encoder so the
  view snaps back to live when the user types

Behavior matches a typical xterm/iTerm2 scrollback experience under
both natural and reverse scroll preferences."
```

---

## Plan complete

After Task 10: Phase 2 is done. `xcodebuild … test` green; the app launches; full TUI workflow works:

- vim / less / htop / mc / tmux render correctly with alt-screen swap, status lines under DECSTBM, italic + bold-italic + dim + reverse + strikethrough text, proper save/restore of cursor across sessions.
- Arrow keys / Home / End / PgUp / PgDn behave correctly under DECCKM (vim navigation works).
- Bracketed paste prevents shell mis-interpretation when pasting code.
- Bell rings.
- Scrollback survives detach/reattach (up to 500 rows over the wire on attach; up to 10K rows in-memory locally).
- Wheel + PgUp/PgDn drive scrollback browsing with auto-anchor.

**Carry-forward for Phase 3** (per spec §8 Phase 3, Appendix A):

- OSC 8 hyperlinks (`CellStyle.hyperlink: Hyperlink?`)
- OSC 52 clipboard (sandbox + consent)
- Blink animation (global timer uniform; shader toggle)
- Unicode atlas beyond ASCII (LRU + CoreText fallback)
- Palette chooser UI (presets + custom import)
- `CellStyle` flyweight (`styleID: UInt16` → ~50% scrollback memory drop)
- Per-row dirty tracking
- `DaemonRequest.fetchHistory(sessionID:, rowRange:)` RPC
- `Span<Cell>` at internal boundaries (profile-driven)
- SGR small-buffer `SGRRun` (avoids `[SGRAttribute]` allocation per SGR sequence)
- Live `ScreenModel` resize (rows/cols change while a session is active)

## Self-review notes

- **Spec coverage:** every Phase 2 in-scope bullet from spec §8 has a corresponding task —
  - DEC private modes (DECAWM/DECTCEM/DECCKM/bracketed paste) → T1 (parser) + T3 (model) + T7 (KeyEncoder hook) + T8 (paste path)
  - Alt screen (47/1047/1049) + dual-buffer ScreenModel → T2 + T4
  - DECSTBM + ESC 7/8 + CSI s/u + saveCursor 1048 → T1 (parser ESC 7/8) + T2 (per-buffer savedCursor) + T4 (1048) + T5 (DECSTBM)
  - Scrollback history → T6
  - Snapshot recentHistory on attach → T6
  - Scrollback UI → T10
  - Renderer italic/bold-italic/dim/reverse/strikethrough → T9 ✓

- **Placeholder scan:** every step has concrete code, exact commands, expected outputs. No `TBD`, no "TODO", no "implement later". The renderer task notes that runtime visual verification requires a manual smoke test (Metal pixel correctness isn't unit-testable) and lists the exact `printf` sequences to check.

- **Type consistency:** `Buffer` (T2), `ScrollRegion` (T2/T5), `TerminalModes` (T3), `ScrollbackHistory` + `ScrollbackHistory.Row` (T6), `CursorKeyMode` (T7), `AttributeProjection` + `GlyphAtlas.Variant.italic/.boldItalic` (T9), `ScrollViewState` (T10). `mutateActive`, `cellAt`, `latestHistoryTail()`, `cursorKeyModeProvider`, `scrollState`, `screenModelForView` — all consistent across tasks. `ScreenSnapshot` field set extends monotonically (T3 adds three; later tasks consume them).

- **Test targets:** `TermCoreTests` for model-side tests; `rTermTests` for app-side (KeyEncoder, AttributeProjection, BracketedPaste, ScrollViewState). Swift Testing throughout per project convention.

- **One commit per task** — 10 commits total.

---

**Plan complete and saved to `docs/superpowers/plans/2026-05-01-control-chars-phase2.md`.**

Two execution options:

1. **Subagent-Driven (recommended)** — controller dispatches a fresh implementer per task, runs `agentic:xcode-build-reporter` after each commit, then dispatches reviewers. Matches the Phase 1 cadence.

2. **Inline Execution** — execute tasks in this session using `superpowers:executing-plans`, batch execution with checkpoints for review.

Let me know which approach.








