# Control Characters & Escape Sequence Handling — Design

- **Date:** 2026-04-30 (revised 2026-05-02 after Phase 2 landing)
- **Status:** Phase 1 delivered (main). Phase 2 delivered (branch `phase-2-control-chars`, PR #5). Phase 3 scope revised and ready for planning.
- **Exploration:** [`docs/explorations/2026-04-30-control-characters.md`](../../explorations/2026-04-30-control-characters.md)
- **Phase 2 research:** `docs/research/2026-05-01-phase2-final-review-empirical-findings.md`, `…-branch-efficiency-…`, `…-branch-simplify-reuse-…`, `…-branch-simplify-quality-…`
- **Phase 3 spec review:** `docs/research/2026-05-02-phase3-spec-review-empirical-findings.md`

## Summary

rTerm's original parser recognized a narrow subset of ASCII control characters and silently discarded every escape sequence — including `ESC` (0x1B) itself. This spec laid out the architecture for full ANSI/VT positional and control-character handling: a Paul Williams VT state machine in the parser, a grouped-enum event vocabulary covering CSI / OSC / C0, dual-buffer `ScreenModel` with alt-screen support, truecolor SGR with render-time depth projection, OSC 0/2 window title, DEC private modes, DECSTBM scroll regions, and bounded scrollback. Implementation is staged across three phases; the architecture has supported the end state from day one. **Phase 1 (MVP) and Phase 2 (full TUI + scrollback + bell) are delivered.** Phase 3 is revised below: it covers OSC 8 hyperlinks, OSC 52 clipboard (set path), DECSCUSR cursor shape, blink, DA1/DA2/CPR device reports, DECOM/DECCOLM, palette chooser UI, plus a mandatory engineering-hygiene track paying down Phase 2 hot-path and API-surface debt.

## Decisions summary

| # | Decision | Choice |
|---|----------|--------|
| 1 | Scope | Wide (C) — positional + SGR + modes + alt screen + scroll regions + scrollback, staged implementation |
| 2 | Parser architecture | Hybrid — Paul Williams VT state machine internally, structured events externally |
| 3 | SGR richness | Truecolor fidelity in parser/model; renderer projects to user-chosen `ColorDepth` (16 / 256 / truecolor), live-switchable |
| 4 | Color mode projection | Renderer-only — parser/model always store max fidelity; mode swap never migrates data |
| 5 | Event enum structure | Grouped nested — `TerminalEvent.{printable, c0, csi, osc, unrecognized}` |
| 6 | Alt-screen architecture | Dual-buffer `ScreenModel` — single actor owns both grids + shared pen/modes |
| 7 | Scrollback | In scope; main-buffer only; `CircularCollection<Row>` in `ScreenModel`; bounded recent-history in snapshot |
| 8 | OSC scope | Phase 1: OSC 0/2 (window title). Phase 3: OSC 8 hyperlinks + OSC 52 clipboard (set path). Parser passthrough `osc(.unknown(...))` kept as stable seam. |

## §1 — Architecture overview

Pipeline unchanged at 10,000 ft:

```
PTY bytes → TerminalParser → [TerminalEvent] → ScreenModel → ScreenSnapshot → Renderer (Metal)
```

Three internal seams change:

1. **`TerminalParser`** gains an internal Paul Williams VT state machine (ground / escape / CSI-entry / CSI-param / CSI-intermediate / OSC-string / DCS / ignore states). Public API still just returns `[TerminalEvent]`. UTF-8 buffering (already robust) stays as the ground-state text path.

2. **`TerminalEvent`** becomes a grouped nested enum. Five top-level cases: `.printable`, `.c0`, `.csi`, `.osc`, `.unrecognized`. Rich payloads (e.g., `.csi(.cursorPosition(row, col))`, `.csi(.sgr([.foreground(.rgb(255,128,0)), .bold]))`). SGR lives inside `CSICommand` — structurally it's just CSI with final byte `m`.

3. **`ScreenModel`** grows from "grid + cursor + scroll" to "grid + alt-grid + pen + modes + saved-cursor + scroll-region + bounded history + window title". Still a single actor with the custom serial-queue executor — preserves `assumeIsolated` from the daemon read path.

Two new companion types:

- **`TerminalColor`** — enum: `.default / .ansi16(UInt8) / .palette256(UInt8) / .rgb(UInt8, UInt8, UInt8)`. Always stored at max fidelity.
- **`CellStyle`** — value type with `fg`, `bg`, `attributes: CellAttributes` (OptionSet); embedded in `Cell`.

Daemon wire protocol stays structurally the same. `ScreenSnapshot` grows richer (styled cells, window title, active buffer, mode flags, bounded history, version counter). Live push remains raw PTY bytes; client's mirror parses independently.

Rendering: parser and model are color-depth-agnostic (always truecolor). A render-time `ColorDepth × TerminalPalette` projection turns stored colors into pixels. User setting, live-switchable, no data migration.

Three implementation phases (§8): Phase 1 (MVP parser + cursor/erase + SGR + colors — **delivered on `main`**), Phase 2 (modes + alt screen + scrollback + bell — **delivered on branch `phase-2-control-chars`**), Phase 3 (OSC 8 + OSC 52 + DECSCUSR + blink + terminal-ID responses + hygiene track — in planning).

## §2 — Parser

### Internal state machine

Adopt Paul Williams' VT state machine. Core states:

- **GROUND** — printable text, C0 controls. Existing UTF-8 lead/continuation logic lives here unchanged.
- **ESCAPE** — entered on `0x1B`. Dispatches based on next byte: `[` → CSI, `]` → OSC, `P` → DCS, single-char escapes handled inline.
- **CSI_ENTRY → CSI_PARAM → CSI_INTERMEDIATE → dispatch** — collect `;`/`:`-separated numeric params and intermediate bytes; final byte triggers emit.
- **OSC_STRING** — collect characters until `ESC \` (ST) or `BEL`.
- **CSI_IGNORE / DCS_IGNORE** — consume-and-drop after malformed sub-sequences, per Williams.

**Cross-chunk buffering.** State persists across `parse(_:)` calls, exactly like today's `utf8Buffer`. A CSI split across three PTY reads stays coherent. Every sequence survives stream fragmentation.

**Cancellation.** CAN (`0x18`) and SUB (`0x1A`) reset to GROUND mid-sequence. Without this, a shell emitting `printf "\033[31m"` followed by ctrl-C would corrupt terminal state.

### Public API — unchanged shape

```swift
public struct TerminalParser: Sendable {
    public init()
    public mutating func parse(_ data: Data) -> [TerminalEvent]
}
```

Internally:

- `state: VTState` — enum with associated values (params accumulator, intermediates, OSC string)
- `utf8Buffer: [UInt8]` — only active in GROUND

Value-typed, Sendable, no I/O — current ergonomics preserved.

**Ownership rule.** `TerminalParser` is value-typed; each copy carries its own in-flight state buffer (partial UTF-8, collected CSI params, OSC string). Callers must own **one instance per PTY stream** — e.g., `rtermd/Session.swift`'s `var parser: TerminalParser`, mutated only inside the owning actor's isolation (or the daemon queue's `assumeIsolated` block). Copying mid-stream duplicates and silently diverges buffered bytes.

### Parser-level bounds

To keep adversarial output from bloating daemon memory:

- **OSC string cap:** `OSC_STRING` accumulates up to 4 KB; oversize payloads emit `.osc(.unknown(ps:, pt: <truncated>))` and drop remaining bytes until the terminator.
- **CSI param cap:** accept up to 16 parameters; extra params emit `.csi(.unknown(...))` with the collected prefix.
- **Intermediates cap:** accept up to 2 intermediate bytes (VT spec maximum); extra drop the sequence through `CSI_IGNORE`.

### Parser normalization contracts

Parser emits *normalized but unclamped* values. Semantic bounds belong to `ScreenModel`:

- `CSICommand.cursorPosition(row:col:)` — parser does 1-indexed → 0-indexed origin shift only. Default/missing params become 0 (post-shift) per VT spec ("`ESC[H`" = top-left). Clamping to `rows`/`cols` happens in `ScreenModel.handleCSI` which owns terminal dimensions.
- `CSICommand.cursorUp(_:)` / `cursorDown` / `cursorForward` / `cursorBack` — raw integer payload. Parser applies VT default (missing parameter → 1) but does not clamp. `ScreenModel` clamps the resulting position.
- `TerminalColor.ansi16(UInt8)` — parser emits values in `0..<16` only. Out-of-range SGR input (e.g., malformed `ESC[38;5;900m`) falls through other branches: 256-palette cases use `0..<256` (values over 255 are clipped by the `UInt8` type); the renderer may assume valid ranges and use `palette.ansi[Int(i)]` without masking.

### Unknown sequence policy

Sequences the parser structurally recognizes but doesn't semantically map emit `.csi(.unknown(params:, intermediates:, final:))` and `.osc(.unknown(ps:, pt:))`. `ScreenModel.apply` ignores them but they're visible to tests and `os_log` — lets you spot real-world apps hitting unmapped sequences.

Structurally invalid sequences (unterminated CSI before an ESC intrudes) flow through `CSI_IGNORE` and are silently dropped, per spec.

### Size estimate

~200 LOC for the state machine + ~150 LOC for dispatch-to-event mapping. Reference: Paul Williams' canonical VT state diagram (vt100.net). A source comment will point at it.

## §3 — Event type + Cell/Style

### `TerminalEvent`

```swift
public enum TerminalEvent: Sendable, Equatable {
    case printable(Character)
    case c0(C0Control)
    case csi(CSICommand)
    case osc(OSCCommand)
    case unrecognized(UInt8)
}
```

**Library-evolution note.** `TermCore` has `BUILD_LIBRARY_FOR_DISTRIBUTION = YES` (Release), which makes public non-`@frozen` enums resilient — every `switch` pays a dispatch cost. Annotation policy:

- **`@frozen`** — `C0Control`, `EraseRegion`, `BufferKind`, `ColorRole`, `CellAttributes` (closed by VT spec; future additions would be a breaking change anyway).
- **Non-`@frozen` (default)** — `TerminalEvent`, `CSICommand`, `OSCCommand`, `DECPrivateMode`, `SGRAttribute`, `TerminalColor`. These may legitimately add cases across phases. Every `.unknown(...)` case serves as the open-world escape hatch so consumers still switch exhaustively without `@unknown default` hints.
- **Dispatch helpers** (`handleCSI`, `handleOSC`, `handleC0`) are `internal` or `package`-visible — they switch over internal state and don't need resilience overhead.

### Subfamilies

```swift
@frozen public enum C0Control: Sendable, Equatable {
    case nul, bell, backspace, horizontalTab, lineFeed, verticalTab, formFeed,
         carriageReturn, shiftOut, shiftIn, delete
}

public enum CSICommand: Sendable, Equatable {
    // Cursor motion
    case cursorUp(Int), cursorDown(Int), cursorForward(Int), cursorBack(Int)
    case cursorPosition(row: Int, col: Int)        // 0-indexed after parser normalization
    case cursorHorizontalAbsolute(Int), verticalPositionAbsolute(Int)
    case saveCursor, restoreCursor                 // CSI s / CSI u

    // Erasing
    case eraseInDisplay(EraseRegion)               // CSI J
    case eraseInLine(EraseRegion)                  // CSI K

    // Modes
    case setMode(DECPrivateMode, enabled: Bool)    // CSI ? h / l

    // Scroll region
    case setScrollRegion(top: Int?, bottom: Int?)  // CSI r (nil = reset)

    // SGR nested here — structurally CSI with final byte 'm'
    case sgr([SGRAttribute])

    case unknown(params: [Int], intermediates: [UInt8], final: UInt8)
}

@frozen public enum EraseRegion: Sendable, Equatable { case toEnd, toBegin, all, scrollback }

public enum DECPrivateMode: Sendable, Equatable {
    case cursorKeyApplication      // 1    DECCKM
    case autoWrap                  // 7    DECAWM
    case cursorVisible             // 25   DECTCEM
    case alternateScreen1049       // 1049 (save + alt + clear)
    case alternateScreen1047       // 1047 (alt + clear)
    case alternateScreen47         // 47   (legacy)
    case saveCursor1048            // 1048 (save cursor only)
    case bracketedPaste            // 2004
    case unknown(Int)
}

public enum OSCCommand: Sendable, Equatable {
    case setWindowTitle(String)        // OSC 0 and OSC 2 (aliased)
    case setIconName(String)           // OSC 1
    case unknown(ps: Int, pt: String)  // OSC 8, 52, iTerm proprietary, future
}

public enum SGRAttribute: Sendable, Equatable {
    case reset                                         // 0
    case bold, dim, italic, underline, blink,
         reverse, strikethrough                        // 1/2/3/4/5/7/9
    case resetIntensity, resetItalic, resetUnderline,
         resetBlink, resetReverse, resetStrikethrough  // 22/23/24/25/27/29
    case foreground(TerminalColor)                     // 30–37, 38;2/5, 39, 90–97
    case background(TerminalColor)                     // 40–47, 48;2/5, 49, 100–107
}
```

### Color + Cell

```swift
public enum TerminalColor: Sendable, Equatable, Codable {
    case `default`
    case ansi16(UInt8)                  // 0..<16
    case palette256(UInt8)               // 0..<256
    case rgb(UInt8, UInt8, UInt8)        // 24-bit
}

public struct CellAttributes: OptionSet, Sendable, Equatable, Codable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let bold          = CellAttributes(rawValue: 1 << 0)
    public static let dim           = CellAttributes(rawValue: 1 << 1)
    public static let italic        = CellAttributes(rawValue: 1 << 2)
    public static let underline     = CellAttributes(rawValue: 1 << 3)
    public static let blink         = CellAttributes(rawValue: 1 << 4)
    public static let reverse       = CellAttributes(rawValue: 1 << 5)
    public static let strikethrough = CellAttributes(rawValue: 1 << 6)
}

public struct CellStyle: Sendable, Equatable, Codable {
    public var foreground: TerminalColor = .default
    public var background: TerminalColor = .default
    public var attributes: CellAttributes = []
    public static let `default` = CellStyle()
}

public struct Cell: Sendable, Equatable, Codable {
    public var character: Character
    public var style: CellStyle
    public init(character: Character, style: CellStyle = .default) {
        self.character = character
        self.style = style
    }
}
```

### Notes

- **SGR nested in CSI** — not top-level; consumers pattern-match `.csi(.sgr(_))` in two lines.
- **`[SGRAttribute]` payload allocates on every SGR sequence.** A stream of `ls --color` output emits hundreds of SGR events per screen, each heap-allocating. Inconsistent with §5's `InlineArray<16, RGBA>` choice for similar reasons. **Still open as a Phase 3+ optimization target:** replace with a small-buffer `SGRRun` type holding inline storage for 1–3 attributes (the overwhelmingly common case) + `Array` fallback. Not tackled in Phase 2; re-evaluate against profiling after the Phase 3 hot-path cleanup (vertex arrays, Row allocs) lands — may be deprioritized if parser allocations do not show up as a measured hotspot.
- **VT 1-indexed → 0-indexed conversion** happens inside the parser when emitting `cursorPosition`. `ScreenModel` always sees 0-indexed. Bounds clamping happens in `ScreenModel` — see §2 "Parser normalization contracts."
- **`ansi16(UInt8)` range is `0..<16`** by parser contract — §2 "Parser normalization contracts." Renderer and model use `palette.ansi[Int(i)]` without masking.
- **Unknown sub-cases** (`CSICommand.unknown`, `OSCCommand.unknown`, `DECPrivateMode.unknown`) carry enough info for logging and future promotion to named cases.
- **Cell memory:** ~24–32 bytes per cell once you account for `Character`'s 16-byte wrapping of `String`, `CellStyle`'s ~10 bytes, and struct alignment padding. For a 200×50 main + 200×50 alt + 10K scrollback = ~60 MB per session. Fine for macOS; post-MVP memory revisit tracked separately (see Appendix A — flyweight `styleID: UInt16` seam gets Cell down to ~8 bytes via shared style table).
- **`Cell.init(from:)` is hand-coded, not synthesized.** Decode is `character` required + `container.decodeIfPresent(CellStyle.self, forKey: .style) ?? .default`. Synthesized Codable would fail on any older or leaner payload lacking the style field. Same pattern is the default for every new field added to a `Codable` type crossing the XPC boundary. Phase 2 extended this pattern to all new `ScreenSnapshot` fields (`cursorKeyApplication`, `bracketedPaste`, `bellCount`, `autoWrap` — all `decodeIfPresent ?? default`).
- **Breaking change (landed in Phase 1):** existing call sites using `.newline`/`.carriageReturn`/`.backspace`/`.tab`/`.bell` now use `.c0(.lineFeed)` etc.

## §4 — ScreenModel

### State layout

```swift
actor ScreenModel {
    // Per-buffer state — one for main, one for alt
    private struct Buffer {
        var grid: ContiguousArray<Cell>
        var cursor: Cursor
        var scrollRegion: ScrollRegion         // top/bottom row, 0-indexed inclusive
        var savedCursor: Cursor? = nil         // CSI s / ESC 7 / mode 1048/1049 target
    }
    private var main: Buffer
    private var alt: Buffer
    private var activeKind: BufferKind = .main  // .main | .alt

    // Terminal-wide state — persists across buffer swap
    private var pen: CellStyle = .default
    private var modes: TerminalModes = .default // autoWrap, cursorVisible, cursorKeyApp, bracketedPaste
    private var windowTitle: String? = nil
    private let cols: Int, rows: Int

    // Scrollback — main buffer only, bounded
    private var history: CircularCollection<Row>  // Row = ContiguousArray<Cell>
    private let historyCapacity: Int = 10_000

    // Version counter — bumps only when state actually changed
    private var version: UInt64 = 0

    // Render snapshot cache — heap-boxed, immutable payload; the mutex guards only a pointer swap
    private final class SnapshotBox: Sendable {
        let snapshot: ScreenSnapshot      // all `let` fields — see §4 snapshot shape
        init(_ s: ScreenSnapshot) { self.snapshot = s }
    }
    private let _latestSnapshot: Mutex<SnapshotBox>  // import Synchronization
}
```

Actor + custom serial-queue executor preserved — the daemon read path's `assumeIsolated` pattern keeps working unchanged.

**Snapshot publication discipline.** Writer holds the mutex for exactly one pointer store (`withLock { $0 = SnapshotBox(new) }`). Reader holds it for exactly one pointer load (`withLock { $0 }.snapshot`). No `ContiguousArray<Cell>` copy ever happens inside the lock — `ScreenSnapshot` is all-immutable `let` fields, and readers hold onto the box reference once they've acquired it. The Swift compiler verifies `Sendable` for both `ScreenSnapshot` (value type, all `let`) and `SnapshotBox` (class, all `let`) without `@unchecked`.

**Future lock-free seam.** `Mutex<SnapshotBox>` can be upgraded to `ManagedAtomic<SnapshotBox>` (via `swift-atomics` SPM package) for lock-free reads under render pressure — writers do an acquire-release store, readers an acquire load. Deferred until profiling warrants the added dependency.

### Event dispatch

`apply(_ events:)` becomes a two-level switch:

```swift
var changed = false
for event in events {
    switch event {
    case .printable(let c):  changed = handlePrintable(c) || changed
    case .c0(let x):         changed = handleC0(x) || changed
    case .csi(let cmd):      changed = handleCSI(cmd) || changed
    case .osc(let cmd):      changed = handleOSC(cmd) || changed
    case .unrecognized:      break
    }
}
if changed {
    version &+= 1
    publishSnapshot()
}
```

Each handler returns `Bool` — `true` when it mutated buffer / cursor / pen / modes / title. `version` bumps only on real changes; a stream of `.unrecognized` or `.bell` events doesn't create phantom versions. `&+=` wraps — `UInt64` overflow is theoretical (584 years at 1 GHz) but wrap-on-overflow is the defensible choice for a monotonic counter.

**Visibility contract.** `version` is read only via `publishSnapshot()` / mutex-guarded snapshot access. There is no standalone `currentVersion()` accessor. Callers that see a version have already synchronized with its backing state.

Each handler is a focused file region. New writes go through `writeCell(_ char:)`, which stamps `pen` onto the new `Cell` at the cursor, then advances cursor respecting the active buffer's `scrollRegion` and `modes.autoWrap`.

### C0 handling

| Control | Behavior |
|---------|----------|
| `nul` (0x00) | Ignored |
| `bell` (0x07) | Phase 2 delivered: `bellCount` in snapshot drives audible `NSSound.beep()` with 200 ms rate limiter |
| `backspace` (0x08) | Cursor left 1 (clamped at col 0) |
| `horizontalTab` (0x09) | Advance cursor to next multiple of 8, clamped to last column |
| `lineFeed` (0x0A) | Move cursor to next row; scroll if at bottom (feeds history on main) |
| `verticalTab` (0x0B) | Treated as `lineFeed` (xterm convention) |
| `formFeed` (0x0C) | Treated as `lineFeed` (xterm convention) |
| `carriageReturn` (0x0D) | Cursor to col 0 |
| `shiftOut` / `shiftIn` (0x0E / 0x0F) | Ignored — alternate character sets are out of scope (Appendix B) |
| `delete` (0x7F) | Ignored (most terminals treat as no-op; true backspace is 0x08) |

### Alt-screen semantics

- **Mode 1049 enter:** save main cursor into `main.savedCursor` → `activeKind = .alt` → clear `alt.grid` → `alt.cursor = .origin`. Pen and modes persist.
- **Mode 1049 exit:** `activeKind = .main` → `alt.grid.clear()` → cursor restored from `main.savedCursor`. History untouched.
- **Modes 47 / 1047:** switch buffers; optional alt-clear. Kept for completeness.
- **ESC 7 / CSI s, ESC 8 / CSI u:** per-buffer save/restore; no buffer switch.

### Scrollback integration

When the **main** buffer's top row would be evicted by a natural scroll (cursor below last row, no scroll region or full-screen region), the evicted row is pushed to `history`. Alt buffer never touches history. Scroll-region-internal scrolls discard without feeding history.

### Snapshot shapes — render vs. wire

Two distinct types. The render-side snapshot is published on every change and must stay small; the attach-time wire payload is built lazily only when a client connects.

```swift
// Render-facing — published every apply(), held in Mutex<SnapshotBox>
public struct ScreenSnapshot: Sendable, Equatable, Codable {
    public let activeCells: ContiguousArray<Cell>   // whichever buffer is active
    public let cols: Int, rows: Int
    public let cursor: Cursor
    public let cursorVisible: Bool
    public let activeBuffer: BufferKind
    public let windowTitle: String?
    public let version: UInt64                      // renderer short-circuit key
    // Phase 2 additions (beyond spec §4 baseline, documented in Phase 2 plan):
    public let cursorKeyApplication: Bool           // DECCKM (mode 1)
    public let bracketedPaste: Bool                 // DECSET 2004
    public let bellCount: UInt64                    // bell rate-limit counter
    public let autoWrap: Bool                       // DECAWM (mode 7)
}

// XPC-facing — built only on .attach, includes scrollback
public struct AttachPayload: Sendable, Codable {
    public let snapshot: ScreenSnapshot             // live grid + cursor + version
    public let recentHistory: ContiguousArray<Row>  // bounded, main-only, empty when alt active
    public let historyCapacity: Int                 // so client mirror can size its own buffer
}
```

Post-Phase-2 the snapshot carries 12 stored fields. Its `init` has 12 parameters, of which 7 have defaults. **Phase 3 hygiene task:** extract a `TerminalStateSnapshot` sub-struct for the terminal-state cluster (`cursorVisible`, `activeBuffer`, `windowTitle`, `cursorKeyApplication`, `bracketedPaste`, `bellCount`, `autoWrap`) to keep `ScreenSnapshot` from growing past ~14 parameters as Phase 3 lands `iconName`, cursor-shape (DECSCUSR), and hyperlink state. Defer is acceptable but the trigger is any new field — see §8 "Phase 3 engineering hygiene."

**Why split.** `recentHistory` at 500 rows × 80 cols × ~32 B ≈ 1.3 MB. Publishing that on every apply is wasteful (renderer never uses it) and thrashes COW. Keeping it out of the hot path means the per-apply snapshot update is a pointer swap on a few kilobytes of immutable state, while the XPC path pays the history cost only when a client actually attaches.

**Construction.**

- `publishSnapshot()` (actor-isolated) builds a fresh `ScreenSnapshot` from the current active buffer + `version`, wraps it in `SnapshotBox`, stores into `_latestSnapshot`.
- `buildAttachPayload()` (actor-isolated, called only from the daemon's attach handler) reads `_latestSnapshot`, builds `recentHistory` by copying the last N rows from `history`, returns an `AttachPayload`. Renderer never calls this.
- `publishHistoryTail()` (Phase 2, actor-isolated) republishes the bounded history tail into `Mutex<HistoryBox>`. Must be invoked before `publishSnapshot()` in the same `apply(_:)` batch — the history-before-snapshot ordering invariant is the "lesser evil" per ScreenModel comments (briefly-duplicate row at scrollOffset > 0 is preferable to briefly-missing row). **Phase 3 hygiene:** add this ordering note to the `publishHistoryTail()` doc comment itself so a future refactor doesn't reorder the calls.

`recentHistory` on initial attach is bounded (default 500 rows) — keeps XPC message ~1.3 MB at 80 cols. Live push remains raw PTY bytes; client `ScreenModel` mirror grows its own history. A later `DaemonRequest.fetchHistory(rowRange:)` RPC is a clean extension — seam documented, **deferred past Phase 3** (500-row attach payload is sufficient for all current use cases; promote to Phase 4 if profiling or UX warrants).

### Memory bake-ins

- `ContiguousArray<Cell>` for grid storage — guarantees contiguous Swift-native layout for Metal upload.
- `version: UInt64` counter on every snapshot update — renderer skips re-upload when unchanged.
- `CellStyle` flyweight (`styleID: UInt16` + shared `StyleTable`) — **conditionally in Phase 3** (only if OSC 8 hyperlink addition crosses the measurement gate; see §8 Phase 3 open question 2); otherwise Phase 4.
- `Span<Cell>` at internal API boundaries **deferred** until profiling shows the win.

## §5 — Renderer color projection

### User-facing types

```swift
@frozen public enum ColorDepth: Sendable, Equatable, Codable {
    case ansi16, palette256, truecolor
}

public struct TerminalPalette: Sendable, Equatable, Codable {
    public var ansi: InlineArray<16, RGBA>   // stack-allocated, no heap, no ARC
    public var defaultForeground: RGBA
    public var defaultBackground: RGBA
    public var cursor: RGBA
    // palette256 is NOT stored — derived from ansi + 216-cube + 24 grays on change,
    // cached in the RenderCoordinator, invalidated when ansi changes.

    public static let xtermDefault: TerminalPalette     // see "Presets" below
    public static let solarizedDark: TerminalPalette
    public static let solarizedLight: TerminalPalette
}
```

`ColorDepth` and `TerminalPalette` live outside `TermCore` (user settings concern). `TerminalColor` (the stored one) stays inside `TermCore` — parser and model know nothing about the palette.

**`InlineArray` Codable — hand-coded.** `InlineArray<N, T>` does not synthesize `Codable` in Swift 6.2 / SE-0453. `TerminalPalette.init(from:)` and `encode(to:)` are hand-written: decode reads a `[RGBA]` of exactly 16 elements (throw on mismatch), then builds the `InlineArray` element-by-element; encode writes `Array(ansi)`. Wire format stays a plain JSON array.

**Presets** are populated via a static init function (`Self.build(xterm:)`, etc.) with element-by-element assignment. `InlineArray` does not yet support collection literals, so there's no `InlineArray<16, RGBA>([ ... ])` form.

### Projection

Single pure function, called at draw time:

```swift
func resolve(_ color: TerminalColor,
             role: ColorRole,             // .foreground or .background
             depth: ColorDepth,
             palette: TerminalPalette,
             derivedPalette256: InlineArray<256, RGBA>) -> RGBA {
    switch (color, depth) {
    case (.default, _):
        return role == .foreground ? palette.defaultForeground : palette.defaultBackground
    case (.ansi16(let i), _):
        return palette.ansi[Int(i)]
    case (.palette256(let i), .ansi16):
        return quantizeToAnsi16(derivedPalette256[Int(i)], palette: palette)
    case (.palette256(let i), _):
        return derivedPalette256[Int(i)]
    case (.rgb(let r, let g, let b), .ansi16):
        return quantizeToAnsi16(RGBA(r, g, b), palette: palette)
    case (.rgb(let r, let g, let b), .palette256):
        return quantizeTo256(RGBA(r, g, b), palette: palette)
    case (.rgb(let r, let g, let b), .truecolor):
        return RGBA(r, g, b)
    }
}
```

Quantization is nearest-neighbor in RGB space against anchor colors. For 80×24 = 1920 cells/frame, plain distance math is fast enough; LUTs are a post-MVP option.

### Where projection runs

CPU side, once per frame, in `RenderCoordinator`. For each cell, compute resolved `fgRGBA` / `bgRGBA` and attribute flags and pack into the vertex buffer. Shader does plain texture-sampled glyph composition. GPU-side projection is a post-MVP optimization.

### Attribute rendering

| Attribute | Implementation |
|-----------|----------------|
| bold | Bold glyph variant in atlas |
| italic | Italic glyph variant in atlas |
| bold + italic | Bold-italic variant (4 atlases total) |
| underline | Second draw pass — thin line quad under the cell |
| strikethrough | Second draw pass — thin line quad across cell center |
| reverse | Swap fg/bg at CPU projection time |
| dim | Multiply fg alpha by ~0.5 at projection time |
| blink | Phase 3 — global timer uniform; shader toggles visibility (bundled with DECSCUSR blink cursor variants) |

### Glyph atlas

Current `GlyphAtlas` is one 16×6 grid of ASCII 0x20–0x7E. Evolves to a **family of up-to-four atlases** (regular / bold / italic / bold-italic), identical layout, materialized lazily. Phase 1 ships regular + bold; italic + bold-italic materialize when Phase 2 activates the italic attribute.

**Unicode beyond ASCII:** **Deferred to Phase 4** (revised 2026-05-02). Non-ASCII cells render U+FFFD or "?" through Phase 3. Cell model is already Unicode-correct (`Character` handles grapheme clusters); only the renderer limits it. Phase 4 will land dynamic glyph atlas with LRU cache + CoreText fallback.

### Live mode switching

`ColorDepth` and `TerminalPalette` are `@Observable` properties of an `@MainActor`-annotated `AppSettings` class. `RenderCoordinator` (`MTKViewDelegate.draw(in:)` runs on the main queue) reads them via `MainActor.assumeIsolated` at frame entry and captures a local copy for the frame. Change → next frame re-projects all cells → instant visual update. No data migration.

## §6 — Daemon protocol changes

### What landed in Phase 1 + Phase 2

1. **`ScreenSnapshot` grew** (per §4): Phase 1 added `cursorVisible`, `activeBuffer`, `windowTitle`, `version`. Phase 2 added `cursorKeyApplication`, `bracketedPaste`, `bellCount`, `autoWrap`. All new fields use `decodeIfPresent ?? default` in the hand-coded `Codable` init. Existing Phase 1 fields retained.

2. **`AttachPayload`** (per §4) — landed in Phase 2. Wraps `ScreenSnapshot` + `recentHistory` + `historyCapacity`. `DaemonResponse.attachPayload(sessionID:, payload: AttachPayload)` replaced `DaemonResponse.snapshot(…)`. Rendering still consumes `ScreenSnapshot` (nested field); `recentHistory` feeds the client's `ScreenModel` history on restore.

3. **No new RPCs through Phase 2.** `fetchHistory(sessionID:, rowRange:)` remains deferred — 500-row attach is sufficient. Promote to Phase 4 if UX demands deep backscroll.

4. **No explicit protocol version field.** rTerm still ships daemon + client together. Keep the `Codable` + `decodeIfPresent` pattern for every new field — it gives a migration path if separate cadences ever appear. **Phase 3 constraint:** new fields on `ScreenSnapshot` / `AttachPayload` must remain backward-compatible by this same convention; do not break Phase 1/2 wire format.

5. **`Cell` is `Codable` with the new style field** (Phase 1). Hand-coded `init(from:)` tolerates style-less payloads. Same pattern carried into all subsequent fields.

6. **Session-wide palette is not in the payload.** Palette and `ColorDepth` are client-side user settings. Daemon stores everything at full fidelity. Different clients reattaching with different settings both render correctly. No change planned for Phase 3.

### Wire size sanity check

- **AttachPayload (cold attach):** 80 × 24 × ~32B = ~60 KB visible snapshot + 500 rows × 80 × ~32B ≈ ~1.3 MB history + a few KB cursor/title/modes → ~1.4 MB per attach. XPC handles this comfortably. Verified in Phase 2.
- **Live fan-out:** unchanged — raw PTY bytes. Verified in Phase 2.

## §7 — Testing strategy

TDD, Swift Testing framework (`@Test`, `#expect`) — matches existing convention.

### 1. Parser state-machine tests (`TerminalParserTests.swift`)

Expand from today's 13 tests to ~40-50:

- **Per-state transitions:** each Williams state, verify legal and illegal byte inputs reach the expected next state. Uses an `@testable` view of `parser.state` to assert transitions directly.
- **Final dispatch:** feed full sequences, assert exact emitted event.
- **Cross-chunk boundaries:** same sequence split at every possible byte boundary must produce the same event list.
- **Cancellation:** `ESC [ 3 1 <CAN>` mid-sequence returns to GROUND without emitting SGR.
- **Malformed sequences:** unterminated CSI + new ESC → CSI_IGNORE path → dropped silently.
- **Unknown sequences:** unmapped final byte emits `.csi(.unknown(...))`.

### 2. ScreenModel behavior tests (`ScreenModelTests.swift`)

Expand from 16 tests to ~30-40:

- CSI cursor motion with bounds clamping and scroll-region awareness.
- Erasing regions (ED 0/1/2/3, EL 0/1/2).
- SGR pen state: composition, reset, individual toggles.
- Alt-screen transitions: mode 1049 enter → saved cursor, alt cleared, pen persists → exit → main restored.
- Scrollback: main eviction feeds history; alt doesn't; region-bounded scroll doesn't.
- Window title from `.osc(.setWindowTitle)`.
- `snapshot.version` bumps on every `apply` call.

### 3. Integration / fixture tests (`TerminalIntegrationTests.swift` — new)

Byte-stream fixtures mapped to expected snapshots:

- Minimal vim-startup (alt screen + tildes + cursor home).
- Minimal `ls --color` output (SGR-styled filenames).
- `clear` (CSI 2J + CSI H; main history fed).
- `top`/`htop` startup (alt screen + full-screen redraw).
- Cross-chunk variants — same streams chunked randomly, identical final snapshot.

Fixtures stored as `.bin` resources next to the test target. Initial corpus hand-authored or captured with `script(1)`.

### 4. Color projection tests (`RenderCoordinatorTests.swift` — new)

Pure-function tests, no Metal device required:

- `resolve(.rgb(255, 128, 0), ..., .truecolor)` → identity.
- `resolve(.rgb(255, 0, 0), ..., .ansi16)` → nearest anchor for known palette.
- `resolve(.ansi16(1), ...)` → `palette.ansi[1]` for any depth.
- `resolve(.default, .foreground, ...)` → `palette.defaultForeground`.

### Coverage expectations

~100 tests total across categories by end of MVP. Every new `CSICommand` / `OSCCommand` / `SGRAttribute` case gets at least one parser test and one screen-model test.

### Out of scope for unit tests

- Renderer pixel correctness — visual smoke-testing via the app + manual `vttest`.
- Daemon XPC end-to-end — existing integration tests cover the pipeline; add one SGR e2e test but don't duplicate model-level coverage at the daemon level.

## §8 — Phasing

Three phases, each a complete, shippable, testable state. Architecture supports all three from day one.

### Phase 1 — Colorful static terminal (MVP) — **Delivered (merged on `main`)**

**In scope (all delivered):**

- `TerminalParser` Williams state machine
- `TerminalEvent` grouped-enum restructure (breaking, in-tree)
- Missing C0 controls (NUL, VT, FF, SO, SI, DEL)
- CSI cursor motion (CUU/CUD/CUF/CUB/CUP/HVP/CHA/VPA) + bounds clamping
- CSI erasing (ED, EL) with all regions
- SGR parsing + `Cell.style` + `CellStyle` pen state
- `TerminalColor` (truecolor fidelity always)
- `ColorDepth` + `TerminalPalette` user settings; render-time projection
- Renderer: regular + bold glyph atlases, per-cell fg/bg, underline pass
- OSC 0/2 window title → `NSWindow.title`
- Snapshot `version` counter
- Mutex<SnapshotBox> publication, split snapshot+attach payload
- Test corpus: parser state transitions + cursor/erase/SGR on ScreenModel + color projection

**Deferred (all addressed in Phase 2):**

- DEC private modes (autoWrap treated always-on, cursor always visible)
- Alt screen (writes go to main)
- DECSTBM (full-screen scroll only)
- Save/restore cursor
- Scrollback history (evicted rows discarded)
- Italic/dim/reverse/strikethrough visual rendering (parsed and stored, ignored by shader)
- Blink

**After Phase 1 (verified):** colored `ls`, colored `git diff`, correct prompts, working `clear`, correct cursor positioning. Vim/tmux/htop look acceptable but overwrite scrollback.

### Phase 2 — Full TUI + scrollback — **Delivered (branch `phase-2-control-chars`, PR #5, tip `8aeea2d`)**

**In scope (all delivered):**

- DEC private modes: DECAWM (7), DECTCEM (25), DECCKM (1) with `KeyEncoder` hook, bracketed paste (2004)
- Alt screen modes 47 / 1047 / 1049; dual-buffer `ScreenModel` (`Buffer` struct + `mutateActive<R>` closure pattern)
- DECSTBM (including the T5 plan correction for the full-screen-scroll predicate)
- ESC 7/8 + CSI s/u
- `saveCursor1048` (1048)
- Scrollback history (`CircularCollection<Row>` in `ScreenModel`, bounded, main-only)
- `AttachPayload` with `recentHistory` + `historyCapacity`, and `restore(from payload:)` on reattach
- Scrollback UI: scroll wheel, PgUp/PgDn, scroll-to-bottom-on-new-output (`ScrollViewState`)
- Renderer: italic + bold-italic glyph atlases materialized; dim alpha, reverse swap, strikethrough pass (`AttributeProjection`)
- Bell (audible `NSSound.beep()` with 200 ms rate limiter via `bellCount` in snapshot)
- `windowTitle` via nonisolated `latestSnapshot()` read (follow-up commit `8aeea2d`)
- `ScrollbackHistory.tail(0)` edge case pinned by test (follow-up `8aeea2d`)
- `TerminalSession.paste(_:)` integration-tested via `pastePayload(text:snapshot:)` (follow-up `8aeea2d`)

**Known deferrals (carry into Phase 3, see engineering-hygiene section below):**

- Cold-attach when alt active: client receives empty `recentHistory` (documented limitation).
- Integration fixture corpus shipped only `vimStartupSequence`; `top`/`htop` fixture deferred.
- Per-row dirty tracking (still deferred — version counter remains sufficient).
- `fetchHistory` RPC — still deferred past Phase 3 unless profiling or UX warrants.

**Phase 2 plan deviations (documented):**

- `T5` scroll-dispatcher trigger condition corrected inline in the plan (`Buffer.shouldScroll(rows:)`).
- `ScreenSnapshot` gained four fields beyond spec §4 baseline (`cursorKeyApplication`, `bracketedPaste`, `bellCount`, `autoWrap`) — all added via `decodeIfPresent` for wire compatibility. Reflected in §4 above.
- `TerminalModes.Codable` conformance added for `restore(from snapshot:)` — internal only, not on the wire.

**After Phase 2 (verified):** vim, tmux, htop, less, mc — all native feel. Real detach/reattach with history. 222/222 TermCoreTests pass; 53/53 rTermTests pass.

### Phase 3 — Polish, hygiene, and the next-tier escape sequences

Phase 3 has two load-bearing tracks that **must ship together** before any further feature phase:

**Track A — feature scope (tightened from the original Phase 3 bullet list).** A smaller set than originally listed; items that require major surface (sixel, kitty images, Unicode atlas) are explicitly deferred to Phase 4+.

**Track B — engineering hygiene (new).** Phase 2 left behind measurable hot-path regressions and latent API risks. These must be paid down before additional features accumulate on top of them.

Each track gets its own implementation plan (or may be combined into a single plan if the planner prefers). Both tracks must hit green tests before Phase 3 closes.

#### Phase 3 — Track A: feature scope

**In scope:**

- **OSC 8 hyperlinks.** Parser already emits `.osc(.unknown(ps: 8, pt: …))`. Land:
  - Promote the OSC 8 case out of `.unknown` into `OSCCommand.setHyperlink(id: String?, uri: String?)` (nil on terminator `OSC 8 ; ; ST`).
  - Extend `CellStyle` with `hyperlink: Hyperlink?` (new value type with `id` and `uri`). Adds ~16 B to `CellStyle` — compare against flyweight motivation below.
  - Renderer: underline on hover, click handler that opens the URI via `NSWorkspace.open(_:)` (sandboxed-safe — `openURL` works without entitlement additions).
  - Model: stamp current hyperlink onto `Cell.style.hyperlink` via pen state, same as foreground/background.
  - Wire compat: `CellStyle.init(from:)` uses `decodeIfPresent(Hyperlink?.self) ?? nil`. `Hyperlink` is `Codable`.

- **OSC 52 clipboard.** Parser emits `.osc(.unknown(ps: 52, pt: "<target>;<payload>"))`.
  - Promote to `OSCCommand.setClipboard(target: ClipboardTarget, payload: ClipboardPayload)` where `target` is `.clipboard | .primary | .selection` (xterm semantics) and `payload` is `.set(String)` (base64-decoded) or `.query`.
  - Model stores nothing permanently — the request fans out through a new `DaemonResponse.clipboardWrite(sessionID:, target:, payload: Data)` push (or equivalent) so the client app can route to `NSPasteboard.general` under a user-consent gate (sandbox-safe).
  - Outgoing paste is the mirror of bracketed paste (bracketed paste is incoming-only today). `OSC 52 query` response — the client reads `NSPasteboard` and writes back into the PTY as `ESC ] 52 ; <target> ; <base64> BEL`. Confirm query response is scoped in Phase 3 or explicitly deferred (see open questions).

- **Cursor shape — DECSCUSR (`CSI Ps SP q`).** Extend `CSICommand` with `setCursorShape(CursorShape)` (block/underline/bar, steady/blink). Snapshot already owns cursor; add `cursorShape: CursorShape` field via `decodeIfPresent`. Renderer draws the variant.

- **Blink attribute.** Already parsed in Phase 1. Land the global timer uniform + shader toggle. Scoped bundle with DECSCUSR blink variants to share the timing infrastructure.

- **Terminal identification responses.** Shell-level query sequences vim/tmux/htop commonly issue:
  - `CSI c` / `CSI 0 c` — Primary DA (DA1). Respond `ESC [ ? 6 c` (VT102) or `ESC [ ? 1 ; 2 c`.
  - `CSI > c` / `CSI > 0 c` — Secondary DA (DA2). Respond with terminal-ID + firmware-version triple.
  - `CSI 6 n` — Cursor Position Report (CPR). Respond `ESC [ <row> ; <col> R` (1-indexed). Reply is a byte stream back to the PTY primary, not a model mutation.
  - Implement via a new `TerminalEvent.csi(.deviceStatusReport(Kind))` → routed in the daemon to write bytes back into the PTY, not into the `ScreenModel`.

- **Origin mode — DECOM (mode 6).** Cursor-position commands become scroll-region-relative when set. Straightforward add to `DECPrivateMode` + `handleSetMode`.

- **132-column mode — DECCOLM (mode 3).** Resizes the buffer to 132 cols when enabled, restores on disable. Requires `resize(cols:rows:)` to already exist (it does — pre-existing on `TerminalSession`). One caveat: DECCOLM also clears the screen by spec; model must coordinate.

- **Palette chooser UI.** Built-in presets (xterm, solarized dark/light) already defined in `TerminalPalette`. Add a settings pane to pick. Not a parser/model concern.

- **Integration fixture corpus completion.** Land `top`/`htop` fixture, widen cross-chunk variants.

**Deferred explicitly to Phase 4+ (not in Phase 3, so the planner does not need to account for them):**

- **Mouse tracking** (X10 `CSI ? 9`, UTF-8 `CSI ? 1005`, SGR `CSI ? 1006`, urxvt `CSI ? 1015`). Requires end-to-end work from `TerminalMTKView` mouse events → encoding → PTY bytes. Document seam but do not implement.
- **Sixel graphics** (DCS `q`). Major surface: DCS state machine, image pixel buffer, Metal texture upload, scrolling semantics. Phase 4 at earliest.
- **Kitty graphics protocol.** Same category as sixel; separate Phase 4+ spec.
- **Unicode glyph atlas beyond ASCII.** Dynamic atlas with LRU cache + CoreText fallback. The Cell model already handles grapheme clusters; only the renderer limits it. Phase 4 — the Phase 3 hygiene track is the right time to *not* expand the atlas surface.
- **`CellStyle` flyweight (`styleID: UInt16` + `StyleTable`).** Still deferred. Adding `Hyperlink?` to `CellStyle` in Phase 3 pushes `CellStyle` from ~10 B to ~26 B, which doubles scrollback memory pressure — this is the trigger to implement the flyweight in Phase 3 **only if** Phase 3's OSC 8 work makes cold-attach payloads exceed 3 MB or scrollback cost exceed 100 MB in measurement. Default posture: keep deferred, measure first. Open question for the planner; see below.
- **Per-row dirty tracking.** Still deferred; version counter + full-frame re-upload remains the rendering contract.
- **`fetchHistory` RPC.** Still deferred; 500-row attach remains sufficient.
- **`Span<Cell>` at internal boundaries.** Still deferred; no profiling evidence of a regression that `Span` would fix.
- **GPU-side color projection, LUT-based quantization.** Still deferred past Phase 3.
- **DCS passthrough**, **character sets (G0/G1 SS2/SS3)**, **RIS hard reset**, **East Asian wide characters** — deferred per Appendix B.

#### Phase 3 — Track B: engineering hygiene (mandatory)

The Phase 2 final/efficiency/simplify/quality research docs enumerate the following cleanup items. **These are not optional** — they must land in Phase 3 before further features compound on the debt.

1. **Renderer vertex array reuse.** `RenderCoordinator.draw(in:)` allocates 6 `[Float]` arrays per frame, each `reserveCapacity`-initialized → ~2,880 KB/frame reserved-then-freed. Phase 1 baseline was ~1,440 KB for 3 arrays. Fix: promote the 6 arrays to `var` instance properties on `RenderCoordinator`, call `removeAll(keepingCapacity: true)` at the top of `draw(in:)`. Eliminates the entire per-frame alloc/free cycle.

2. **Metal buffer pre-allocation ring.** Up to 6 `device.makeBuffer(...)` calls per frame in the worst case (4 glyph passes + underline + strikethrough; cursor already uses `setVertexBytes`). Implement a pre-allocated ring of `MTLBuffer`s sized for the largest frame, rotated per-frame-in-flight. Target: zero `makeBuffer` calls in steady state. This was already noted as a Phase 3 target in the Phase 2 plan.

3. **`ScrollbackHistory.Row` pre-allocated slots.** `scrollAndMaybeEvict` allocates a new `ContiguousArray<Cell>` (~3.1 KB) per scrolling LF on main. Negligible at interactive speeds; noticeable at ≥10,000 LF/s burst (binary output, `yes`). Fix: pre-allocate a ring of Row buffers on the `ScrollbackHistory` side and copy into a fixed slot rather than allocating a fresh array per scroll. Measure before optimizing — if measurements show no regression at 60 MB/s sustained throughput, document "deferred with measurement" and move on.

4. **`ScreenSnapshot` 12-param init.** Extract a `TerminalStateSnapshot` sub-struct covering the 7 terminal-state fields. Driven by the fact that Phase 3 adds at least `cursorShape` and possibly `iconName` — refactoring before the 13th/14th field lands keeps the `init` tractable. See §4.

5. **`ScreenModel.swift` file split.** At 941 lines with 10 logical sections, split into `ScreenModel.swift` + `ScreenModel+Buffer.swift` (contains `Buffer`, `ScrollRegion`, `mutateActive`, `scrollAndMaybeEvict`, `clearGrid`) + `ScreenModel+History.swift` (history storage, `publishHistoryTail`, `buildAttachPayload`, `restore(from payload:)`, `latestHistoryTail`). Requires promoting `Buffer` and `ScrollRegion` from `private` to `fileprivate` or `internal`. Low risk, high readability payoff as Phase 3 handlers grow the file further.

6. **`DispatchQueue` → `DispatchSerialQueue` force-cast hardening.** `ScreenModel.init(queue:)` force-casts the base-class parameter to `DispatchSerialQueue`. If a future caller passes a `.concurrent` queue the force-cast crashes at runtime with no compile-time warning. Fix: add a new `public init(…, queue: DispatchSerialQueue? = nil)` with the typed parameter, deprecate the untyped `init(…, queue: DispatchQueue? = nil)` via `@available(*, deprecated, renamed: …)`. Because `BUILD_LIBRARY_FOR_DISTRIBUTION` is enabled on TermCore (Release), keep both inits to preserve binary compatibility.

7. **`cellAt` scrolled-render loop restructuring.** When `scrollOffset > 0` the renderer calls `history[historyRowIdx]` once per (row, col) pair instead of once per row. Hoist the row load to the outer loop. Small per-scrolled-frame cost (~46 KB of header copies) but trivial fix.

8. **`publishHistoryTail()` ordering doc.** Add a one-sentence doc comment on `publishHistoryTail()` describing the history-before-snapshot ordering invariant, so a future refactor does not accidentally invert the calls.

9. **`Cursor.zero` / `.origin` static.** One-liner on `Cursor` to replace the 4 inline `Cursor(row: 0, col: 0)` sites. Nice-to-have; bundle with (4) since both touch `ScreenSnapshot.swift` / `Cell.swift`.

10. **`CircularCollection` TODO (line 53).** Pre-existing from Phase 1 — "we can split the payload into before and after slices, and apply them, 2 steps instead of n." Addressed in Phase 3 only if benchmarks indicate `append(contentsOf:)` is a hotspot. Default: defer with a tracking comment that this was reconsidered in Phase 3.

11. **`ImmutableBox<T>` extraction (still deferred — conditional).** Do **not** extract the `SnapshotBox` / `HistoryBox` duplication into a generic `ImmutableBox<T>` for Phase 3's initial work. **Trigger revisit:** if Phase 3's OSC 52 clipboard work or cursor-shape work adds a third `Mutex<Box>` to `ScreenModel`, extract then. Otherwise, two named types are more readable than a generic.

12. **Test gaps from Phase 2.** Add:
    - A test pinning the `AttributeProjection.atlasVariant` invariance against dim/underline/blink (non-atlas attributes should not affect variant).
    - An integration test verifying `restore(from payload:)` clear-before-publish ordering (or document why this ordering cannot be unit-tested without a concurrent reader).
    - `top`/`htop` fixture in the integration corpus.

13. **Comment cleanup.** No outstanding items — the `TermView.swift:192` "T10's scroll handlers" stale comment was addressed by ongoing polish before Phase 3 opens; verify during Phase 3 that no stale T-references remain.

**Track B test discipline.** Every item lands behind existing tests + any new tests specifically asserting the regression it fixes (e.g., per-frame allocation count via `os_signpost` instrumentation for item 1; boundary test for item 6).

#### Phase 3 open questions for the planner (to be resolved before writing the plan)

1. **OSC 52 query response in Phase 3 or Phase 4?** Reading `NSPasteboard` and writing back into the PTY requires the daemon to accept a client-originated byte injection via XPC. That is a new daemon surface. Possibly defer the query side of OSC 52 to Phase 4 and ship only the *set* path in Phase 3.

2. **Flyweight `CellStyle`.** With OSC 8 hyperlinks adding ~16 B to `CellStyle`, memory pressure doubles. Ship flyweight in Phase 3 **conditionally on measurement** (cold-attach payload > 3 MB or scrollback > 100 MB). Planner decision: define the measurement gate and stick to it.

3. **Measurement instrumentation.** Track B items 1 and 3 both recommend measurement before optimization. Which measurement tool — `os_signpost`, Metal frame capture, allocation profiler? Planner picks one and applies it consistently across all Phase 3 hot-path fixes.

4. **Scope of OSC 8 URI opening.** Sandboxed `NSWorkspace.open(_:)` for `http(s)://` and `file://` only, or broader? Security posture question.

5. **Plan-granularity preference.** Track A and Track B are large enough that a single Phase 3 plan may exceed a reasonable single-session scope. Planner may split into `phase-3-features` and `phase-3-hygiene` plans, or interleave. Decision point.

### Cross-phase principles

- Every phase ends on green tests.
- Every phase preserves daemon/client protocol compatibility within its own cut. Phase boundaries may bump snapshot fields (nothing external has shipped), but within a phase the bundled daemon + client are always compatible. **Phase 3 constraint:** must not break Phase 1/2 wire format — new fields use `decodeIfPresent`, removal is forbidden.
- No phase introduces a feature flag. If something isn't ready, it doesn't merge.
- Phase 1 and Phase 2 landed with their own implementation plans. Phase 3 items may be planned as one or two plans per the open-question decision above.

## Appendix A — Open seams documented for future phases

Updated 2026-05-02 to reflect Phase 2 landing state.

**Live seams (planned for Phase 3, see §8 Track B):**
- OSC 8 (`CellStyle.hyperlink: Hyperlink?`) — Cell-shape change
- OSC 52 clipboard set path (query path may slip to Phase 4)
- DECSCUSR cursor shape, blink uniform
- DECOM, DECCOLM
- DA1 / DA2 / CPR responses (write-back-to-PTY path)
- `DaemonResponse.clipboardWrite(...)` new XPC push case for OSC 52

**Deferred past Phase 3 (still open, not scheduled):**
- `Span<Cell>` at internal API boundaries — no profiling evidence of a regression that demands it
- `CellStyle` flyweight via `styleID: UInt16` + `StyleTable` — revisit conditionally if OSC 8 + full hyperlink cell surface crosses the memory-pressure gate (see Phase 3 open question 2)
- Per-row dirty tracking — version counter + full-frame re-upload is sufficient
- `DaemonRequest.fetchHistory(sessionID:, rowRange:)` for deep backscroll — 500-row attach still sufficient
- Unicode glyph atlas beyond ASCII (dynamic LRU + CoreText fallback) — Phase 4 material
- Sixel / kitty graphics (DCS passthrough) — Phase 4+
- Mouse tracking (X10, UTF-8 1005, SGR 1006, urxvt 1015) — Phase 4
- Character sets (G0/G1, SS2/SS3, DEC special graphics) — Phase 4+
- East Asian wide characters — separate spec
- GPU-side color projection (uniform palette + enum-encoded Cell colors)
- LUT-based color quantization (32K RGB bins → palette index)
- `protocolVersion` envelope field — only if daemon and client ever ship on separate cadences

## Appendix B — Non-goals

Updated 2026-05-02. Some items moved into Phase 3 scope (see §8); those are no longer non-goals.

Still not addressed in this spec:

- Mouse reporting (SGR 1000/1002/1006) — Phase 4
- Character sets (G0/G1 switching, DEC special graphics) — Phase 4+
- DCS passthrough (sixel graphics, kitty image protocol) — Phase 4+
- VT100 hard reset (RIS) — out of scope
- Multi-byte character widths (East Asian wide characters) — needs tracking as a separate spec
- Configurable keybindings (input side — separate concern)
- Per-session palette overrides (palette is client-global, not session-local)

**Moved into Phase 3 scope** (no longer non-goals): OSC 8 hyperlinks, OSC 52 clipboard, DECSCUSR cursor shape, blink, DECOM, DECCOLM, DA1/DA2/CPR responses, palette chooser UI.
