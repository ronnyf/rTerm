# Dumb Terminal Foundation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **IMPORTANT — Pseudocode strategy:** This plan provides pseudocode and behavioral descriptions rather than literal Swift source. You are a Swift expert — translate the pseudocode into the most idiomatic, efficient Swift possible. Use modern Swift patterns (actors, structured concurrency, `consuming`/`borrowing` where appropriate, `@inlinable`, etc.). The pseudocode specifies *what* each piece does; you decide *how* to express it in Swift. When the pseudocode says "accumulate bytes," you choose the right buffer type. When it says "lookup table," you choose `Dictionary` vs. a fixed-size array indexed by ASCII value — whichever is faster.

**Goal:** Build the minimum pipeline for a working dumb terminal session — parser, screen model, Metal renderer, keyboard input.

**Architecture:** Raw bytes from the XPC shell output are parsed into `TerminalEvent`s, applied to a `ScreenModel` actor (flat grid + cursor), and rendered each frame by Metal via a glyph atlas. Keyboard input flows the reverse direction through a `KeyEncoder` → XPC → PTY write.

**Tech Stack:** Swift 5, SwiftUI, Metal, MetalKit, Core Text, AsyncAlgorithms, XPCOverlay, Swift Testing

**Spec:** `docs/superpowers/specs/2026-04-06-dumb-terminal-foundation-design.md`

---

## File Map

### New Files

| File | Target | Description |
|---|---|---|
| `TermCore/TerminalEvent.swift` | TermCore | Event enum (shared between parser and screen model) |
| `TermCore/TerminalParser.swift` | TermCore | Byte stream → events |
| `TermCore/Cell.swift` | TermCore | Cell, Cursor, ScreenSnapshot types |
| `TermCore/ScreenModel.swift` | TermCore | Actor — grid state + cursor + snapshot |
| `rTerm/KeyEncoder.swift` | rTerm | NSEvent → bytes for PTY |
| `rTerm/GlyphAtlas.swift` | rTerm | Core Text rasterization → MTLTexture |
| `rTerm/Shaders.metal` | rTerm | Vertex + fragment shaders |
| `TermCoreTests/TerminalParserTests.swift` | TermCoreTests | Parser tests |
| `TermCoreTests/ScreenModelTests.swift` | TermCoreTests | Screen model tests |

### Modified Files

| File | Changes |
|---|---|
| `TermCore/XPCRequest.swift` | Add `RemoteCommand.input(Data)` case |
| `rTermSupport/PTYResponder.swift` | Handle `.input` — write bytes to PTY primary FD |
| `rTerm/TermView.swift` | Rewrite `RenderCoordinator` with atlas, pipeline, draw loop; make MTKView subclass for key input |
| `rTerm/ContentView.swift` | Replace `Term` class with `TerminalSession`; swap UI to `TermView` |
| `rTerm.xcodeproj/project.pbxproj` | Add all new files to their targets |

---

## Task 1: TerminalEvent Enum

**Files:**
- Create: `TermCore/TerminalEvent.swift`

This is a shared type used by both the parser (output) and the screen model (input). Define it first so subsequent tasks can reference it.

- [ ] **Step 1: Create `TerminalEvent.swift`**

```pseudo
// Public enum in TermCore module
// Cases:
//   printable(Character)   — a displayable Unicode character
//   newline                — LF 0x0A
//   carriageReturn         — CR 0x0D
//   backspace              — BS 0x08
//   tab                    — HT 0x09
//   bell                   — BEL 0x07
//   unrecognized(UInt8)    — passthrough for bytes we don't handle yet
//
// Must be Sendable (all associated values are Sendable).
// Must be Equatable (needed for test assertions).
```

- [ ] **Step 2: Add file to TermCore target in Xcode project**

Add `TerminalEvent.swift` to the TermCore target's Sources build phase in `rTerm.xcodeproj/project.pbxproj`.

- [ ] **Step 3: Build TermCore to verify**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCore -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```
git add TermCore/TerminalEvent.swift rTerm.xcodeproj/project.pbxproj
git commit -m "feat(TermCore): add TerminalEvent enum"
```

---

## Task 2: TerminalParser — Tests First

**Files:**
- Create: `TermCoreTests/TerminalParserTests.swift`
- Create: `TermCore/TerminalParser.swift`

The parser is a struct with mutating method `parse(_ data: Data) -> [TerminalEvent]`. It handles UTF-8 decoding and control character recognition.

- [ ] **Step 1: Write parser tests**

Create `TermCoreTests/TerminalParserTests.swift`. Use Swift Testing (`@Test`, `#expect`).

```pseudo
// Test: ASCII text
//   Input: Data from "Hello"
//   Expected: [.printable("H"), .printable("e"), .printable("l"), .printable("l"), .printable("o")]

// Test: control characters
//   Input: bytes [0x0A, 0x0D, 0x08, 0x09, 0x07]
//   Expected: [.newline, .carriageReturn, .backspace, .tab, .bell]

// Test: mixed text and controls
//   Input: Data from "AB" + [0x0A] + Data from "C"
//   Expected: [.printable("A"), .printable("B"), .newline, .printable("C")]

// Test: unrecognized byte
//   Input: [0x01]  (SOH — not in our handled set)
//   Expected: [.unrecognized(0x01)]

// Test: multi-byte UTF-8
//   Input: Data from "é" (0xC3 0xA9, two bytes)
//   Expected: [.printable("é")]

// Test: split multi-byte UTF-8 across chunks
//   Input chunk 1: [0xC3]  (first byte of "é")
//   Input chunk 2: [0xA9]  (second byte of "é")
//   Expected from chunk 1: []  (incomplete sequence, buffered)
//   Expected from chunk 2: [.printable("é")]

// Test: CR+LF sequence (common in terminal output)
//   Input: [0x0D, 0x0A]
//   Expected: [.carriageReturn, .newline]  (two separate events)
```

- [ ] **Step 2: Add test file to TermCoreTests target in pbxproj**

- [ ] **Step 3: Run tests to see them fail**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test`
Expected: FAIL — `TerminalParser` not defined

- [ ] **Step 4: Implement `TerminalParser`**

Create `TermCore/TerminalParser.swift`:

```pseudo
// Public struct TerminalParser
// Internal state: a small byte buffer for incomplete UTF-8 sequences
//
// mutating func parse(_ data: Data) -> [TerminalEvent]:
//   Walk each byte in data:
//     If we have buffered bytes (incomplete UTF-8):
//       Append this byte to the buffer
//       Try to decode the buffer as a complete UTF-8 scalar
//       If complete: emit .printable(Character), clear buffer
//       If still incomplete: continue to next byte
//       If invalid: emit .unrecognized for each buffered byte, clear buffer
//
//     Else, examine the byte:
//       0x07 → .bell
//       0x08 → .backspace
//       0x09 → .tab
//       0x0A → .newline
//       0x0D → .carriageReturn
//       0x20...0x7E → .printable(Character from ASCII)
//       High bit set (0x80+) → start UTF-8 accumulation
//         If this is a leading byte (0xC0+): buffer it, expected length from leading byte
//         If this is a continuation byte without a leading byte: .unrecognized
//       Everything else (0x00-0x06, 0x0B, 0x0C, 0x0E-0x1F except handled) → .unrecognized
//
//   Return collected events array
//
// Design notes for the implementer:
//   - Consider using Swift's built-in Unicode.UTF8 codec for the multi-byte handling
//     rather than hand-rolling byte classification. The codec handles all edge cases.
//   - The struct must be Sendable. The internal buffer is a value type so this is free.
//   - Performance: this runs on every data chunk from the PTY. Avoid allocations in the
//     hot path where possible. Pre-size the result array if you can estimate from data.count.
```

- [ ] **Step 5: Add `TerminalParser.swift` to TermCore target in pbxproj**

- [ ] **Step 6: Run tests to see them pass**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test`
Expected: All parser tests PASS

- [ ] **Step 7: Commit**

```
git add TermCore/TerminalParser.swift TermCoreTests/TerminalParserTests.swift rTerm.xcodeproj/project.pbxproj
git commit -m "feat(TermCore): add TerminalParser with tests"
```

---

## Task 3: Cell, Cursor, and ScreenSnapshot Types

**Files:**
- Create: `TermCore/Cell.swift`

Value types used by the screen model and the renderer. Defined separately so the renderer (in rTerm target) can import them from TermCore without importing the actor.

- [ ] **Step 1: Create `Cell.swift`**

```pseudo
// Public struct Cell: Sendable, Equatable
//   character: Character (default: " ")
//   Provide a static `empty` convenience → Cell(character: " ")

// Public struct Cursor: Sendable, Equatable
//   row: Int
//   col: Int

// Public struct ScreenSnapshot: Sendable
//   cells: ContiguousArray<Cell>   — flat row-major grid
//   cols: Int
//   rows: Int
//   cursor: Cursor
//
//   Provide a subscript for (row, col) access → cells[row * cols + col]
//   This is a read-only view; the screen model is the only writer.
```

- [ ] **Step 2: Add to TermCore target in pbxproj**

- [ ] **Step 3: Build TermCore to verify**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCore -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```
git add TermCore/Cell.swift rTerm.xcodeproj/project.pbxproj
git commit -m "feat(TermCore): add Cell, Cursor, ScreenSnapshot types"
```

---

## Task 4: ScreenModel — Tests First

**Files:**
- Create: `TermCoreTests/ScreenModelTests.swift`
- Create: `TermCore/ScreenModel.swift`

The screen model is an actor that owns the grid and cursor, accepts `[TerminalEvent]`, and publishes snapshots for the renderer.

- [ ] **Step 1: Write screen model tests**

Create `TermCoreTests/ScreenModelTests.swift`:

```pseudo
// All tests use a small grid (e.g. 4 cols × 3 rows) for readability.
// Use async test functions since ScreenModel is an actor.

// Test: print characters
//   Create 4×3 model
//   Apply: [.printable("A"), .printable("B")]
//   Assert: snapshot cell (0,0) = "A", cell (0,1) = "B"
//   Assert: cursor at row=0, col=2

// Test: newline
//   Apply: [.printable("A"), .newline, .printable("B")]
//   Assert: cell (0,0) = "A", cell (1,0) = "B"
//   Assert: cursor at row=1, col=1

// Test: carriage return
//   Apply: [.printable("A"), .printable("B"), .carriageReturn, .printable("X")]
//   Assert: cell (0,0) = "X"  (overwrote "A"), cell (0,1) = "B"
//   Assert: cursor at row=0, col=1

// Test: backspace
//   Apply: [.printable("A"), .printable("B"), .backspace, .printable("X")]
//   Assert: cell (0,0) = "A", cell (0,1) = "X"  (overwrote "B")

// Test: backspace at column 0 (clamp)
//   Apply: [.backspace]
//   Assert: cursor stays at row=0, col=0

// Test: tab
//   Apply: [.printable("A"), .tab, .printable("B")]
//   Assert: cell (0,0) = "A", cell (0,8) = "B"  (tab stop at 8)
//   Assert: cursor at row=0, col=9

// Test: line wrap
//   4-col grid: apply 5 printable characters "ABCDE"
//   Assert: row 0 = "ABCD", row 1 col 0 = "E"
//   Assert: cursor at row=1, col=1

// Test: scroll up
//   3-row grid: fill all 3 rows, then newline + print
//   Assert: original row 0 content is gone (scrolled off)
//   Assert: original row 1 is now row 0
//   Assert: new content is on last row

// Test: unrecognized events are ignored
//   Apply: [.printable("A"), .unrecognized(0x01), .printable("B")]
//   Assert: cell (0,0) = "A", cell (0,1) = "B", cursor at col=2

// Test: bell is no-op
//   Apply: [.printable("A"), .bell, .printable("B")]
//   Assert: same as if bell weren't there

// Test: snapshot returns current state
//   Apply some events, take snapshot
//   Assert snapshot.cells, snapshot.cursor match expected
//   Apply more events, take another snapshot
//   Assert first snapshot is unchanged (it's a value type)
```

- [ ] **Step 2: Add test file to TermCoreTests target in pbxproj**

- [ ] **Step 3: Run tests to see them fail**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test`
Expected: FAIL — `ScreenModel` not defined

- [ ] **Step 4: Implement `ScreenModel`**

Create `TermCore/ScreenModel.swift`:

```pseudo
// Public actor ScreenModel
//
// Private state:
//   grid: ContiguousArray<Cell> of size rows * cols, initialized to Cell.empty
//   cursor: Cursor (starts at 0, 0)
//   cols: Int
//   rows: Int
//   latestSnapshot: ScreenSnapshot  — updated after every apply()
//
// Public init(cols: Int = 80, rows: Int = 24)
//
// Public func apply(_ events: [TerminalEvent]):
//   For each event:
//     case .printable(char):
//       grid[cursor.row * cols + cursor.col] = Cell(character: char)
//       cursor.col += 1
//       if cursor.col >= cols:
//         cursor.col = 0
//         cursor.row += 1
//         if cursor.row >= rows: scrollUp()
//
//     case .newline:
//       cursor.row += 1
//       if cursor.row >= rows: scrollUp()
//
//     case .carriageReturn:
//       cursor.col = 0
//
//     case .backspace:
//       cursor.col = max(0, cursor.col - 1)
//
//     case .tab:
//       cursor.col = min(cols - 1, (cursor.col / 8 + 1) * 8)
//       // If tab lands past last col, clamp to last col (don't wrap)
//
//     case .bell:
//       break  // no-op
//
//     case .unrecognized:
//       break  // ignored
//
//   Update latestSnapshot with current grid + cursor
//
// Private func scrollUp():
//   Shift rows 1..rows-1 → 0..rows-2 (memmove / replaceSubrange on the flat array)
//   Fill last row with Cell.empty
//   cursor.row = rows - 1
//
// Snapshot access for renderer (must be callable without await from render thread):
//   Option A: nonisolated property backed by an atomic/lock-free box
//   Option B: publish to a Sendable wrapper that the coordinator holds
//   The implementer should choose the most idiomatic Swift approach for
//   cross-isolation snapshot sharing. The key constraint: the MTKView draw
//   loop calls this synchronously on a render thread.
//
// Public func snapshot() -> ScreenSnapshot  (actor-isolated version for tests)
```

- [ ] **Step 5: Add `ScreenModel.swift` to TermCore target in pbxproj**

- [ ] **Step 6: Run tests to see them pass**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test`
Expected: All screen model tests PASS

- [ ] **Step 7: Commit**

```
git add TermCore/ScreenModel.swift TermCoreTests/ScreenModelTests.swift rTerm.xcodeproj/project.pbxproj
git commit -m "feat(TermCore): add ScreenModel actor with tests"
```

---

## Task 5: XPC Input Plumbing

**Files:**
- Modify: `TermCore/XPCRequest.swift` (line 62-65, `RemoteCommand` enum)
- Modify: `rTermSupport/PTYResponder.swift` (line 99-113, `respond` method)

Wire up the input direction: app sends keystrokes → XPC → PTY.

- [ ] **Step 1: Add `input(Data)` case to `RemoteCommand`**

In `TermCore/XPCRequest.swift`, the `RemoteCommand` enum currently has `spawn` and `failure`. Add:

```pseudo
// Add case: input(Data)
// This carries raw bytes from the keyboard to be written to the PTY.
// The enum is already Codable; Data is Codable, so this just works.
```

- [ ] **Step 2: Handle `.input` in `PTYResponder`**

In `rTermSupport/PTYResponder.swift`, the `respond(_:session:)` method (line 101) switches on `RemoteCommand`. Add a case:

```pseudo
// case .input(let data):
//   Write `data` to the PTY primary file descriptor.
//   The PTYResponder needs to hold a reference to the primary FD after spawn().
//   Currently, spawn() creates a PseudoTerminal but doesn't store the primary FD.
//
//   Changes needed in PTYResponder:
//     - Add a stored property: primaryFD: FileDescriptor? (set during spawn)
//     - In spawn(), after creating the PseudoTerminal, store pty.primary
//     - In the new .input handler:
//       guard let fd = primaryFD else { return .failure("no PTY") }
//       Write data to fd using Darwin.write() or fd.writeAll()
//       Return nil (no reply needed for fire-and-forget input)
//
//   Note: The current code closes the secondary FD after dup2 (line 53).
//   The PRIMARY FD must NOT be closed — it's our write channel.
```

- [ ] **Step 3: Build TermCore and rTermSupport to verify**

Run: `xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build`
Expected: BUILD SUCCEEDED (full app build exercises both targets)

- [ ] **Step 4: Commit**

```
git add TermCore/XPCRequest.swift rTermSupport/PTYResponder.swift
git commit -m "feat: add RemoteCommand.input for keyboard → PTY forwarding"
```

---

## Task 6: KeyEncoder

**Files:**
- Create: `rTerm/KeyEncoder.swift`

Translates `NSEvent` key events into the bytes the shell expects.

- [ ] **Step 1: Create `KeyEncoder`**

```pseudo
// Public struct KeyEncoder
//
// func encode(_ event: NSEvent) -> Data?
//
// Logic:
//   1. Check for Ctrl modifier + letter key:
//      If event has .control modifier and characters is a single letter a-z:
//        Return byte = (letter ASCII value - 0x60)
//        e.g. Ctrl+C → 0x03, Ctrl+D → 0x04, Ctrl+Z → 0x1A
//
//   2. Check keyCode for special keys:
//      Return key (keyCode 36) → Data([0x0D])
//      Delete/Backspace (keyCode 51) → Data([0x7F])
//      Tab (keyCode 48) → Data([0x09])
//
//   3. For printable characters:
//      Use event.characters (not charactersIgnoringModifiers)
//      If non-empty, return its UTF-8 encoded Data
//
//   4. Anything else: return nil (unhandled)
//
// Notes for implementer:
//   - NSEvent.keyCode values are hardware codes. The values above are standard
//     macOS key codes (36=Return, 51=Delete, 48=Tab).
//   - event.characters already accounts for keyboard layout and modifiers
//     (except Ctrl, which we handle explicitly).
//   - Do NOT call super.keyDown or interpretKeyEvents — we handle everything.
```

- [ ] **Step 2: Add to rTerm target in pbxproj**

- [ ] **Step 3: Build rTerm to verify**

Run: `xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```
git add rTerm/KeyEncoder.swift rTerm.xcodeproj/project.pbxproj
git commit -m "feat(rTerm): add KeyEncoder for NSEvent → PTY byte translation"
```

---

## Task 7: KeyEncoder Tests

**Files:**
- Create: `rTermTests/KeyEncoderTests.swift`

The spec requires unit tests for KeyEncoder. These go in `rTermTests` (which hosts against the rTerm app, so it can access rTerm types).

- [ ] **Step 1: Write KeyEncoder tests**

Create `rTermTests/KeyEncoderTests.swift`:

```pseudo
// Use Swift Testing (@Test, #expect).
// NSEvent construction for testing: use NSEvent.keyEvent(with:...) factory method.

// Test: printable character "a"
//   Create NSEvent for key "a" (keyCode 0, characters "a", no modifiers)
//   Encode → expect Data containing UTF-8 of "a" (0x61)

// Test: Return key
//   Create NSEvent for Return (keyCode 36)
//   Encode → expect Data([0x0D])

// Test: Backspace/Delete key
//   Create NSEvent for Delete (keyCode 51)
//   Encode → expect Data([0x7F])

// Test: Tab key
//   Create NSEvent for Tab (keyCode 48)
//   Encode → expect Data([0x09])

// Test: Ctrl+C
//   Create NSEvent for "c" with .control modifier
//   Encode → expect Data([0x03])

// Test: Ctrl+D
//   Create NSEvent for "d" with .control modifier
//   Encode → expect Data([0x04])

// Test: Ctrl+Z
//   Create NSEvent for "z" with .control modifier
//   Encode → expect Data([0x1A])

// Test: unhandled key returns nil
//   Create NSEvent for F1 or arrow key
//   Encode → expect nil
```

- [ ] **Step 2: Add test file to rTermTests target in pbxproj**

- [ ] **Step 3: Run tests**

Run: `xcodebuild -project rTerm.xcodeproj -scheme rTermTests test`
Expected: All KeyEncoder tests PASS (KeyEncoder was built in Task 6)

- [ ] **Step 4: Commit**

```
git add rTermTests/KeyEncoderTests.swift rTerm.xcodeproj/project.pbxproj
git commit -m "test(rTerm): add KeyEncoder unit tests"
```

---

## Task 8: Glyph Atlas

**Files:**
- Create: `rTerm/GlyphAtlas.swift`

Rasterizes ASCII glyphs into a Metal texture atlas using Core Text.

- [ ] **Step 1: Create `GlyphAtlas`**

```pseudo
// struct GlyphAtlas
//
// Properties:
//   texture: MTLTexture        — the atlas texture
//   cellWidth: CGFloat          — width of one character cell in points
//   cellHeight: CGFloat         — height of one character cell in points
//   glyphRegions: [Character: (x: Int, y: Int)]  — atlas tile coordinates per character
//
// init(device: MTLDevice, fontSize: CGFloat = 14.0):
//
//   1. Create a CTFont — system monospaced font at the given size.
//      Use CTFontCreateUIFontForLanguage(.userFixedPitch, fontSize, nil)
//      or NSFont.monospacedSystemFont.
//
//   2. Measure cell dimensions from font metrics:
//      cellWidth = advancement width of a reference glyph (e.g. "M")
//      cellHeight = ascent + descent + leading
//      Round up to whole pixels.
//
//   3. Determine atlas layout:
//      We need tiles for ASCII 0x20 (space) through 0x7E (~) = 95 glyphs.
//      Arrange in a grid: e.g. 16 columns × 6 rows = 96 tiles (enough).
//      Atlas pixel size = (16 * cellWidth, 6 * cellHeight), rounded up to power of 2 if needed.
//
//   4. Create a CGContext (bitmap context, 8-bit grayscale or RGBA):
//      Fill with black (background).
//      Set text color to white.
//      For each ASCII char 0x20...0x7E:
//        Calculate tile position (col, row) in the grid
//        Draw the glyph at (col * cellWidth, row * cellHeight) using CTLineDraw
//        or CTFontDrawGlyphs. Account for font baseline (ascent offset).
//        Store the tile coordinates in glyphRegions.
//
//   5. Create MTLTexture from the bitmap data:
//      Texture descriptor: .r8Unorm (grayscale) or .rgba8Unorm
//      Copy CGContext pixel data into the texture via texture.replace(region:...)
//
// func uvRect(for character: Character) -> (u0: Float, v0: Float, u1: Float, v1: Float):
//   Look up character in glyphRegions (fall back to "?" if missing)
//   Convert tile pixel coordinates to normalized UV coordinates (0.0...1.0)
//   Return the UV rect for this glyph's tile
//
// Notes for implementer:
//   - Consider Retina: use a scale factor of 2x when creating the CGContext
//     so glyphs are crisp on HiDPI displays. The cellWidth/cellHeight in points
//     stay the same; the texture is 2x the pixel dimensions.
//   - For grayscale (r8Unorm), the fragment shader reads the red channel as alpha.
//     This is more texture-efficient than RGBA for monochrome glyphs.
```

- [ ] **Step 2: Add to rTerm target in pbxproj**

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```
git add rTerm/GlyphAtlas.swift rTerm.xcodeproj/project.pbxproj
git commit -m "feat(rTerm): add GlyphAtlas — Core Text rasterization to MTLTexture"
```

---

## Task 9: Metal Shaders

**Files:**
- Create: `rTerm/Shaders.metal`

Vertex and fragment shaders for rendering textured quads from the glyph atlas.

- [ ] **Step 1: Create `Shaders.metal`**

```pseudo
// Shared types (in a header or at top of .metal file):
//
// struct VertexIn {
//   float2 position;   // clip-space x,y
//   float2 texCoord;   // UV into glyph atlas
// };
//
// struct VertexOut {
//   float4 position [[position]];
//   float2 texCoord;
// };
//
// vertex_main:
//   Takes VertexIn from vertex buffer
//   Passes position through as float4(position, 0.0, 1.0)
//   Passes texCoord through
//
// fragment_main:
//   Samples glyph atlas texture at texCoord
//   If using r8Unorm (grayscale): alpha = texture sample .r
//   Output: float4(1.0, 1.0, 1.0, alpha)  — white text, alpha from glyph
//   (Black background is handled by the clear color)
//
// cursor_fragment (optional, could be a separate pipeline or just a solid quad):
//   Output: float4(1.0, 1.0, 1.0, 0.7)  — semi-transparent white block
//
// Notes for implementer:
//   - The vertex buffer is rebuilt every frame (1920 quads = ~46KB, trivial).
//   - Consider using instanced rendering as an optimization later, but for
//     80×24 it's not necessary. Simple vertex buffer is fine.
//   - Make sure the function names match what RenderCoordinator references
//     when building the pipeline state.
```

- [ ] **Step 2: Add to rTerm target in pbxproj**

Ensure the .metal file is in the rTerm target's Compile Sources phase. Xcode compiles .metal files automatically.

- [ ] **Step 3: Build to verify shaders compile**

Run: `xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build`
Expected: BUILD SUCCEEDED (Metal compiler runs as part of build)

- [ ] **Step 4: Commit**

```
git add rTerm/Shaders.metal rTerm.xcodeproj/project.pbxproj
git commit -m "feat(rTerm): add Metal vertex and fragment shaders for glyph rendering"
```

---

## Task 10: RenderCoordinator + TermView Rewrite

**Files:**
- Modify: `rTerm/TermView.swift` (full rewrite of existing file)

This is the most complex task. The existing scaffold is replaced with a working renderer.

- [ ] **Step 1: Rewrite `TermView.swift`**

```pseudo
// --- TerminalMTKView (NSView subclass wrapping MTKView or subclassing it) ---
//
// Purpose: An MTKView subclass that accepts first responder for keyboard input.
//
// override var acceptsFirstResponder: Bool { true }
// override func keyDown(with event: NSEvent):
//   Use KeyEncoder to encode the event
//   If bytes returned, call an onInput callback (closure or delegate)
//   Do NOT call super.keyDown — we swallow all key events
//
// override func flagsChanged(with event: NSEvent):
//   Needed if we want to detect modifier-only presses. For now, no-op.
//
//
// --- RenderCoordinator: NSObject, MTKViewDelegate ---
//
// Properties:
//   device: MTLDevice
//   commandQueue: MTLCommandQueue
//   pipelineState: MTLRenderPipelineState
//   glyphAtlas: GlyphAtlas
//   screenModel: ScreenModel
//   keyEncoder: KeyEncoder
//   onInput: ((Data) -> Void)?     — callback for keyboard bytes
//
// init(screenModel: ScreenModel):
//   device = MTLCreateSystemDefaultDevice()
//   commandQueue = device.makeCommandQueue()
//   glyphAtlas = GlyphAtlas(device: device)
//   Build pipeline state:
//     Load default library from device
//     Get vertex_main and fragment_main functions
//     Create MTLRenderPipelineDescriptor with those functions
//     Set color attachment pixel format (from the MTKView)
//     Enable alpha blending on the color attachment:
//       sourceRGBBlendFactor = .sourceAlpha
//       destinationRGBBlendFactor = .oneMinusSourceAlpha
//     Create pipeline state from descriptor
//
// func draw(in view: MTKView):
//   Guard: drawable, renderPassDescriptor, commandBuffer, renderEncoder
//
//   Set clear color to black (0, 0, 0, 1)
//
//   Read snapshot from screenModel (see Task 4 note on cross-isolation access)
//
//   Build vertex data:
//     For each row 0..<snapshot.rows, col 0..<snapshot.cols:
//       Look up the character's UV rect from glyphAtlas
//       Calculate the quad's screen position:
//         x0 = col * cellWidth (in points, mapped to clip space)
//         y0 = row * cellHeight (flip Y — Metal clip space is bottom-left origin)
//       Emit 6 vertices (2 triangles) with position + texCoord
//
//   Upload vertex data to a MTLBuffer (or use setVertexBytes for small data)
//
//   Set pipeline state, vertex buffer, fragment texture (glyph atlas)
//   Draw primitives: .triangle, vertexCount = 6 * rows * cols
//
//   Draw cursor:
//     One more quad at the cursor position, using cursor_fragment or
//     just a solid white quad with alpha. Could use same pipeline with
//     a special "solid" UV region, or a second pipeline. Simplest: add
//     one more quad with UV pointing to a filled region of the atlas.
//
//   End encoding, present drawable, commit command buffer
//
// func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize):
//   For now, no-op. Dynamic resize is a future spec.
//
//
// --- TermView: NSViewRepresentable ---
//
// Properties:
//   screenModel: ScreenModel
//   onInput: ((Data) -> Void)?
//
// makeCoordinator() → RenderCoordinator:
//   Return RenderCoordinator(screenModel: screenModel)
//
// makeNSView(context:) → TerminalMTKView:
//   Create TerminalMTKView with coordinator's device
//   Set delegate to coordinator
//   Set preferredFramesPerSecond (e.g. 60)
//   Set colorPixelFormat to .bgra8Unorm
//   Set clearColor to black
//   Wire up keyboard: view.onInput = coordinator.onInput
//   Set frame size to (cols * cellWidth, rows * cellHeight)
//   Return the view
//
// updateNSView: no-op for now
//
//
// Notes for implementer:
//   - Remove the existing TermViewController class from this file — it's unused.
//   - Remove the existing RenderCoordinator and TermView — this is a full rewrite.
//   - The clip-space mapping: Metal clip space is [-1, 1] × [-1, 1].
//     Map grid positions: x_clip = (col * cellWidth / viewWidth) * 2 - 1
//                          y_clip = 1 - (row * cellHeight / viewHeight) * 2
//     Or use an orthographic projection matrix passed as a uniform.
//     The implementer should choose whichever is cleaner.
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build`
Expected: BUILD SUCCEEDED (won't be usable yet — ContentView still references old `Term` class)

- [ ] **Step 3: Commit**

```
git add rTerm/TermView.swift
git commit -m "feat(rTerm): rewrite TermView with Metal glyph rendering and key input"
```

---

## Task 11: TerminalSession + ContentView Integration

**Files:**
- Modify: `rTerm/ContentView.swift` (full rewrite)

Replace the old `Term` class and `ContentView` with the new pipeline.

- [ ] **Step 1: Rewrite `ContentView.swift`**

```pseudo
// --- TerminalSession (replaces Term class) ---
//
// @Observable @MainActor class TerminalSession
//
// Properties:
//   screenModel: ScreenModel
//   remotePTY: RemotePTY
//   parser: TerminalParser      (value type, mutated during processing)
//   log: Logger
//
// init(rows: Int = 24, cols: Int = 80):
//   screenModel = ScreenModel(cols: cols, rows: rows)
//   remotePTY = RemotePTY()
//   parser = TerminalParser()
//
// nonisolated func connect() async:
//   try remotePTY.connect()
//   let spawnReply = try remotePTY.sendSync(.spawn)
//   if case .spawned = spawnReply:
//     for await data in remotePTY.outputData:
//       let events = parser.parse(Data(data))
//       await screenModel.apply(events)
//
// func sendInput(_ data: Data):
//   try remotePTY.send(command: RemoteCommand.input(data))
//
//
// --- ContentView ---
//
// @State var session = TerminalSession()
//
// var body: some View
//   TermView(screenModel: session.screenModel, onInput: { data in
//     session.sendInput(data)
//   })
//   .frame(width: desiredWidth, height: desiredHeight)
//     // width = 80 * cellWidth, height = 24 * cellHeight
//     // The cell dimensions come from GlyphAtlas metrics.
//     // For now, hardcode a reasonable size or compute from font metrics.
//   .task {
//     do {
//       try await session.connect()
//     } catch {
//       // Log the error. No UI error display for this spec.
//     }
//   }
//
// Remove:
//   - The old Term class (entirely)
//   - ScreenBufferView struct
//   - All TextField / TextEditor UI
//   - All AsyncChannel<Data> input handling
//   - The CIFilter import (no longer needed)
//
// Keep:
//   - The #Preview if desired (it won't connect to a real shell but can show the empty grid)
```

- [ ] **Step 2: Build the full app**

Run: `xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```
git add rTerm/ContentView.swift
git commit -m "feat(rTerm): integrate TerminalSession pipeline, replace old Term/TextEditor UI"
```

---

## Task 12: Manual Integration Test

No code changes. Verify the full pipeline works end-to-end.

- [ ] **Step 1: Run all unit tests**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test`
Expected: All tests PASS (parser + screen model)

- [ ] **Step 2: Launch the app**

Run: `open rTerm.xcodeproj` and Run the rTerm scheme (or `xcodebuild ... && open build/...`)

Verify:
- The Metal view appears with a black background
- Shell output appears as white monospaced text (you should see a shell prompt)
- Typing characters appears on screen
- Enter key sends commands to the shell
- `ls` shows directory contents
- Ctrl+C interrupts a running command
- Backspace deletes characters

- [ ] **Step 3: Final commit with any fixes**

If manual testing reveals issues, fix them and commit. Otherwise:

```
git commit --allow-empty -m "test: verify dumb terminal foundation works end-to-end"
```

---

## Summary

| Task | Component | Type |
|---|---|---|
| 1 | TerminalEvent enum | New type |
| 2 | TerminalParser + tests | TDD |
| 3 | Cell, Cursor, ScreenSnapshot | New types |
| 4 | ScreenModel + tests | TDD |
| 5 | XPC input plumbing | Modify existing |
| 6 | KeyEncoder | New type |
| 7 | KeyEncoder tests | TDD |
| 8 | GlyphAtlas | New type |
| 9 | Metal shaders | New file |
| 10 | RenderCoordinator + TermView | Rewrite |
| 11 | TerminalSession + ContentView | Rewrite |
| 12 | Manual integration test | Verification |
