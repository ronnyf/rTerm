# Control Characters & Escape Sequence Handling — Design

- **Date:** 2026-04-30
- **Status:** Approved (brainstorming)
- **Exploration:** [`docs/explorations/2026-04-30-control-characters.md`](../../explorations/2026-04-30-control-characters.md)

## Summary

rTerm's current parser recognizes a narrow subset of ASCII control characters and silently discards every escape sequence — including `ESC` (0x1B) itself. This spec lays out the architecture for full ANSI/VT positional and control-character handling: a Paul Williams VT state machine in the parser, a grouped-enum event vocabulary covering CSI / OSC / C0, dual-buffer `ScreenModel` with alt-screen support, truecolor SGR with render-time depth projection, OSC 0/2 window title, DEC private modes, DECSTBM scroll regions, and bounded scrollback. Implementation is staged across three phases; the architecture supports the end state from day one.

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
| 8 | OSC scope | OSC 0/2 (window title) now; OSC 8 / 52 deferred with `.osc(.unknown(...))` passthrough seam |

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

Three implementation phases (§8): MVP parser + cursor/erase + SGR + colors, then modes + alt screen + scrollback, then OSC 8/52 + polish.

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

### Subfamilies

```swift
public enum C0Control: Sendable, Equatable {
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

public enum EraseRegion: Sendable, Equatable { case toEnd, toBegin, all, scrollback }

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
- **VT 1-indexed → 0-indexed conversion** happens inside the parser when emitting `cursorPosition`. `ScreenModel` always sees 0-indexed.
- **Unknown sub-cases** (`CSICommand.unknown`, `OSCCommand.unknown`, `DECPrivateMode.unknown`) carry enough info for logging and future promotion to named cases.
- **Cell memory:** ~24–32 bytes per cell once you account for `Character`'s 16-byte wrapping of `String`, `CellStyle`'s ~10 bytes, and struct alignment padding. For a 200×50 main + 200×50 alt + 10K scrollback = ~60 MB per session. Fine for macOS; post-MVP memory revisit tracked separately (see §8 Phase 3 style-flyweight — gets Cell down to ~8 bytes via `styleID: UInt16` into a shared table).
- **Breaking change:** existing call sites using `.newline`/`.carriageReturn`/`.backspace`/`.tab`/`.bell` become `.c0(.lineFeed)` etc. All in-tree — ~20-30 lines of mechanical change across parser / model / tests.

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

    // Version counter — bumps on every snapshot update
    private var version: UInt64 = 0

    // Snapshot cache — unchanged pattern
    private let _latestSnapshot: OSAllocatedUnfairLock<ScreenSnapshot>
}
```

Actor + custom serial-queue executor preserved — the daemon read path's `assumeIsolated` pattern keeps working unchanged.

### Event dispatch

`apply(_ events:)` becomes a two-level switch:

```swift
for event in events {
    switch event {
    case .printable(let c):  handlePrintable(c)
    case .c0(let x):         handleC0(x)
    case .csi(let cmd):      handleCSI(cmd)
    case .osc(let cmd):      handleOSC(cmd)
    case .unrecognized:      break
    }
}
version += 1
updateSnapshot()
```

Each handler is a focused file region. New writes go through `writeCell(_ char:)`, which stamps `pen` onto the new `Cell` at the cursor, then advances cursor respecting the active buffer's `scrollRegion` and `modes.autoWrap`.

### C0 handling

| Control | Behavior |
|---------|----------|
| `nul` (0x00) | Ignored |
| `bell` (0x07) | No-op in MVP; visual/audible bell is a Phase 2 UX detail |
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

### Snapshot shape

```swift
public struct ScreenSnapshot: Sendable, Equatable, Codable {
    public let activeCells: ContiguousArray<Cell>   // whichever buffer is active
    public let cols: Int, rows: Int
    public let cursor: Cursor
    public let cursorVisible: Bool
    public let activeBuffer: BufferKind
    public let windowTitle: String?
    public let recentHistory: ContiguousArray<Row>  // bounded, main-only, empty when alt active
    public let historyCapacity: Int                  // so client mirror can allocate
    public let version: UInt64                        // renderer short-circuit
}
```

`recentHistory` on initial attach is bounded (default 500 rows) — keeps XPC message ~640 KB at 80 cols. Live push remains raw PTY bytes; client `ScreenModel` mirror grows its own history. A later `DaemonRequest.fetchHistory(rowRange:)` RPC is a clean extension — seam documented, Phase 3.

### Memory bake-ins

- `ContiguousArray<Cell>` for grid storage — guarantees contiguous Swift-native layout for Metal upload.
- `version: UInt64` counter on every snapshot update — renderer skips re-upload when unchanged.
- `CellStyle` flyweight (`styleID: UInt16` + shared `StyleTable`) **deferred to Phase 3** — architectural seam noted.
- `Span<Cell>` at internal API boundaries **deferred** until profiling shows the win.

## §5 — Renderer color projection

### User-facing types

```swift
public enum ColorDepth: Sendable, Equatable, Codable {
    case ansi16, palette256, truecolor
}

public struct TerminalPalette: Sendable, Equatable, Codable {
    public var ansi: InlineArray<16, RGBA>   // stack-allocated, no heap, no ARC
    public var defaultForeground: RGBA
    public var defaultBackground: RGBA
    public var cursor: RGBA
    // palette256 is NOT stored — derived from ansi + 216-cube + 24 grays on change,
    // cached in the RenderCoordinator, invalidated when ansi changes.

    public static let xtermDefault: TerminalPalette
    public static let solarizedDark: TerminalPalette
    public static let solarizedLight: TerminalPalette
}
```

`ColorDepth` and `TerminalPalette` live outside `TermCore` (user settings concern). `TerminalColor` (the stored one) stays inside `TermCore` — parser and model know nothing about the palette.

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
| blink | Phase 3 — global timer uniform; shader toggles visibility |

### Glyph atlas

Current `GlyphAtlas` is one 16×6 grid of ASCII 0x20–0x7E. Evolves to a **family of up-to-four atlases** (regular / bold / italic / bold-italic), identical layout, materialized lazily. Phase 1 ships regular + bold; italic + bold-italic materialize when Phase 2 activates the italic attribute.

**Unicode beyond ASCII:** Phase 3. Non-ASCII cells render U+FFFD or "?" in MVP/Phase 2. Cell model is already Unicode-correct (`Character` handles grapheme clusters); only the renderer limits it.

### Live mode switching

`ColorDepth` and `TerminalPalette` are `@Observable` properties of the app-level settings object. `RenderCoordinator` reads them each frame. Change → next frame re-projects all cells → instant visual update. No data migration.

## §6 — Daemon protocol changes

### What changes

1. **`ScreenSnapshot` grows** (per §4): adds `cursorVisible`, `activeBuffer`, `windowTitle`, `recentHistory`, `historyCapacity`, `version`. Existing fields retained.

2. **No new RPCs for MVP.** Snapshot-on-attach + raw fan-out stays sufficient because clients parse independently. Post-MVP RPC documented: `fetchHistory(sessionID:, rowRange:)`.

3. **No explicit version field on the protocol.** rTerm hasn't shipped; daemon + client always ship together in the same bundle. If that ever changes (public release, separate cadence), add `protocolVersion: Int` at the envelope level — `Codable` with `decodeIfPresent` throughout keeps that path open.

4. **`Cell` becomes `Codable` with the new style field.** `Cell.style` defaults to `.default`, so old `Cell` values decode cleanly with the default style. Nothing to design around.

5. **Session-wide palette is not in the snapshot.** Palette and `ColorDepth` are client-side user settings, not session state. Daemon stores everything at full fidelity. Different clients reattaching with different settings both render correctly.

### Wire size sanity check

- **Snapshot (cold attach):** 80 × 24 × 16B = 30 KB visible + 500 rows × 80 × 16 = 640 KB history + a few KB cursor/title/modes → ~675 KB per attach. XPC handles this easily.
- **Live fan-out:** unchanged — raw PTY bytes.

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

### Phase 1 — Colorful static terminal (MVP)

**In scope:**

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
- Test corpus: parser state transitions + cursor/erase/SGR on ScreenModel + color projection

**Deferred:**

- DEC private modes (autoWrap treated always-on, cursor always visible)
- Alt screen (writes go to main)
- DECSTBM (full-screen scroll only)
- Save/restore cursor
- Scrollback history (evicted rows discarded)
- Italic/dim/reverse/strikethrough visual rendering (parsed and stored, ignored by shader)
- Blink

**After Phase 1:** colored `ls`, colored `git diff`, correct prompts, working `clear`, correct cursor positioning. Vim/tmux/htop look acceptable but overwrite scrollback.

### Phase 2 — Full TUI + scrollback

**In scope:**

- DEC private modes: DECAWM (7), DECTCEM (25), DECCKM (1) with `KeyEncoder` hook, bracketed paste (2004)
- Alt screen modes 47 / 1047 / 1049; dual-buffer `ScreenModel`
- DECSTBM
- ESC 7/8 + CSI s/u
- `saveCursor1048` (1048)
- Scrollback history (`CircularCollection<Row>` in `ScreenModel`, bounded, main-only)
- Snapshot `recentHistory` on attach
- Scrollback UI: scroll wheel, PgUp/PgDn, scroll-to-bottom-on-new-output
- Renderer: italic + bold-italic glyph atlases materialized; dim alpha, reverse swap, strikethrough pass activated

**Deferred:**

- Per-row dirty tracking (version counter suffices)
- `fetchHistory` RPC (500-row attach snapshot sufficient)
- OSC 8 hyperlinks

**After Phase 2:** vim, tmux, htop, less, mc — all native feel. Real detach/reattach with history.

### Phase 3 — Polish

Phase 3 groups **remaining control-character extensions** (OSC 8 hyperlinks, OSC 52 clipboard, blink) alongside **adjacent future work this spec has exposed seams for** (Unicode atlas, palette UI, flyweight, dirty tracking, `fetchHistory` RPC, `Span` at boundaries). Not all of these will share one implementation plan — they're listed together because the spec has already reasoned about them.

**In scope:**

- OSC 8 hyperlinks: `CellStyle.hyperlink: Hyperlink?`; renderer hit-testing
- OSC 52 clipboard (with user-consent gate for sandbox)
- Blink: global timer uniform; shader toggle
- Unicode beyond ASCII: dynamic glyph atlas with LRU cache; CoreText fallback
- Palette chooser UI: built-in presets + custom import
- `CellStyle` flyweight (`styleID` + `StyleTable`) — scrollback memory ~50% drop
- Per-row dirty tracking
- `fetchHistory(sessionID:, rowRange:)` RPC
- `Span<Cell>` at internal boundaries where profiling shows wins

**After Phase 3:** feature-parity with iTerm2 baseline for single-session, single-window use.

### Cross-phase principles

- Every phase ends on green tests.
- Every phase preserves daemon/client protocol compatibility within its own cut. Phase boundaries may bump snapshot fields (nothing external has shipped), but within a phase the bundled daemon + client are always compatible.
- No phase introduces a feature flag. If something isn't ready, it doesn't merge.
- Phase 1 and Phase 2 each get their own implementation plan via the writing-plans skill. Phase 3 items will be planned individually as they're picked up.

## Appendix A — Open seams documented for future phases

- `Span<Cell>` at internal API boundaries
- `CellStyle` flyweight via `styleID: UInt16` + `StyleTable`
- Per-row dirty tracking in `ScreenModel` + snapshot
- `DaemonRequest.fetchHistory(sessionID:, rowRange:)` for deep backscroll
- OSC 8 (`CellStyle.hyperlink: Hyperlink?`) — Cell-shape change that motivates phase ordering
- OSC 52 clipboard (sandbox + consent work)
- GPU-side color projection (uniform palette + enum-encoded Cell colors)
- LUT-based color quantization (32K RGB bins → palette index)
- `protocolVersion` envelope field — only if daemon and client ever ship on separate cadences

## Appendix B — Non-goals

Explicitly not addressed in this spec:

- Mouse reporting (SGR 1000/1002/1006 — future work)
- Character sets (G0/G1 switching, DEC special graphics — future work)
- DCS passthrough (sixel graphics, kitty image protocol — future work)
- VT100 hard reset (RIS — out of scope)
- Multi-byte character widths (East Asian wide characters — needs tracking as a separate spec)
- Configurable keybindings (input side — separate concern)
- Per-session palette overrides (palette is client-global, not session-local)
