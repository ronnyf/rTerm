# PseudoTerminal & PTY I/O Path Rework — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make PseudoTerminal the self-contained PTY+Shell manager, fix the end-to-end I/O path, simplify PTYResponder to a thin XPC adapter.

**Architecture:** PseudoTerminal owns the PTY FD pair, spawns the shell process using FileHandle-based I/O (no pipes), exposes output via AsyncStream<Data> backed by FileHandle.readabilityHandler, and accepts synchronous writes. PTYResponder delegates all PTY logic to PseudoTerminal. RemotePTY.incomingMessages is restored so the client-side output path works.

**Tech Stack:** Swift, Foundation (Process, FileHandle), Darwin (ioctl, write, ptsname), System (FileDescriptor), Swift Testing

**Spec:** `docs/superpowers/specs/2026-04-09-pseudoterminal-pty-io-path-design.md`

---

## Context

PseudoTerminal is currently a thin data holder — all actual PTY setup, shell spawning, output reading, and input writing live in PTYResponder. The I/O path has bugs: Shell.process() creates Pipe objects that conflict with PTY FD redirection, RemotePTY.incomingMessages is a stub (empty AsyncStream), and PseudoTerminal.connect() is dead code. This rework consolidates PTY logic into PseudoTerminal, fixes the pipeline end-to-end, and removes dead code.

---

### Task 1: Shell.swift — Remove Pipe Setup and Process Extension

**Files:**
- Modify: `TermCore/Shell.swift`

- [ ] **Step 1: Remove Pipe assignments from `process()`**

In `TermCore/Shell.swift`, remove the three `Pipe()` lines from `process()`. PseudoTerminal will assign FileHandles instead.

```swift
public func process() throws -> Process {
    let shellProcess = Process()
    
    // REMOVE these three lines:
    // shellProcess.standardInput = Pipe()
    // shellProcess.standardOutput = Pipe()
    // shellProcess.standardError = Pipe()
    
    shellProcess.executableURL = URL(filePath: executable)
    shellProcess.arguments = defaultArguments
    shellProcess.environment = ["HOME": "/Users/ronny", "PATH": "/usr/bin:/bin:/opt/homebrew/bin"]
    shellProcess.currentDirectoryURL = URL(fileURLWithPath: "/Users/ronny")
    
    return shellProcess
}
```

- [ ] **Step 2: Remove the Process extension**

Delete the entire `extension Process` block (lines 67–79) with `inputPipe`, `outputPipe`, `errorPipe`. These are no longer used and `outputPipe` had a bug (returned `standardInput` instead of `standardOutput`).

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCore -configuration Debug build`
Expected: Build succeeds. If there are callers of `inputPipe`/`outputPipe`/`errorPipe` elsewhere, the build will catch them.

- [ ] **Step 4: Commit**

```bash
git add TermCore/Shell.swift
git commit -m "refactor(Shell): remove Pipe setup and Process extension

PseudoTerminal will assign PTY FileHandles directly.
The Process extension had a bug (outputPipe returned standardInput)."
```

---

### Task 2: PseudoTerminal — write() and resize() with TDD

**Files:**
- Create: `TermCoreTests/PseudoTerminalTests.swift`
- Modify: `TermCore/PseudoTerminal.swift`

- [ ] **Step 1: Write failing tests for write() and resize()**

Create `TermCoreTests/PseudoTerminalTests.swift`:

```swift
//
//  PseudoTerminalTests.swift
//  TermCoreTests
//

import Testing
import Darwin
import System
@testable import TermCore

struct PseudoTerminalTests {
    
    @Test("write() sends bytes through PTY primary to secondary")
    func test_write_sends_bytes() throws {
        let pt = try PseudoTerminal()
        let testData = Data("hello".utf8)
        
        pt.write(testData)
        
        // Read from secondary FD to verify bytes arrived
        var buffer = [UInt8](repeating: 0, count: 64)
        let bytesRead = read(pt.pty.secondary.rawValue, &buffer, buffer.count)
        #expect(bytesRead > 0)
        let received = Data(buffer[..<bytesRead])
        #expect(received == testData)
    }
    
    @Test("resize() propagates winsize via TIOCSWINSZ")
    func test_resize_propagates_winsize() throws {
        let pt = try PseudoTerminal()
        
        pt.resize(rows: 40, cols: 120)
        
        // Read winsize from secondary FD to verify propagation
        var ws = Darwin.winsize()
        let rc = ioctl(pt.pty.secondary.rawValue, TIOCGWINSZ, &ws)
        #expect(rc == 0)
        #expect(ws.ws_row == 40)
        #expect(ws.ws_col == 120)
        #expect(pt.winsize.ws_row == 40)
        #expect(pt.winsize.ws_col == 120)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests -only-testing TermCoreTests/PseudoTerminalTests test`
Expected: FAIL — `write()` and `resize()` don't exist yet (or have wrong implementations).

- [ ] **Step 3: Implement write() and resize() on PseudoTerminal**

In `TermCore/PseudoTerminal.swift`, replace the existing `PseudoTerminal` class with:

```swift
public class PseudoTerminal {
    
    public enum Errors: Swift.Error {
        case noProcess
        case posix(Int32)
        case noPtsName
    }
    
    public let shell: Shell
    public private(set) var winsize: Darwin.winsize
    public let pty: AltPTY
    
    /// Output bytes from the shell, backed by FileHandle.readabilityHandler on the primary FD.
    public let outputStream: AsyncStream<Data>
    private let outputContinuation: AsyncStream<Data>.Continuation
    
    /// FileHandle for reading from the primary FD.
    private let primaryHandle: FileHandle
    
    /// The running shell process.
    private var shellProcess: Process?
    
    let log = Logger(subsystem: "TermCore", category: "PseudoTerminal")
    
    public init(shell: Shell = .zsh, rows: UInt16 = 24, cols: UInt16 = 80) throws {
        self.shell = shell
        self.winsize = Darwin.winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        self.pty = try AltPTY()
        self.primaryHandle = FileHandle(fileDescriptor: pty.primary.rawValue, closeOnDealloc: false)
        
        (self.outputStream, self.outputContinuation) = AsyncStream<Data>.makeStream()
    }
    
    /// Writes input bytes to the PTY primary FD.
    public func write(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            let result = Darwin.write(pty.primary.rawValue, baseAddress, buffer.count)
            if result < 0 {
                log.error("write failed: \(errno)")
            }
        }
    }
    
    /// Updates window size via TIOCSWINSZ ioctl.
    public func resize(rows: UInt16, cols: UInt16) {
        winsize = Darwin.winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        var ws = winsize
        let rc = ioctl(pty.primary.rawValue, TIOCSWINSZ, &ws)
        if rc < 0 {
            log.error("TIOCSWINSZ failed: \(errno)")
        }
    }
}
```

Note: `start()` is added in Task 3. For now this is the minimal class with write/resize. Replace only the `PseudoTerminal` class definition (lines 13–83 of the original file) — the `FileDescriptor` and `FileHandle` extensions below the class remain for now and are removed in Task 4. Remove the `AsyncAlgorithms` import since `AsyncChannel` is no longer used.

The imports for the file should be:

```swift
import Foundation
import OSLog
import System
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests -only-testing TermCoreTests/PseudoTerminalTests test`
Expected: PASS

- [ ] **Step 5: Add test file to Xcode project**

Add `TermCoreTests/PseudoTerminalTests.swift` to the `TermCoreTests` target in `rTerm.xcodeproj`. This can be done via Xcode (File → Add Files) or by editing `project.pbxproj`.

- [ ] **Step 6: Commit**

```bash
git add TermCoreTests/PseudoTerminalTests.swift TermCore/PseudoTerminal.swift rTerm.xcodeproj/project.pbxproj
git commit -m "feat(PseudoTerminal): add write() and resize() with tests

TDD: tests verify bytes flow through PTY pair and winsize
propagates via TIOCSWINSZ ioctl."
```

---

### Task 3: PseudoTerminal — start() and outputStream

**Files:**
- Modify: `TermCoreTests/PseudoTerminalTests.swift`
- Modify: `TermCore/PseudoTerminal.swift`

- [ ] **Step 1: Write failing integration test for start() + outputStream**

Add to `TermCoreTests/PseudoTerminalTests.swift`:

```swift
@Test("start() spawns shell and outputStream yields data")
func test_start_and_output_stream() async throws {
    let pt = try PseudoTerminal(shell: .sh)
    let ttyName = try pt.start()
    
    #expect(!ttyName.isEmpty)
    
    // Send a command that produces known output
    let command = Data("echo hello\r".utf8)
    pt.write(command)
    
    // Read first chunk from outputStream with a timeout
    let result = try await withThrowingTaskGroup(of: Data?.self) { group in
        group.addTask {
            for await data in pt.outputStream {
                return data
            }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            return nil
        }
        
        let first = try await group.next() ?? nil
        group.cancelAll()
        return first
    }
    
    #expect(result != nil)
    #expect(result!.count > 0)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests -only-testing TermCoreTests/PseudoTerminalTests/test_start_and_output_stream test`
Expected: FAIL — `start()` doesn't exist yet.

- [ ] **Step 3: Implement start() on PseudoTerminal**

Add the `start()` method to `PseudoTerminal` in `TermCore/PseudoTerminal.swift`:

```swift
/// Spawns the shell process, begins reading output. Returns the tty name.
public func start() throws -> String {
    guard let ptsName = ptsname(pty.secondary.rawValue) else {
        throw Errors.noPtsName
    }
    let ttyName = String(cString: ptsName)
    
    // Set controlling terminal on parent — child inherits via fork
    let tioResult = ioctl(pty.secondary.rawValue, TIOCSCTTY, 0)
    if tioResult < 0 {
        log.warning("TIOCSCTTY failed: \(errno)")
    }
    
    // Create the shell process
    let process = try shell.process()
    let secondaryHandle = FileHandle(fileDescriptor: pty.secondary.rawValue, closeOnDealloc: false)
    process.standardInput = secondaryHandle
    process.standardOutput = secondaryHandle
    process.standardError = secondaryHandle
    
    // Hook up output reading before starting the shell
    primaryHandle.readabilityHandler = { [weak self] handle in
        let data = handle.availableData
        if data.isEmpty {
            self?.outputContinuation.finish()
            handle.readabilityHandler = nil
        } else {
            self?.outputContinuation.yield(data)
        }
    }
    
    // Shell termination cleanup
    process.terminationHandler = { [weak self] _ in
        self?.primaryHandle.readabilityHandler = nil
        self?.outputContinuation.finish()
    }
    
    try process.run()
    self.shellProcess = process
    
    // Close the secondary FD — the shell process has inherited it
    try pty.secondary.close()
    
    return ttyName
}
```

Also add `deinit` for cleanup:

```swift
deinit {
    primaryHandle.readabilityHandler = nil
    outputContinuation.finish()
    if let shellProcess, shellProcess.isRunning {
        shellProcess.terminate()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests -only-testing TermCoreTests/PseudoTerminalTests/test_start_and_output_stream test`
Expected: PASS

- [ ] **Step 5: Run all PseudoTerminal tests**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests -only-testing TermCoreTests/PseudoTerminalTests test`
Expected: All pass. Note: the `test_write_sends_bytes` test reads from the secondary FD directly. After `start()` is called the secondary is closed, but these tests create separate PseudoTerminal instances so there's no conflict.

- [ ] **Step 6: Commit**

```bash
git add TermCore/PseudoTerminal.swift TermCoreTests/PseudoTerminalTests.swift
git commit -m "feat(PseudoTerminal): add start() with FileHandle-based output streaming

Spawns shell process using PTY secondary FileHandles (no pipes).
Reads output via readabilityHandler on primary FD into AsyncStream.
Includes integration test that spawns /bin/sh and verifies output."
```

---

### Task 4: Dead Code Removal from PseudoTerminal.swift

**Files:**
- Modify: `TermCore/PseudoTerminal.swift`

- [ ] **Step 1: Remove dead extensions and commented-out code**

From `TermCore/PseudoTerminal.swift`, remove everything outside the `PseudoTerminal` class:

1. Remove the `FileDescriptor` extension with `copy(accessMode:)` and `tiosctty()` (tiosctty logic is now inline in `start()`).
2. Remove the empty `FileHandle` extension (commented-out `values()` method).
3. Remove any remaining commented-out methods (`stream(fd:)`, etc.).

The file should contain only the `PseudoTerminal` class and its imports.

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCore -configuration Debug build`
Expected: Build succeeds. If `tiosctty()` or `copy(accessMode:)` are called elsewhere, the build will catch it.

- [ ] **Step 3: Run all tests**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test`
Expected: All pass.

- [ ] **Step 4: Commit**

```bash
git add TermCore/PseudoTerminal.swift
git commit -m "chore: remove dead code from PseudoTerminal.swift

Remove unused FileDescriptor extensions (copy, tiosctty),
commented-out stream/values methods, and FileHandle extension."
```

---

### Task 5: PTYResponder Simplification

**Files:**
- Modify: `rTermSupport/PTYResponder.swift`

- [ ] **Step 1: Rewrite PTYResponder to delegate to PseudoTerminal**

Replace the contents of `rTermSupport/PTYResponder.swift` with:

```swift
//
//  PTYResponder.swift
//  rTermSupport
//
//  Created by Ronny Falk on 6/22/24.
//

import Foundation
import OSLog
import TermCore
import XPCOverlay

class PTYResponder {
    
    let log = Logger(subsystem: "rTermSupport", category: "PTYResponder")
    
    var pseudoTerminal: PseudoTerminal?
    var outputTask: Task<Void, Error>?
    
    deinit {
        outputTask?.cancel()
    }
    
    func spawn(session: XPCSession) throws -> RemoteResponse {
        let pt = try PseudoTerminal()
        let ttyName = try pt.start()
        self.pseudoTerminal = pt
        
        outputTask = Task { [log] in
            for await data in pt.outputStream {
                try Task.checkCancellation()
                try session.send(RemoteResponse.stdout(data))
            }
            log.info("output stream finished")
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
            log.error("unknown request: \(String(describing: request))")
            return nil
        }
    }
}
```

This removes: `primaryFD`, `shellTask`, the task group, all dup2/tiosctty/fd.close logic, the `Errors` enum, `darwinFailureDescription()`, and the `FileHandle.dataStream()` extension.

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build`
Expected: Build succeeds. Use the rTerm scheme (not just TermCore) since PTYResponder is in the rTermSupport target.

- [ ] **Step 3: Commit**

```bash
git add rTermSupport/PTYResponder.swift
git commit -m "refactor(PTYResponder): simplify to thin XPC adapter

PTYResponder now delegates all PTY logic to PseudoTerminal.
Removed dup2/tiosctty/pipe reading, task group, and dead code."
```

---

### Task 6: RemotePTY.incomingMessages Fix

**Files:**
- Modify: `TermCore/RemotePTY.swift`

- [ ] **Step 1: Restore the incomingMessages AsyncStream body**

In `TermCore/RemotePTY.swift`, find the `XPCSession.incomingMessages` extension (line ~138) and restore the body:

```swift
extension XPCSession {
    
    func incomingMessages<Message: Decodable, Result>(transform: @escaping (Message) -> Result?) -> some AsyncSequence<Result, Never> {
        AsyncStream(Result.self) { continuation in
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

Note: Verify that `XPCSession` from XPCOverlay has a `setIncomingMessageHandler` method with this signature. If the API differs, adapt accordingly — the intent is to register a handler that transforms incoming XPC messages and yields them into the stream.

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build`
Expected: Build succeeds. If `setIncomingMessageHandler` doesn't exist on `XPCSession`, the build will fail and we'll need to check the XPCOverlay API.

- [ ] **Step 3: Commit**

```bash
git add TermCore/RemotePTY.swift
git commit -m "fix(RemotePTY): restore incomingMessages AsyncStream body

The AsyncStream was empty (never yielded), so RemotePTY.outputData
never produced values on the client side."
```

---

## Verification

After all tasks are complete:

1. **Unit tests pass:** `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test`
2. **Full build:** `xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build`
3. **Manual integration test:** Launch the app, verify that typing commands produces output in the terminal view. The full pipeline is: keystrokes → KeyEncoder → RemotePTY.send(.input) → XPC → PTYResponder → PseudoTerminal.write() → shell → PTY primary → PseudoTerminal.outputStream → XPC → RemotePTY.outputData → TerminalParser → ScreenModel → Metal render.
