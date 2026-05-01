# rTerm Control Character & Escape Sequence Architecture: Exploration (2026-04-30)

## Overview

This document surveys rTerm's current parsing, event, and screen-model architecture to establish a baseline for designing improvements to **positional and control character handling**—escape sequences (CSI, OSC, DCS), C0 controls, cursor movement, text styling, and terminal modes.

---

## 1. Current State: Parser, Event, and Screen Model

### 1.1 TerminalParser (`TerminalParser.swift:34-146`)

**Role:** Converts raw PTY bytes → `[TerminalEvent]`.

**Architecture:**
- **Stateful value type** with a single mutable field: `utf8Buffer: [UInt8]` (lines 39).
  - Buffers incomplete multi-byte UTF-8 sequences across `parse()` calls.
  - For a 4-byte UTF-8 sequence, can buffer up to 3 leading bytes.

- **Single public method:** `parse(_ data: Data) -> [TerminalEvent]` (line 54).
  - Reserves capacity upfront (line 65).
  - Routes each byte through two paths:
    1. **ASCII bytes (0x00–0x7F):** Dispatched via `asciiEvent(_:)` (line 113–123).
    2. **Multi-byte UTF-8 (0x80–0xFF):** Validated, decoded, and emitted as `.printable(Character)` (lines 75–103) or `.unrecognized` on invalid encoding (line 81, 101).

**ASCII dispatch table** (`asciiEvent(_:)`, lines 113–123):
  - `0x07` → `.bell`
  - `0x08` → `.backspace`
  - `0x09` → `.tab`
  - `0x0A` → `.newline`
  - `0x0D` → `.carriageReturn`
  - `0x20–0x7E` → `.printable(Character)` (printable ASCII)
  - **Everything else** (0x00–0x06, 0x0B–0x0C, 0x0E–0x1F, 0x7F) → `.unrecognized(byte)` (line 121)

**Key limitation:** ESC (0x1B) falls into the catch-all `.unrecognized(0x1B)` case. **No escape sequence parsing happens at all.**

**UTF-8 handling:** Robust—validates lead bytes, detects incomplete sequences, rejects overlong/invalid encodings per Swift's string decoder (lines 138–145). Well-tested (see 1.3).

### 1.2 TerminalEvent (`TerminalEvent.swift:27-42`)

**Role:** Enum of all possible parsed events.

**Cases:**
```swift
public enum TerminalEvent: Sendable, Equatable {
    case printable(Character)
    case newline              // 0x0A
    case carriageReturn       // 0x0D
    case backspace            // 0x08
    case tab                  // 0x09
    case bell                 // 0x07
    case unrecognized(UInt8)  // Catch-all for unparsed bytes
}
```

**Observations:**
- **No cursor-movement events** (e.g., no `.cursorUp`, `.cursorDown`, `.cursorToPosition(row, col)`).
- **No styling events** (e.g., no `.boldOn`, `.colorForeground`, `.underline`).
- **No mode events** (e.g., no `.enableAlternateScreen`, `.setAutoWrap`).
- **No erase events** (e.g., no `.eraseLine`, `.eraseDisplay`).
- **No scroll-region or other advanced events**.

The enum is deliberately minimal—designed as a **passthrough** for only the simplest controls.

### 1.3 ScreenModel (`ScreenModel.swift:41–235`)

**Role:** Actor that owns the grid, processes events, and publishes snapshots.

**Grid storage** (lines 51–92):
- Flat row-major `grid: ContiguousArray<Cell>` (line 51).
- Dimensions: `cols: Int`, `rows: Int` (lines 57–60).
- Cursor: `cursor: Cursor` (line 54).
- Snapshot cache: `_latestSnapshot: OSAllocatedUnfairLock<ScreenSnapshot>` (line 63) for lock-protected non-isolated access from the render thread.

**Event application** (`apply(_:)`, lines 115–155):
- Single-pass loop over events (line 118).
- Per-event handling (lines 119–149):

  | Event | Behavior |
  |-------|----------|
  | `.printable(char)` | Execute deferred wrap if `cursor.col >= cols` (lines 121–127); write cell at `grid[cursor.row * cols + cursor.col] = Cell(char)` (line 128); increment `cursor.col` (line 129). |
  | `.newline` | `cursor.col = 0`; `cursor.row += 1` (lines 132–133); scroll if `cursor.row >= rows` (lines 134–136). |
  | `.carriageReturn` | `cursor.col = 0` (line 139). |
  | `.backspace` | `cursor.col = max(0, cursor.col - 1)` (line 142). |
  | `.tab` | `cursor.col = min(cols - 1, ((cursor.col / 8) + 1) * 8)` (line 145). Hard-coded to multiples of 8, clamped to last column. |
  | `.bell`, `.unrecognized` | No-op (line 147–148). |

- After all events: update lock-protected snapshot cache (lines 153–154).

**Deferred wrapping** (lines 111–114, 121–127):
- When a character is written at column `cols - 1`, cursor advances to `cursor.col == cols` (past the edge).
- Wrap does **not** execute immediately; it defers until the next printable character.
- On the next printable, if `cursor.col >= cols`: reset `cursor.col = 0`, increment row, scroll if needed.
- This prevents double-advancing on newline after a full row.

**Scroll** (`scrollUp()`, lines 218–234):
- Moves rows 1..<rows into 0..<rows-1 in the flat array (lines 221–227).
- Clears the last row (lines 228–232).
- Clamps cursor row to `rows - 1` (line 233).

**No cursor movement:** There are no events to move the cursor to an arbitrary position (e.g., CSI H). The model only handles newline, CR, backspace, and tab.

### 1.4 Cell and ScreenSnapshot (`Cell.swift:28–157`)

**Cell** (lines 28–63):
- Holds a single `character: Character` (line 30).
- Minimal: no color, bold, underline, or other attributes.
- Value type, `Sendable`, `Codable`.

**Cursor** (lines 71–82):
- `row: Int`, `col: Int` (lines 73–75).
- Zero-based indices.

**ScreenSnapshot** (lines 94–157):
- Immutable snapshot of screen state: `cells: ContiguousArray<Cell>`, `cols: Int`, `rows: Int`, `cursor: Cursor` (lines 96–102).
- 2D subscript `[row, col]` for convenience (lines 123–125).
- `Codable` for serialization over daemon protocol.

**Observation:** No styling metadata in cells—`Cell` is deliberately simple.

### 1.5 Storage: ScreenBuffer and CircularCollection

**ScreenBuffer** (`ScreenBuffer.swift:11–75`):
- Generic actor wrapper around `CircularCollection` (line 13).
- Mostly placeholder: `append(data:)` logs but does nothing (lines 19–22).
- Has a stub `YAScreenBuffer` (lines 39–75) that is unused.
- **Not currently used by the main flow.**

**CircularCollection** (`CircularCollection.swift:12–118`):
- Generic circular buffer for scrollback (prepend/append O(1)).
- Used by `ScreenBuffer` but not integrated into the main PTY → parser → model flow.
- **Future use case:** Likely intended for history/scrollback, not yet wired.

---

## 2. Gaps: What's Missing

### 2.1 No Escape Sequence Parsing

**Current:**
- ESC (0x1B) is emitted as `.unrecognized(0x1B)` (line 121 in `TerminalParser.swift`).
- Downstream: `.unrecognized` is silently dropped by `ScreenModel.apply()` (line 147–148).
- **Effect:** All escape sequences (CSI, OSC, DCS, SS2, SS3) are discarded.

**Missing:**
- No state machine to recognize escape-sequence families.
- No buffer to accumulate multi-byte sequences like `ESC [ 5 ; 10 H`.
- No dispatch to specific handlers (CSI vs. OSC vs. DCS).
- No event types to represent parsed sequences.

### 2.2 No CSI (Cursor Positioning and Editing)

**Common CSI sequences:** `ESC [ ... <letter>`, where `<letter>` is the final byte.

**Not implemented:**
- **Cursor movement:** CUU (A), CUD (B), CUF (C), CUB (D), CUP (H), HVP (f), CHA (G), VPA (d).
  - Example: `ESC [ 5 ; 10 H` → move cursor to row 5, col 10.
  - **Current:** No way to move cursor to an arbitrary position (only via newline, CR, backspace, tab).
  
- **Erasing:** ED (J), EL (K).
  - Example: `ESC [ 2 J` → erase entire display.
  - Example: `ESC [ K` → erase to end of line.
  - **Current:** No erase capability; cells are only overwritten by printing.

- **SGR (Select Graphic Rendition):** `ESC [ ... m` → colors, bold, underline, reverse, etc.
  - Example: `ESC [ 1 ; 31 m` → bold red text.
  - **Current:** No styling events; cells have no color or attribute metadata.

- **Modes (DEC private modes):** `ESC [ ? <num> h/l`.
  - DECAWM (1049): Auto-wrap mode.
  - DECCKM (1): Cursor keys (application vs. normal mode).
  - DECTCEM (25): Cursor visibility.
  - Alternate screen (1049): Save/restore screen buffer.
  - **Current:** No mode state; wrap is always on, cursor always visible.

- **Scroll regions:** DECSTBM `ESC [ <top> ; <bottom> r`.
  - **Current:** No scroll-region tracking; scrolls always affect the entire screen.

### 2.3 No OSC (Operating System Command)

**Format:** `ESC ] ... <terminator>` (terminator is BEL or `ESC \`).

**Common OSC:**
- OSC 0: Set both window title and icon name.
- OSC 2: Set window title.
- OSC 8: Set hyperlink (URL).
- OSC 52: Clipboard integration (copy/paste).

**Current:** No OSC parsing or handling.

### 2.4 No DCS, SS2, SS3

- **DCS (Device Control String):** `ESC P ... ESC \` — rarely used in basic terminals.
- **SS2/SS3:** Single-shift 2/3 — uncommon in modern terminals.
- Not prioritized but worth tracking.

### 2.5 Limited C0 Control Coverage

**Currently recognized C0 controls:**
- 0x07 (BEL), 0x08 (BS), 0x09 (HT), 0x0A (LF), 0x0D (CR).

**Missing:**
- 0x00 (NUL): Often ignored, but should not corrupt state.
- 0x0B (VT): Vertical tab — rare, but some terminal output uses it.
- 0x0C (FF): Form feed — scrolls a page.
- 0x0E (SO), 0x0F (SI): Shift out/in for alternate character sets (rare).
- 0x1B (ESC): Recognized but not parsed into sequences.
- 0x7F (DEL): Backspace variant; rare in modern use.

**Current behavior:** All unrecognized C0 controls (0x00–0x1F except the 5 above, plus 0x7F) are emitted as `.unrecognized(byte)` and then silently dropped by the screen model.

### 2.6 No Cell Attributes

**Current `Cell` structure:**
```swift
public struct Cell: Sendable, Equatable, Codable {
    public var character: Character
}
```

**Missing:**
- Foreground color (8 ANSI colors, 256 extended colors, or 24-bit RGB).
- Background color.
- Bold, dim, italic, underline, blink, reverse, strikethrough.
- Any charset or alternate-font flags.

**Implication:** Even if SGR events are parsed, there's no place to store the style. The renderer would need updates too (see 2.8).

### 2.7 No Terminal Mode State

**No mode tracking:**
- Auto-wrap (DECAWM): Currently always on.
- Cursor key (DECCKM): No distinction between application and normal cursor key codes.
- Cursor visibility (DECTCEM): No way to hide/show cursor.
- Alternate screen (1049): No ability to switch between main and alternate buffers.
- Insert/replace mode (IRM): Always in replace.
- Newline mode (LNM): LF alone is treated the same as CR+LF; no way to distinguish.

**Current:** Hardcoded behavior; no state to change.

### 2.8 Renderer Assumptions

**TermView.swift** (lines 32–56):
- Metal-based rendering.
- Reads `ScreenModel.latestSnapshot()` on the render thread.
- Uses `GlyphAtlas` to rasterize printable ASCII (0x20–0x7E) (lines 28–43).

**GlyphAtlas.swift** (lines 28–80):
- Rasterizes **only printable ASCII** (0x20–0x7E) into a 16×6 grid of monospace glyphs.
- Single-channel grayscale texture (`.r8Unorm`).
- No support for colors, styles, or extended Unicode beyond ASCII.

**Current assumptions the renderer makes:**
1. All cells contain a single graphic character.
2. All cells render with the same foreground and background colors (implicitly black on white or white on black).
3. No bold, underline, or other styling.
4. No colored text.

**For styled output to work:** The renderer would need to:
1. Extend `Cell` with color/attribute metadata.
2. Generate or cache multiple glyph variants (bold, italic, etc.).
3. Modify the shader to apply foreground and background colors.
4. Possibly extend the atlas or use a more dynamic glyph cache.

---

## 3. Test Coverage

### 3.1 TerminalParserTests (`TerminalParserTests.swift`)

**Line 26–162:** Comprehensive UTF-8 and control-character coverage.

**What IS tested:**
- ✅ ASCII text (line 30–39).
- ✅ Individual control characters: LF, CR, BS, HT, BEL (line 44–49).
- ✅ Mixed text and controls (line 53–62).
- ✅ Unrecognized byte (line 67–70).
- ✅ Multi-byte UTF-8: 2-byte (é), 3-byte (中), 4-byte (😀) (line 75–127).
- ✅ Split UTF-8 across parse calls (line 84–93, 131–151).
- ✅ Overlong lead bytes rejected (line 155–161).

**What is NOT tested:**
- ❌ ESC (0x1B) escape sequences (CSI, OSC, DCS).
- ❌ Any escape-sequence parsing or buffering.
- ❌ Edge cases around escape sequence boundaries.

### 3.2 ScreenModelTests (`ScreenModelTests.swift`)

**Line 26–280:** Comprehensive cursor movement and grid manipulation.

**What IS tested:**
- ✅ Printing characters (line 30–38).
- ✅ Newline (line 42–50).
- ✅ Carriage return (line 54–66).
- ✅ Backspace (line 70–82, 86–92).
- ✅ Tab (line 96–107).
- ✅ Line wrap (line 111–125).
- ✅ Scroll up (line 129–151).
- ✅ Unrecognized events ignored (line 155–163).
- ✅ Bell is no-op (line 167–175).
- ✅ Snapshot semantics and restore (line 179–244).
- ✅ Deferred wrap then newline (line 264–279).

**What is NOT tested:**
- ❌ Arbitrary cursor positioning (no events exist).
- ❌ Erasing (no events exist).
- ❌ Styling / SGR (no events or attributes exist).
- ❌ Mode changes (no mode state exists).
- ❌ Scroll regions (not implemented).
- ❌ Alternate screen (not implemented).

---

## 4. Integration Surface: Where New Handling Would Plug In

### 4.1 Parser → Event Type → ScreenModel Data Flow

```
PTY bytes
    ↓
TerminalParser.parse(_:)           [Line 54]
    ↓
[TerminalEvent]
    ↓
ScreenModel.apply(_:)              [Line 115]
    ↓
Cursor move, grid mutation
    ↓
ScreenModel.latestSnapshot()        [Line 198] (non-isolated)
    ↓
RenderCoordinator reads snapshot    [TermView.swift:64]
    ↓
Metal rendering
```

### 4.2 Where New Escape Sequence Handling Needs to Integrate

**Option A: Parser-Only Dispatch (Structural Events)**
- Parser buffers multi-byte sequences and emits structured `.csi(.cursorUp(5))`, `.sgr([.bold, .red])`, etc.
- Screen model dispatches on detailed event types.
- **Pros:** Clean separation; events are self-contained.
- **Cons:** Parser becomes more complex; tightly couples parser to terminal semantics.

**Option B: Parser → Raw Sequence Events → Screen Model Interpretation**
- Parser emits generic `.escapeSequence(family: .csi, bytes: [...])` or similar.
- Screen model parses and interprets the bytes.
- **Pros:** Parser remains simple; screen model owns terminal semantics.
- **Cons:** Screen model becomes more complex; harder to test parser in isolation.

**Option C: Parser → State Machine in a Separate Layer**
- Parser emits raw bytes for ESC and onwards.
- A `TerminalStateMachine` or `SequenceParser` sits between parser and ScreenModel.
- Screen model only sees structured events.
- **Pros:** Decoupled; reusable parsing logic; clear separation of concerns.
- **Cons:** Another layer of indirection.

### 4.3 Changes Required Across the Stack

**TerminalParser:**
- Add escape-sequence state machine (states: GROUND, ESC, CSI, OSC, etc.).
- Add buffer for multi-byte sequences.
- Emit new event types on sequence completion or error.

**TerminalEvent:**
- Add cases for cursor movement: `.csiCursorUp(Int)`, `.csiCursorDown(Int)`, ..., `.csiCursorToPosition(row: Int, col: Int)`.
- Add cases for erasing: `.csiEraseDisplay(Int)`, `.csiEraseLine(Int)`.
- Add cases for SGR: `.csiSetGraphicRendition([TerminalAttribute])`.
- Add cases for modes: `.csiSetMode(Int, on: Bool)`.
- Add cases for scroll regions, OSC, etc.
- Consider a grouped enum: `.csi(CSIEvent)`, `.osc(OSCEvent)`, etc.

**Cell:**
- Add optional `foregroundColor: TerminalColor?`.
- Add optional `backgroundColor: TerminalColor?`.
- Add optional `attributes: Set<CellAttribute>` (bold, underline, reverse, etc.).
- Increases size but necessary for styling.

**ScreenModel.apply(_:):**
- Handle cursor-movement events: update `cursor` directly or via new private methods.
- Handle erase events: clear cells in grid.
- Handle SGR: apply attributes to cells written afterward.
- Track and apply mode state (auto-wrap, alternate screen, etc.).
- Implement scroll regions (deferred feature).

**Daemon protocol (DaemonProtocol.swift):**
- If extended `Cell` carries color/attribute data, ensure it serializes properly.
- May need version negotiation if clients differ in styling support.

**Renderer (TermView.swift, GlyphAtlas.swift):**
- Extend rendering pipeline to apply cell colors as shader inputs.
- Cache or generate bold/italic/underline glyph variants.
- Update fragment shader to composite foreground and background colors.
- Handle cells with style attributes.

---

## 5. Terminal Standards Shopping List

### 5.1 Tier 1: V1 (Minimal Viable Terminal)

**Must-have for basic shell output:**

1. **C0 Controls (Already mostly done):**
   - ✅ BEL (0x07), BS (0x08), HT (0x09), LF (0x0A), CR (0x0D).
   - ⚠️ Add: NUL (0x00), VT (0x0B), FF (0x0C) — mostly pass-through or scroll.

2. **CSI Cursor Movement:**
   - CUU (A), CUD (B), CUF (C), CUB (D): Single-step cursor movement.
   - CUP (H) or HVP (f): Absolute positioning `ESC [ row ; col H`.
   - **Why:** Essential for prompt placement, menu UIs, and full-screen apps (vim, less, htop).

3. **CSI Erase:**
   - ED (J): Erase display (full, from cursor, to end).
   - EL (K): Erase line (full, from cursor, to end).
   - **Why:** TUIs clear the screen; without this, text accumulates junk.

4. **Basic SGR (Select Graphic Rendition):**
   - Bold (1), reset (0).
   - 16-color foreground (30–37, 90–97) and background (40–47, 100–107).
   - **Why:** Many CLI tools output colored errors (red) and status (green); bold highlights.

5. **Modes (Minimal):**
   - DECAWM (auto-wrap mode, enable/disable).
   - **Why:** Some apps disable wrap for custom display logic.

### 5.2 Tier 2: V2 (Full-featured TUI)

**Adds support for richer TUIs:**

1. **Extended CSI:**
   - CHA (G), VPA (d): Line-absolute positioning.
   - DECSTBM (r): Set scroll region.
   - ED/EL variations: Partial erases (from cursor up, etc.).

2. **Full SGR:**
   - Dim (2), italic (3), underline (4), blink (5), reverse (7), strikethrough (9).
   - 256-color palette (38;5;n, 48;5;n).
   - 24-bit RGB color (38;2;r;g;b, 48;2;r;g;b).

3. **Alternate screen (1049):**
   - Save/restore screen buffer on application start/end.
   - **Why:** vim, tmux, and similar apps rely on this.

4. **Cursor visibility (DECTCEM, 25):**
   - Hide/show cursor.

5. **Additional modes:**
   - DECCKM (cursor key application mode).
   - DECLRM (left-right margin).
   - IRM (insert mode).

6. **OSC (Partial):**
   - OSC 0 / OSC 2: Window title.
   - **Why:** Apps set the terminal window title.

### 5.3 Tier 3: V3 (Advanced, Edge Cases)

**Rare but supported by xterm/Terminal.app:**

1. **Advanced CSI:**
   - DECSLRM: Left-right margins.
   - Scroll up/down (S/T).
   - Character attribute operations (SGR for specific cells).

2. **OSC (Full):**
   - OSC 8: Hyperlinks.
   - OSC 52: Clipboard (copy/paste).
   - OSC 9: iTerm2 annotations.

3. **Character sets (G0/G1 switching):**
   - Alternate character sets (line drawing, etc.).

4. **Mouse reporting:**
   - X11 mouse tracking (not parsing input, but apps assume it).

5. **DCS / kitty graphics protocol:**
   - Future extensibility for images and advanced features.

---

## 6. Open Questions for Brainstorming

### 6.1 Escape Sequence Event Design

**Q: Should the parser emit structured events or raw sequences?**

Example for CSI cursor positioning:
- **Structured:** `.csi(.cursorToPosition(row: 5, col: 10))` — parser fully decodes.
- **Raw:** `.escapeSequence(.csi, bytes: [UInt8(0x35), UInt8(0x3B), UInt8(0x31), UInt8(0x30), UInt8(0x48)])` — parser buffers, ScreenModel interprets.

**Trade-offs:**
- Structured is easier to consume but couples the parser to semantics.
- Raw is more flexible but requires ScreenModel to parse bytes.
- **Recommendation:** Start with **structured** for Tier 1 (cursor, erase, SGR); extend to raw if a second parsing layer is needed.

### 6.2 Cell Attribute Storage

**Q: How should `Cell` store color and style?**

Options:
- Add fields: `foregroundColor: TerminalColor?`, `backgroundColor: TerminalColor?`, `attributes: Set<CellAttribute>`.
- Use a bit-packed integer: `attributes: UInt64` (32 bits for color, 16 for styles, etc.).
- Separate storage: Keep `Cell` minimal; store attributes in a parallel array-of-structs.

**Trade-offs:**
- Flat fields are simple and codable but increase `Cell` size.
- Bit-packing is compact but less readable and harder to extend.
- Parallel storage complicates snapshot serialization.

**Recommendation:** **Flat optional fields** for now. `Cell` size becomes ~64 bytes (still small); trade-off is worth the clarity.

### 6.3 Alternate Screen Buffer

**Q: Should the main ScreenModel hold both normal and alternate buffers, or create a separate abstraction?**

Options:
- **Dual-buffer ScreenModel:** `buffer: [Cell]` + `altBuffer: [Cell]`; mode switch flips which is active.
- **ScreenModel factory:** Separate instance per buffer; DaemonClient/App manages switching.
- **Wrapper:** `ScreenModelContainer` holds two models and delegates to the active one.

**Trade-offs:**
- Dual-buffer is simplest for the caller but adds state to ScreenModel.
- Factory pattern separates concerns but requires external switching logic.
- Wrapper is middle ground.

**Recommendation:** **Dual-buffer ScreenModel.** Most terminals handle it this way; the model knows its own lifecycle.

### 6.4 Scroll Region and Scroll History

**Q: Are scroll regions (top/bottom margins) separate from a scrollback buffer?**

Current state:
- No scrollback buffer (`ScreenBuffer` is unused).
- Scrolling discards row 0.
- No `CircularCollection` integration.

**Future consideration:**
- Scrollback is valuable for users (scroll wheel, Page Up).
- Separate from scroll regions (DECSTBM), which are per-application settings.
- Probably a v2+ feature, but worth designing for now.

**Recommendation:** **Track separately.** Scroll regions live in ScreenModel mode state. Scrollback is a separate concern (maybe `HistoryBuffer` class, fed by scroll events, queried by the renderer).

### 6.5 Parser Buffering Strategy

**Q: Should the parser buffer incomplete sequences or throw them away?**

Current:
- UTF-8 sequences are buffered across `parse()` calls.

Escape sequences:
- A CSI might span multiple PTY chunks: `[0x1B, 0x5B, ...]` in one chunk, then `[... 0x48]` in the next.
- **Option A:** Buffer incomplete sequences and emit on completion.
- **Option B:** Emit incomplete sequences as `.unrecognized` and lose them.

**Recommendation:** **Buffer incomplete sequences.** Mirrors UTF-8 approach; necessary for correctness over slow networks or high-frequency PTY chunks. Adds complexity but is required.

### 6.6 Daemon / Client Protocol Changes

**Q: If cells now carry colors/attributes, do all clients need to handle them?**

Current:
- `ScreenSnapshot` is `Codable`, sent over the daemon–client link.
- Client may be older and not understand new `Cell` fields.

**Option A:** Version the snapshot protocol; old clients ignore new fields.
**Option B:** Require all clients to update together.
**Option C:** Send only "compatible" snapshots over the wire; clients request feature level.

**Recommendation:** **Version (Option A).** Graceful degradation is good UX. Use a `protocolVersion` field in the snapshot; clients skip unsupported fields. For now, start without versioning, but design for it (e.g., `Cell` decoding with `decodeIfPresent` for optional fields).

---

## 7. Summary: Top Findings

### 7.1 Parser is a Clean Slate for Escape Sequences

- Currently only routes ASCII to a flat 6-case table; ESC falls through as `.unrecognized(0x1B)`.
- UTF-8 multi-byte buffering is robust and well-tested, providing a good template for escape-sequence buffering.
- Adding a state machine for ESC sequences here is the logical integration point.

### 7.2 Event Type Needs Major Expansion

- Today's 6 cases (`printable`, `newline`, `carriageReturn`, `backspace`, `tab`, `bell`) don't cover cursor movement, erasing, or styling.
- Design decision needed: structured events (e.g., `.csi(.cursorUp(5))`) vs. raw sequences for ScreenModel to interpret.
- Recommend structured for Tier 1 (cursor, erase, basic SGR).

### 7.3 ScreenModel is Ready for Cursor Positioning

- Already handles cursor, grid, and wrapping correctly.
- Adding methods like `moveCursorAbsolute(row, col)`, `eraseLine()`, `eraseDisplay()` is straightforward.
- Deferred wrapping logic is subtle but correct; new cursor-move events must respect it.

### 7.4 Cell Needs Attributes, But Carefully

- Current `Cell` holds only `character`; no color, style, or metadata.
- Adding optional `foregroundColor`, `backgroundColor`, `attributes` fields is the simplest approach.
- Renderer needs updates to actually use these (shader changes, glyph variants, color compositing).

### 7.5 Renderer Footprint is Significant

- GlyphAtlas rasterizes only ASCII printable (0x20–0x7E) into a monospace grid.
- For styling and colors to work, the renderer must:
  - Extend Cell with color/attribute metadata.
  - Cache bold/italic glyph variants (or use a more dynamic approach).
  - Update the Metal fragment shader to composite colors.
- This is a v1.5+ effort, not blocking basic sequence parsing.

### 7.6 Test Coverage is Excellent for Today's Feature Set

- Both parser and screen model have comprehensive tests for the features they support.
- UTF-8 edge cases are well-covered.
- No tests for escape sequences or styling (because they don't exist yet).
- Adding new features should be test-driven (TDD).

---

## Appendix A: File Inventory

| File | Purpose | Key Lines |
|------|---------|-----------|
| `TerminalParser.swift` | Byte-to-event parser; UTF-8 decoding. | 34–146 |
| `TerminalEvent.swift` | Event enum (6 cases). | 27–42 |
| `ScreenModel.swift` | Grid, cursor, event application, snapshot. | 41–235 |
| `Cell.swift` | Cell, Cursor, ScreenSnapshot structs. | 28–157 |
| `ScreenBuffer.swift` | Unused generic buffer; `CircularCollection` wrapper. | 11–75 |
| `CircularCollection.swift` | Generic circular buffer for future scrollback. | 12–118 |
| `TerminalParserTests.swift` | 13 comprehensive UTF-8 and control tests. | 26–162 |
| `ScreenModelTests.swift` | 16 comprehensive grid and cursor tests. | 26–280 |
| `TermView.swift` | Metal rendering coordinator. | 32–56 (excerpt) |
| `GlyphAtlas.swift` | Glyph rasterization (ASCII 0x20–0x7E). | 28–80 (excerpt) |

---

## Appendix B: Relevant Code Snippets

### Parser ASCII Dispatch Table

```swift
// TerminalParser.swift:113–123
private static func asciiEvent(_ byte: UInt8) -> TerminalEvent {
    switch byte {
    case 0x07: return .bell
    case 0x08: return .backspace
    case 0x09: return .tab
    case 0x0A: return .newline
    case 0x0D: return .carriageReturn
    case 0x20 ... 0x7E: return .printable(Character(UnicodeScalar(byte)))
    default: return .unrecognized(byte)  // All other bytes, including 0x1B (ESC)
    }
}
```

### ScreenModel Event Application

```swift
// ScreenModel.swift:115–155
public func apply(_ events: [TerminalEvent]) {
    for event in events {
        switch event {
        case .printable(let char):
            if cursor.col >= cols {
                cursor.col = 0
                cursor.row += 1
                if cursor.row >= rows { scrollUp() }
            }
            grid[cursor.row * cols + cursor.col] = Cell(character: char)
            cursor.col += 1
        case .newline:
            cursor.col = 0
            cursor.row += 1
            if cursor.row >= rows { scrollUp() }
        case .carriageReturn:
            cursor.col = 0
        case .backspace:
            cursor.col = max(0, cursor.col - 1)
        case .tab:
            cursor.col = min(cols - 1, ((cursor.col / 8) + 1) * 8)
        case .bell, .unrecognized:
            break
        }
    }
    let snap = ScreenSnapshot(cells: grid, cols: cols, rows: rows, cursor: snapshotCursor())
    _latestSnapshot.withLock { $0 = snap }
}
```

---

**End of Exploration Document**
