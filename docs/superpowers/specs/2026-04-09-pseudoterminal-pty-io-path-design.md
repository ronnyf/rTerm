# PseudoTerminal & PTY I/O Path Rework

**Date:** 2026-04-09
**Status:** Draft
**Scope:** Rework PseudoTerminal into a self-contained PTY+Shell manager, fix the surrounding PTY I/O path (Shell, PTYResponder, RemotePTY), remove dead code.

---

## Overview

PseudoTerminal currently holds an `AltPTY` and `Shell` reference but does almost nothing — the actual PTY setup, shell spawning, output reading, and input writing all live in PTYResponder. Additionally, the I/O path has several bugs: Shell.process() creates Pipe objects that conflict with PTY FD redirection, RemotePTY.incomingMessages is a stub, and PseudoTerminal.connect() is dead code.

This spec makes PseudoTerminal the self-contained PTY+Shell manager. PTYResponder becomes a thin XPC adapter. The full output path (shell → PTY → XPC → app) and input path (app → XPC → PTY → shell) are fixed end-to-end.

## 1. PseudoTerminal — Self-Contained Manager

### Responsibility

Own the PTY file descriptor pair, spawn and manage the shell process, expose output as an `AsyncStream<Data>`, accept input writes, and handle window size changes.

### Interface

```swift
public class PseudoTerminal {
    public let shell: Shell
    public let pty: AltPTY
    public private(set) var winsize: Darwin.winsize

    /// Output bytes from the shell, backed by FileHandle.readabilityHandler on the primary FD.
    public let outputStream: AsyncStream<Data>
    private let outputContinuation: AsyncStream<Data>.Continuation

    /// FileHandle for reading from the primary FD.
    private let primaryHandle: FileHandle

    /// The running shell process.
    private var shellProcess: Process?

    public init(shell: Shell = .zsh, rows: UInt16 = 24, cols: UInt16 = 80) throws
    public func start() throws -> String
    public func write(_ data: Data)
    public func resize(rows: UInt16, cols: UInt16)
}
```

### init

- Creates `AltPTY` (primary + secondary FD pair).
- Stores shell and winsize.
- Creates `AsyncStream<Data>` with its continuation (stream is inert until `start()` hooks up the readabilityHandler).
- Creates `primaryHandle` as `FileHandle(fileDescriptor: pty.primary.rawValue, closeOnDealloc: false)`.

### start() → String

1. Get the secondary FD's tty name via `ptsname()`. Throw if nil.
2. Set the secondary as the controlling terminal via `ioctl(TIOCSCTTY)`. This runs in the parent (XPC service) process — Foundation's `Process` doesn't provide a pre-exec hook, so the child inherits the controlling terminal via fork.
3. Create a shell `Process` via `shell.process()`.
4. Assign `FileHandle(fileDescriptor: pty.secondary.rawValue, closeOnDealloc: false)` to `shellProcess.standardInput`, `standardOutput`, and `standardError`.
5. Set `primaryHandle.readabilityHandler` to yield `availableData` into `outputContinuation`. When `availableData` is empty, call `continuation.finish()` and set `readabilityHandler = nil`.
6. Set `shellProcess.terminationHandler` to clean up (finish the continuation, nil out readabilityHandler).
7. Call `shellProcess.run()`.
8. Close the secondary FD — the shell process has inherited it, PseudoTerminal no longer needs it.
9. Return the tty name.

### write(_ data: Data)

Synchronous `Darwin.write(pty.primary.rawValue, buffer, count)` — PTY primary writes are small and fast. Log errors but do not throw (matches current behavior).

### resize(rows: UInt16, cols: UInt16)

1. Update `self.winsize` with new row/col values.
2. Call `ioctl(pty.primary.rawValue, TIOCSWINSZ, &winsize)` to propagate to the PTY.

### Lifecycle

- `deinit` cancels the readabilityHandler, finishes the continuation, and terminates the shell process if still running.
- No automatic reconnection — if the shell exits, `outputStream` finishes.

## 2. Shell.swift Cleanup

### Changes

- **Remove Pipe setup** from `process()`: delete the three lines that assign `Pipe()` to `standardInput`/`standardOutput`/`standardError`. PseudoTerminal.`start()` assigns PTY FileHandles instead.
- **Remove the `Process` extension** with `inputPipe`/`outputPipe`/`errorPipe` computed properties — no longer used. (Note: `outputPipe` had a bug — it returned `standardInput as? Pipe` instead of `standardOutput`.)
- **Keep** the `executable`, `defaultArguments`, and `process()` factory (it still creates the `Process` with executableURL, arguments, environment, currentDirectoryURL).

## 3. PTYResponder Simplification

### Before

PTYResponder does everything: creates AltPTY, dup2's FDs, sets controlling terminal, spawns the shell, reads from pipes via a task group, writes input via stored primaryFD.

### After

Thin XPC adapter that delegates to PseudoTerminal:

```swift
class PTYResponder {
    var pseudoTerminal: PseudoTerminal?
    var outputTask: Task<Void, Error>?

    func spawn(session: XPCSession) throws -> RemoteResponse {
        let pt = try PseudoTerminal()
        let ttyName = try pt.start()
        self.pseudoTerminal = pt

        outputTask = Task {
            for await data in pt.outputStream {
                try Task.checkCancellation()
                try session.send(RemoteResponse.stdout(data))
            }
        }
        return .spawned(URL(filePath: ttyName))
    }
}

extension PTYResponder: XPCSyncResponder {
    func respond(_ request: RemoteCommand, session: XPCSession) throws -> RemoteResponse? {
        switch request {
        case .spawn:
            return try spawn(session: session)
        case .input(let data):
            pseudoTerminal?.write(data)
            return nil
        case .failure(let message):
            return .failure(message)
        @unknown default:
            return nil
        }
    }
}
```

### Removed from PTYResponder

- `primaryFD` property
- `shellTask` and the task group
- All dup2/tiosctty/fd.close logic
- `FileHandle.dataStream()` extension

## 4. RemotePTY.incomingMessages Fix

The `XPCSession.incomingMessages` extension has an empty `AsyncStream` body — it never yields, so `RemotePTY.outputData` never produces values on the client side.

Restore the body to call `setIncomingMessageHandler`:

```swift
extension XPCSession {
    func incomingMessages<Message: Decodable, Result>(
        transform: @escaping (Message) -> Result?
    ) -> some AsyncSequence<Result, Never> {
        AsyncStream { continuation in
            setIncomingMessageHandler { (message: Message) in
                if let value = transform(message) {
                    continuation.yield(value)
                }
                return nil
            }
        }
    }
}
```

Verify during implementation that `setIncomingMessageHandler` exists on `XPCSession` (from XPCOverlay) with this signature.

## 5. Dead Code Removal

### PseudoTerminal.swift

| Item | Action |
|---|---|
| `connect()` | Remove — dead NSKeyedArchiver code |
| `outputChannel` / `outputData` (AsyncChannel) | Remove — replaced by `outputStream` |
| `primaryIOChannel()` / `secondaryIOChannel()` | Remove — unused DispatchIO factories |
| Commented-out `stream(fd:)` methods | Remove |
| `FileDescriptor.copy(accessMode:)` extension | Remove — unused |
| `FileDescriptor.tiosctty()` extension | Move inline into `start()` as a private detail |
| `FileHandle` extension (commented-out `values()`) | Remove |

### PTYResponder.swift

| Item | Action |
|---|---|
| `primaryFD` property | Remove — PseudoTerminal owns this |
| `shellTask` + task group in `spawn()` | Remove — replaced by simple `outputTask` |
| dup2/tiosctty/fd.close logic | Remove — PseudoTerminal handles this |
| `FileHandle.dataStream()` extension | Remove — no longer needed |

### Shell.swift

| Item | Action |
|---|---|
| `Process` extension (`inputPipe`/`outputPipe`/`errorPipe`) | Remove — no more pipes |
| `Pipe()` assignments in `process()` | Remove |

## 6. Testing

| Component | Approach | Notes |
|---|---|---|
| `PseudoTerminal.write()` | Unit test | Write bytes to primary FD, read from secondary FD to verify. Uses raw AltPTY pair, no shell spawn needed. |
| `PseudoTerminal.resize()` | Unit test | Call resize, then `ioctl(TIOCGWINSZ)` on secondary FD to verify propagation. |
| `PseudoTerminal.start()` + `outputStream` | Integration test | Spawn a real shell, send `echo hello\r`, assert output stream yields echoed text. Needs a timeout to avoid hanging. |
| `PTYResponder` | Manual via app | Now thin enough that PseudoTerminal tests cover the logic. |
| `RemotePTY.incomingMessages` | Manual via app | Depends on XPCSession testability from XPCOverlay. |

All tests use Swift Testing (`@Test`, `#expect`), consistent with the existing suite.

## 7. Files Changed

### Modified Files

| File | Changes |
|---|---|
| `TermCore/PseudoTerminal.swift` | Rewrite: add outputStream, start(), write(), resize(). Remove dead code and unused extensions. |
| `TermCore/Shell.swift` | Remove Pipe setup from process(). Remove Process extension. |
| `TermCore/RemotePTY.swift` | Fix incomingMessages AsyncStream body. |
| `rTermSupport/PTYResponder.swift` | Simplify to thin XPC adapter delegating to PseudoTerminal. |

### Unchanged

| File | Reason |
|---|---|
| `TermCore/PTY.swift` | AltPTY and FileDescriptor extensions unchanged. |
| `TermCore/XPCRequest.swift` | RemoteCommand/RemoteResponse already have the right cases. |
| `rTerm/` app-layer files | No changes needed — RemotePTY.outputData API shape is the same. |

## Out of Scope

- Dynamic window resize propagation from the app layer (SIGWINCH). This spec adds `resize()` to PseudoTerminal but does not wire it to the UI.
- Actor conversion of PseudoTerminal — class is sufficient for the single-owner pattern in rTermSupport.
- XPC reconnection on failure.
- Multiple sessions / tabs.
