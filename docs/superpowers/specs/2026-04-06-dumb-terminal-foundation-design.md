# Dumb Terminal Foundation

**Date:** 2026-04-06
**Status:** Draft
**Scope:** Byte-stream parser, screen model, Metal renderer, keyboard input — the minimum pipeline for a working (non-ANSI) terminal session.

---

## Overview

rTerm currently has XPC plumbing that can spawn a shell and shuttle stdout back to the app, but nothing that interprets the output or renders it properly. This spec covers the foundational pipeline: parsing raw PTY output into structured events, maintaining a screen grid model, rendering that grid with Metal, and forwarding keyboard input back to the shell.

The target is a "dumb terminal" — plain text, newlines, carriage returns, backspace, tab, and bell. No ANSI escape sequences, no colors, no alternate screen buffer. Those are future specs that build on this foundation.

## 1. Byte Stream Parser

### Responsibility

Consume raw bytes from the XPC output stream and produce typed terminal events.

### Input

`AsyncSequence<Data, Never>` from `RemotePTY.outputData`.

### Output

`[TerminalEvent]` — a batch of events per data chunk.

### Event Type

```swift
public enum TerminalEvent {
    case printable(Character)       // displayable character (UTF-8 decoded)
    case newline                    // LF (0x0A)
    case carriageReturn             // CR (0x0D)
    case backspace                  // BS (0x08) — cursor left one
    case tab                        // HT (0x09)
    case bell                       // BEL (0x07)
    case unrecognized(UInt8)        // anything not handled yet
}
```

### Design

- `TerminalParser` is a **struct** (pure transform, no shared state).
- UTF-8 decoding happens here. Multi-byte sequences are accumulated in internal state until a complete code point is formed.
- Method signature: `mutating func parse(_ data: Data) -> [TerminalEvent]` — mutating because of the UTF-8 continuation byte accumulator.
- Designed to be extended later with CSI (Control Sequence Introducer) parsing for ANSI/VT100, but the initial implementation only handles the 7 event types above.

### Location

`TermCore/TerminalParser.swift`

## 2. Screen Model

### Responsibility

Canonical representation of the terminal display. The parser writes to it; the renderer reads from it.

### Cell

```swift
public struct Cell {
    public var character: Character  // " " for empty
}
```

Minimal for dumb terminal scope. Future specs add attributes (color, bold, underline) to `Cell`.

### Grid Storage

- Fixed-size grid of `rows * cols` cells.
- Backed by `ContiguousArray<Cell>`, row-major layout.
- Index math: `grid[row * cols + col]`.
- Default dimensions: 80 columns, 24 rows.

### Cursor

```swift
public struct Cursor {
    public var row: Int
    public var col: Int
}
```

### Operations

| Method | Behavior |
|---|---|
| `print(Character)` | Write at cursor, advance right. Wrap to next row if past last column. Scroll up if past last row. |
| `newline()` | Move cursor to next row. Scroll up if at bottom. |
| `carriageReturn()` | Move cursor to column 0. |
| `backspace()` | Move cursor left one column, clamped at 0. |
| `tab()` | Advance cursor to next tab stop (every 8 columns). |
| `bell()` | No-op for now. |
| `apply(_ events: [TerminalEvent])` | Batch-apply events from the parser. |

**Scrolling:** When the cursor moves past the last row, shift all rows up by one (discard row 0), insert a blank row at the bottom.

**Scrollback:** Not in this spec. The grid is the visible viewport only.

### Snapshot

The renderer reads the screen state via a value-type snapshot:

```swift
public struct ScreenSnapshot: Sendable {
    public let cells: ContiguousArray<Cell>
    public let cols: Int
    public let rows: Int
    public let cursor: Cursor
}
```

The `ScreenModel` actor exposes `func snapshot() -> ScreenSnapshot`. However, since the Metal draw loop runs on a render thread and cannot `await`, the actor publishes the latest snapshot to a `@unchecked Sendable` atomic property (or uses `nonisolated` access on an immutable value-type copy). The `RenderCoordinator` reads this snapshot synchronously each frame. This avoids overproducing snapshots when output arrives faster than the screen refreshes.

### Location

`TermCore/ScreenModel.swift`, `TermCore/Cell.swift`

### Replaces

- The existing `ScreenBuffer<Element>` actor
- The `Term` class's ad-hoc `text: String` accumulation in `ContentView.swift`
- `CircularCollection` is not used here (flat array with scroll-up is simpler for a fixed viewport without scrollback)

## 3. Metal Renderer

### Responsibility

Render the `ScreenSnapshot` as a grid of monospaced glyphs using the existing `MTKView` scaffold.

### Glyph Atlas

- On startup, rasterize visible ASCII (0x20–0x7E, 95 glyphs) into a single `MTLTexture` atlas using Core Text.
- Use the system monospaced font (e.g. Menlo or SF Mono) at a fixed size (14pt). Configurable font is a future spec.
- Each glyph occupies a uniform `cellWidth * cellHeight` tile. Cell dimensions are derived from font metrics (advancement for width, ascent + descent + leading for height).
- Maintain a lookup table: `[Character: (atlasX: Int, atlasY: Int)]` mapping characters to atlas positions.

### Draw Loop

Each frame (driven by MTKView display link):

1. Grab `ScreenSnapshot` from `ScreenModel`.
2. Build a vertex buffer: for each cell, emit a quad (two triangles) textured with the glyph's atlas region.
3. For 80x24 = 1,920 quads, this is trivially small for Metal.
4. Render the cursor as a filled rectangle (block cursor) at the cursor position, blended on top.

### Shaders

- **Vertex shader (`vertex_main`):** Takes per-quad position + UV coordinates, outputs clip-space position and texture coordinates.
- **Fragment shader (`fragment_main`):** Samples the glyph atlas texture, outputs white-on-black. Foreground/background colors are a future spec.

### Shader Location

`rTerm/Shaders.metal` (new file)

### View Integration

- `TermView` (`NSViewRepresentable`) stays as the SwiftUI bridge.
- `RenderCoordinator` is fleshed out: holds the atlas texture, pipeline state, vertex buffer, and a reference to the `ScreenModel`.
- `TermViewController` is kept but not used — `TermView` + `RenderCoordinator` is the primary path.

### Sizing

The MTKView drawable size divided by cell dimensions determines theoretical rows/cols. For this spec, fix at 80x24 and size the view accordingly. Dynamic resize is a future spec.

### Replaces

- The `TextEditor(text: $term.text)` in `ContentView.swift`
- The empty `draw(in:)` in `RenderCoordinator`

## 4. Keyboard Input

### Responsibility

Route keystrokes from the user into the PTY via the existing XPC channel.

### Key Capture

The `MTKView` becomes the first responder for keyboard events. Override `keyDown(with:)` on the view (via a custom `NSView` subclass wrapping `MTKView`, or via the coordinator's `makeNSView` setup).

### Key Mapping (Dumb Terminal Scope)

| Key | Bytes Sent |
|---|---|
| Printable characters | UTF-8 encoding of the character |
| Enter / Return | `0x0D` (CR) |
| Backspace / Delete | `0x7F` (DEL) |
| Tab | `0x09` (HT) |
| Ctrl+C | `0x03` (ETX) |
| Ctrl+D | `0x04` (EOT) |
| Ctrl+Z | `0x1A` (SUB) |

Arrow keys, function keys, and other special keys are out of scope. They require escape sequences and will be addressed in a future ANSI/VT100 spec.

### Encoding

`KeyEncoder` struct with method: `func encode(_ event: NSEvent) -> Data?`

Returns `nil` for unhandled keys (e.g. arrow keys, function keys).

### Data Path

1. `keyDown(with:)` captures the `NSEvent`.
2. `KeyEncoder.encode(_:)` converts to bytes.
3. Bytes are sent via `RemotePTY.send(command: .input(data))`.
4. XPC service receives `RemoteCommand.input(Data)`.
5. `PTYResponder` writes the data to the PTY primary file descriptor.

### New XPC Plumbing

Add to `RemoteCommand`:

```swift
public enum RemoteCommand: Codable {
    case spawn
    case input(Data)        // NEW: keyboard input forwarded to shell
    case failure(String)
}
```

`PTYResponder` handles `.input(Data)` by writing to the PTY primary FD via `write()` or `DispatchIO`.

### Location

`rTerm/KeyEncoder.swift` (new), modifications to `TermCore/XPCRequest.swift` and `rTermSupport/PTYResponder.swift`.

### Replaces

The `TextField("Prompt", ...)` + `AsyncChannel<Data>` input hack in `ContentView.swift`.

## 5. Data Pipeline

### Output Path

```
Shell process (rTermSupport.xpc)
  → PTY primary FD
  → XPC message (RemoteResponse.stdout)
  → RemotePTY.outputData (AsyncSequence<Data>)
  → TerminalParser.parse(_:) → [TerminalEvent]
  → ScreenModel.apply(_: [TerminalEvent])
  → MTKView draw loop reads ScreenModel.snapshot()
  → Metal renders glyphs to screen
```

### Input Path

```
NSEvent (keyDown)
  → KeyEncoder.encode(_:) → Data
  → RemotePTY.send(command: .input(Data))
  → XPC message (RemoteCommand.input)
  → PTYResponder writes to PTY primary FD
  → Shell reads from PTY secondary
```

### Pipeline Host

The `Term` class in `ContentView.swift` is refactored into `TerminalSession`:

- `TerminalSession` is `@Observable` and `@MainActor`.
- Owns `RemotePTY`, `TerminalParser`, and `ScreenModel`.
- On `connect()`, spawns a `Task` that reads from `remotePTY.outputData`, runs each chunk through the parser, and applies events to the screen model.
- Exposes the `ScreenModel` to the view layer.
- `ContentView` creates a `TerminalSession` and passes its `ScreenModel` to `TermView`'s coordinator.

### Lifecycle

1. App launches, `ContentView` creates `TerminalSession`.
2. `.task` modifier calls `terminalSession.connect()`.
3. `connect()` opens XPC session, sends `.spawn`, starts output processing loop.
4. `TermView` draws frames on display link, reading snapshots from the screen model.
5. Keystrokes flow through `KeyEncoder` → `RemotePTY` → XPC → shell.

### Error Handling

Minimal for this spec:

- **XPC disconnection:** Log and stop the processing task. No automatic reconnection (future spec).
- **Unrecognized byte in parser:** Emit `TerminalEvent.unrecognized`, screen model ignores it.
- **Write to PTY fails:** Log the error.

## 6. Testing Strategy

| Component | Approach | Notes |
|---|---|---|
| `TerminalParser` | Unit tests in TermCoreTests | Feed known byte sequences, assert correct events. Pure struct, easy to test. |
| `ScreenModel` | Unit tests in TermCoreTests | Apply event sequences, assert grid state and cursor position. Actor, use async tests. |
| `KeyEncoder` | Unit tests in TermCoreTests | Construct NSEvent-like inputs, assert correct byte output. |
| Metal renderer | Manual visual verification | Launch app, confirm glyphs render. Not unit tested in this spec. |
| Integration | Manual | Launch app, type `ls`, confirm output appears and input works. |

All tests use Swift Testing framework (`@Test`, `#expect`), consistent with existing `TermCoreTests`.

## 7. Files Changed / Created

### New Files

| File | Target | Description |
|---|---|---|
| `TermCore/TerminalParser.swift` | TermCore | Byte stream parser |
| `TermCore/ScreenModel.swift` | TermCore | Screen grid actor |
| `TermCore/Cell.swift` | TermCore | Cell and related types |
| `rTerm/KeyEncoder.swift` | rTerm | NSEvent to bytes conversion |
| `rTerm/Shaders.metal` | rTerm | Vertex + fragment shaders |

### Modified Files

| File | Changes |
|---|---|
| `TermCore/XPCRequest.swift` | Add `RemoteCommand.input(Data)` |
| `rTermSupport/PTYResponder.swift` | Handle `.input` — write to PTY primary FD |
| `rTerm/TermView.swift` | Flesh out `RenderCoordinator` with atlas, pipeline, draw loop |
| `rTerm/ContentView.swift` | Replace `Term` with `TerminalSession`, replace `TextEditor` with `TermView`, remove TextField input hack |
| `rTerm.xcodeproj/project.pbxproj` | Add new files to targets |

### Unchanged / Untouched

| File | Reason |
|---|---|
| `TermCore/CircularCollection.swift` | Not used in this spec (flat array for viewport) |
| `TermCore/RingBuffer.swift` | Not used in this spec |
| `TermCore/ScreenBuffer.swift` | Replaced by `ScreenModel`; removal is optional (can defer cleanup) |
| `TermCore/TermMessage.swift` | Empty stub, not relevant to this spec |

## Out of Scope

Explicitly deferred to future specs:

- ANSI/VT100/xterm escape sequences (CSI parsing, SGR attributes, cursor addressing)
- Colors and text attributes (bold, underline, inverse)
- Alternate screen buffer
- Scrollback history
- Dynamic window resize (SIGWINCH propagation)
- Mouse tracking
- Clipboard / selection / copy-paste
- Multiple tabs or sessions
- Configurable font, font size, or color themes
- Arrow keys, function keys, Home/End/PageUp/PageDown
- XPC reconnection on failure
- iOS / xrOS support
