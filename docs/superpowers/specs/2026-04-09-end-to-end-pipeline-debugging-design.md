# End-to-End Pipeline Debugging Design

**Date:** 2026-04-09
**Status:** Draft
**Depends on:** Dumb Terminal Foundation (2026-04-06), PTY I/O Path (2026-04-09)

## Context

The dumb terminal foundation and PTY I/O path have been implemented per their specs. The XPC connection succeeds and shell spawning works (`spawned(file:///dev/ttys006)`), but no shell prompt appears on screen and keyboard input does not reach the shell. The pipeline is broken somewhere between the running shell and the Metal renderer.

**Goal:** Identify and fix every break in the data path so that the terminal displays the shell prompt, accepts keyboard input, and renders shell output.

## Architecture Recap

```
Output path:
Shell → PTY primary FD → readabilityHandler → AsyncStream<Data>
  → PTYResponder.outputTask → session.send(RemoteResponse.stdout)
  → RemotePTY.processIncomingMessages → outputDataChannel
  → TerminalSession.connect() loop → TerminalParser.parse()
  → ScreenModel.apply() → latestSnapshot()
  → RenderCoordinator.draw() → Metal → screen

Input path:
keyDown → KeyEncoder.encode() → onKeyInput closure
  → TerminalSession.sendInput() → RemotePTY.send(.input)
  → PTYResponder.respond(.input) → PseudoTerminal.write()
  → PTY primary FD → Shell
```

## Known Suspects

### S1: Shell process not producing output (HIGH)

`PseudoTerminal.start()` spawns a shell via Foundation's `Process` (which uses `posix_spawn` internally). The `readabilityHandler` on `primaryHandle` yields data into `outputStream`. Code review confirmed `primaryHandle` is properly retained as a property, so the handler stays alive.

Possible failures:
- Foundation's `posix_spawn` may not inherit the secondary FD correctly when `standardInput`/`standardOutput`/`standardError` are set to the same FileHandle
- The `TIOCSCTTY` ioctl is called on the secondary FD **before** fork in the parent process — non-standard pattern that may not properly set the shell's controlling terminal
- The shell (zsh by default) may not enter interactive mode if it doesn't detect a valid TTY on stdin
- After `pty.secondary.close()`, the parent's copy is closed but `posix_spawn` may have already set up its own FD actions, making the close timing sensitive

**Files:** `TermCore/PseudoTerminal.swift`, `TermCore/Shell.swift`

### S2: XPC output delivery fails silently (MEDIUM)

`PTYResponder.outputTask` calls `session.send(RemoteResponse.stdout(data))` in a loop. Both `try Task.checkCancellation()` and `try session.send(...)` are unguarded — if a single send fails, the entire Task exits and **all further output is lost**. The task does not log the error before exiting.

**Files:** `rTermSupport/PTYResponder.swift`

### S3: Client-side incoming message handler not receiving (MEDIUM)

`RemotePTY.processIncomingMessages()` creates an `AsyncStream` via `xpcSession.incomingMessages` which calls `setIncomingMessageHandler`. If the handler is replaced or the stream is not consumed promptly, messages could be dropped.

**Files:** `TermCore/RemotePTY.swift`

### S4: Metal renderer displays empty grid (LOW)

If data reaches `ScreenModel` but the renderer isn't picking it up, possible causes:
- `latestSnapshot()` returns stale data (lock contention or missed update)
- `GlyphAtlas` doesn't map space characters or the prompt characters correctly
- Vertex coordinates are wrong (off-screen or zero-sized)

**Files:** `rTerm/TermView.swift`, `rTerm/GlyphAtlas.swift`

### S5: First responder not set for keyboard input (HIGH)

`TerminalMTKView.acceptsFirstResponder` returns `true` but in SwiftUI's `NSViewRepresentable`, the view may not automatically become first responder. Without first responder status, `keyDown(with:)` is never called.

**Files:** `rTerm/TermView.swift`

## Debugging Strategy

### Phase 1: Instrument the Output Path

Add `os_log` / `Logger` statements at each handoff to trace data flow. Each log should include the byte count to confirm data is non-empty.

| Location | Log message | File |
|----------|-------------|------|
| `PseudoTerminal.start()` readabilityHandler | `"PTY output: \(data.count) bytes"` | `PseudoTerminal.swift` |
| `PTYResponder.outputTask` before send | `"XPC sending stdout: \(data.count) bytes"` | `PTYResponder.swift` |
| `RemotePTY.processIncomingMessages` | `"Received XPC message: \(message.count) bytes"` | `RemotePTY.swift` |
| `TerminalSession.connect()` for-await loop | `"Parser input: \(output.count) bytes"` | `ContentView.swift` |
| `ScreenModel.apply()` | `"Applying \(events.count) events"` | `ScreenModel.swift` |

**Run the app and read Console.app logs.** The first location with no log output is the break point.

### Phase 2: Instrument the Input Path

| Location | Log message | File |
|----------|-------------|------|
| `TerminalMTKView.keyDown` | `"keyDown: keyCode=\(event.keyCode)"` | `TermView.swift` |
| `KeyEncoder.encode()` return | `"encoded \(data.count) bytes"` | `KeyEncoder.swift` (or caller) |
| `TerminalSession.sendInput()` | `"sendInput: \(data.count) bytes"` | `ContentView.swift` |
| `PTYResponder.respond(.input)` | `"PTY write: \(data.count) bytes"` | `PTYResponder.swift` |

### Phase 3: Fix Each Break Point

Based on code review, the predicted fixes are:

**Fix 1: Verify shell output at the PTY level**
Add a log in the `readabilityHandler` to confirm data is arriving from the shell. If no data arrives, the issue is in shell/PTY setup (TIOCSCTTY, fd inheritance). If data arrives but doesn't reach the app, the issue is in XPC delivery.

**Fix 2: Make PTYResponder.outputTask resilient to send errors**
Wrap individual `session.send()` calls in do/catch so a single send failure doesn't kill the entire output stream. Log the error and continue.

**Fix 3: Ensure first responder in TermView**
Call `view.window?.makeFirstResponder(view)` in `makeNSView` or use `DispatchQueue.main.async` to set it after the view is added to the window hierarchy.

**Fix 4: Verify GlyphAtlas character mapping**
Confirm that common prompt characters (`%`, `$`, `~`, `/`) are in the ASCII range (0x20-0x7E) that GlyphAtlas rasterizes. They should be, but verify the UV lookup returns valid coordinates.

## Testing

### Automated
- Existing `PseudoTerminalTests` already cover write/read/resize
- Add a test that spawns a shell, sends `echo hello\n`, and asserts `hello` appears in the output stream (no XPC, no rendering — just PTY round-trip)

### Manual
1. Run the app, observe Console.app for the diagnostic logs
2. Confirm shell prompt appears on screen
3. Type `ls` + Enter, confirm output renders
4. Type Ctrl+C, confirm signal reaches shell
5. Type `exit`, confirm session ends gracefully

## Scope

**In scope:**
- Diagnostic logging at each pipeline stage
- Fixing identified break points in the output and input paths
- Basic first-responder handling for keyboard input

**Out of scope:**
- ANSI escape sequences, colors, attributes
- Window resize propagation
- Scrollback buffer
- Arrow keys and function keys
- XPC reconnection/error recovery

## Notes

- Diagnostic logging added during debugging should be kept at `debug` level or removed once the pipeline is confirmed working. Permanent logging at `info`/`error` level is fine for error paths.
- The existing `SessionHandler` already logs incoming requests at `info` level — these logs should appear in Console.app and help trace XPC message flow.
