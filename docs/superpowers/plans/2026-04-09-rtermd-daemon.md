# rtermd Daemon Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the XPC Application Service (`rTermSupport`) with a LaunchAgent daemon (`rtermd`) that supports tmux-style detach/reattach of terminal sessions.

**Architecture:** A standalone daemon binary registered as a LaunchAgent, communicating with the app via Mach service XPC. The daemon owns shell processes (via `forkpty()`), `TerminalParser`, and `ScreenModel` per session. Sessions survive app quit/crash.

**Tech Stack:** Swift 5, `import XPC` (public XPC framework, macOS 14+), Darwin (`forkpty`, `execve`, signal handling), Swift Testing framework, Xcode project (no SPM).

**Spec:** `docs/superpowers/specs/2026-04-09-daemon-architecture-design.md`

---

## File Structure

### New Files
- `TermCore/DaemonProtocol.swift` — `DaemonRequest`, `DaemonResponse`, `DaemonError`, `SessionInfo`
- `TermCore/DaemonClient.swift` — XPC client replacing `RemotePTY`
- `TermCoreTests/DaemonProtocolTests.swift` — Codable round-trip tests
- `TermCoreTests/CodableTests.swift` — Cell, Cursor, ScreenSnapshot, Shell Codable tests
- `rtermd/main.swift` — daemon entry point
- `rtermd/Session.swift` — per-session state (PTY + parser + screen)
- `rtermd/SessionManager.swift` — actor managing all sessions
- `rtermd/DaemonPeerHandler.swift` — XPC peer handler
- `rtermd/ShellSpawner.swift` — forkpty wrapper
- `rtermd/Info.plist` — daemon bundle info
- `rtermd/rtermd.entitlements` — app-group entitlement
- `rtermd/group.com.ronnyf.rterm.rtermd.plist` — LaunchAgent plist

### Modified Files
- `TermCore/Cell.swift` — add Codable to Cell, Cursor, ScreenSnapshot
- `TermCore/Shell.swift` — add Codable, Sendable, remove `+m`, fix `.custom`
- `TermCore/ScreenModel.swift` — add `restore(from:)` method
- `rTerm/ContentView.swift` — update TerminalSession to use DaemonClient
- `rTerm/rTerm.entitlements` — add app-group entitlement

### Dropped (later task)
- `rTermSupport/` — entire target (replaced by rtermd)
- `rTermLauncher/` — entire target (superseded)

---

## Phase A: Foundation Types ✅ COMPLETE

> All tasks in Phase A are implemented and tested. Do not re-implement.

### Task 1: Shell Enum — Codable, Sendable, Fix Arguments

**Files:**
- Modify: `TermCore/Shell.swift`
- Create: `TermCoreTests/CodableTests.swift`

The Shell enum needs Codable + Sendable. The `.custom` case calls `fatalError` and prevents auto-derived Codable. The `+m` flag disables job control and must be removed (forkpty provides proper sessions).

- [ ] **Step 1: Write failing test for Shell Codable round-trip**

```swift
// TermCoreTests/CodableTests.swift
import Testing
@testable import TermCore

struct CodableTests {
    @Test func shell_codable_roundtrip() throws {
        let shells: [Shell] = [.bash, .zsh, .fish, .sh]
        for shell in shells {
            let data = try JSONEncoder().encode(shell)
            let decoded = try JSONDecoder().decode(Shell.self, from: data)
            #expect(decoded == shell)
        }
    }

    @Test func shell_sendable() {
        // Compile-time check: Shell can cross isolation boundaries
        let shell: Shell = .zsh
        Task { @Sendable in
            _ = shell.executable
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests -only-testing TermCoreTests/CodableTests/shell_codable_roundtrip test 2>&1 | tail -20`

Expected: Compilation error — Shell does not conform to Codable

- [ ] **Step 3: Update Shell enum**

In `TermCore/Shell.swift`:
- Remove the `.custom` case entirely (it fatalErrors, is unused)
- Add `: Codable, Sendable` conformance
- Add `: Equatable` if not present
- Remove `+m` from `defaultArguments` for bash and zsh
- Rename `executable` references if needed (it's already `executable`)

```swift
// TermCore/Shell.swift
public enum Shell: Codable, Sendable, Equatable {
    case bash
    case zsh
    case fish
    case sh
}

extension Shell {
    public var executable: String {
        switch self {
        case .bash: "/bin/bash"
        case .zsh:  "/bin/zsh"
        case .fish: "/opt/homebrew/bin/fish"
        case .sh:   "/bin/sh"
        }
    }

    public var defaultArguments: [String] {
        switch self {
        case .bash: ["--norc", "--noprofile"]
        case .zsh:  ["-f"]
        case .fish: []
        case .sh:   []
        }
    }

    /// Build a configured Process for this shell (used by legacy PseudoTerminal path)
    public func process() throws -> Process {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = defaultArguments
        process.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/opt/homebrew/bin",
            "TERM": "dumb",
            "SHELL": executable,
        ]
        process.currentDirectoryURL = URL(filePath: NSHomeDirectory())
        return process
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests -only-testing TermCoreTests/CodableTests test 2>&1 | tail -20`

Expected: PASS

- [ ] **Step 5: Commit**

```
git add TermCore/Shell.swift TermCoreTests/CodableTests.swift
git commit -m "feat(TermCore): make Shell Codable+Sendable, remove +m flag, drop .custom case"
```

---

### Task 2: Cell, Cursor, ScreenSnapshot — Codable Conformance

**Files:**
- Modify: `TermCore/Cell.swift`
- Modify: `TermCoreTests/CodableTests.swift`

Character does not auto-derive Codable. Cell contains Character. ScreenSnapshot contains ContiguousArray<Cell>. Custom Codable required.

- [ ] **Step 1: Write failing tests**

Append to `TermCoreTests/CodableTests.swift`:

```swift
@Test func cell_codable_roundtrip() throws {
    let cell = Cell(character: "A")
    let data = try JSONEncoder().encode(cell)
    let decoded = try JSONDecoder().decode(Cell.self, from: data)
    #expect(decoded == cell)
}

@Test func cell_empty_codable_roundtrip() throws {
    let data = try JSONEncoder().encode(Cell.empty)
    let decoded = try JSONDecoder().decode(Cell.self, from: data)
    #expect(decoded == Cell.empty)
}

@Test func cursor_codable_roundtrip() throws {
    let cursor = Cursor(row: 5, col: 10)
    let data = try JSONEncoder().encode(cursor)
    let decoded = try JSONDecoder().decode(Cursor.self, from: data)
    #expect(decoded == cursor)
}

@Test func screenSnapshot_codable_roundtrip() throws {
    var cells = ContiguousArray<Cell>(repeating: .empty, count: 6)
    cells[0] = Cell(character: "H")
    cells[1] = Cell(character: "i")
    let snapshot = ScreenSnapshot(cells: cells, cols: 3, rows: 2, cursor: Cursor(row: 0, col: 2))
    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(ScreenSnapshot.self, from: data)
    #expect(decoded == snapshot)
}

@Test func cell_unicode_codable_roundtrip() throws {
    let cell = Cell(character: "\u{1F600}")  // emoji
    let data = try JSONEncoder().encode(cell)
    let decoded = try JSONDecoder().decode(Cell.self, from: data)
    #expect(decoded.character == "\u{1F600}")
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests -only-testing TermCoreTests/CodableTests/cell_codable_roundtrip test 2>&1 | tail -20`

Expected: Compilation error — Cell does not conform to Codable

- [ ] **Step 3: Add Codable conformances in Cell.swift**

```swift
// Add to TermCore/Cell.swift

extension Cell: Codable {
    enum CodingKeys: String, CodingKey { case character }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(String(character), forKey: .character)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let str = try container.decode(String.self, forKey: .character)
        guard let ch = str.first, str.count == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .character, in: container,
                debugDescription: "Expected single character, got \(str.count) characters"
            )
        }
        self.character = ch
    }
}

extension Cursor: Codable {}

extension ScreenSnapshot: Codable {
    enum CodingKeys: String, CodingKey { case cells, cols, rows, cursor }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Array(cells), forKey: .cells)
        try container.encode(cols, forKey: .cols)
        try container.encode(rows, forKey: .rows)
        try container.encode(cursor, forKey: .cursor)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let cellArray = try container.decode([Cell].self, forKey: .cells)
        self.cells = ContiguousArray(cellArray)
        self.cols = try container.decode(Int.self, forKey: .cols)
        self.rows = try container.decode(Int.self, forKey: .rows)
        self.cursor = try container.decode(Cursor.self, forKey: .cursor)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests -only-testing TermCoreTests/CodableTests test 2>&1 | tail -20`

Expected: All PASS

- [ ] **Step 5: Commit**

```
git add TermCore/Cell.swift TermCoreTests/CodableTests.swift
git commit -m "feat(TermCore): add Codable conformance to Cell, Cursor, ScreenSnapshot"
```

---

### Task 3: DaemonProtocol — Request/Response/Error/SessionInfo

**Files:**
- Create: `TermCore/DaemonProtocol.swift`
- Create: `TermCoreTests/DaemonProtocolTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// TermCoreTests/DaemonProtocolTests.swift
import Testing
@testable import TermCore

struct DaemonProtocolTests {
    @Test func daemonRequest_codable_roundtrip() throws {
        let requests: [DaemonRequest] = [
            .listSessions,
            .createSession(shell: .zsh, rows: 24, cols: 80),
            .attach(sessionID: 42),
            .detach(sessionID: 42),
            .input(sessionID: 0, data: Data("hello".utf8)),
            .resize(sessionID: 1, rows: 40, cols: 120),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for request in requests {
            let data = try encoder.encode(request)
            let decoded = try decoder.decode(DaemonRequest.self, from: data)
            #expect(decoded == request)
        }
    }

    @Test func daemonResponse_codable_roundtrip() throws {
        let info = SessionInfo(
            id: 0, shell: .zsh, tty: "/dev/ttys003", pid: 12345,
            createdAt: Date(), title: nil, rows: 24, cols: 80, hasClient: true
        )
        let snapshot = ScreenSnapshot(
            cells: ContiguousArray(repeating: .empty, count: 4),
            cols: 2, rows: 2, cursor: Cursor(row: 0, col: 0)
        )
        let responses: [DaemonResponse] = [
            .sessions([info]),
            .sessionCreated(info),
            .screenSnapshot(sessionID: 0, snapshot: snapshot),
            .sessionEnded(sessionID: 0, exitCode: 0),
            .output(sessionID: 1, data: Data([0x41, 0x42])),
            .error(.sessionNotFound(99)),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for response in responses {
            let data = try encoder.encode(response)
            let decoded = try decoder.decode(DaemonResponse.self, from: data)
            #expect(decoded == response)
        }
    }

    @Test func daemonError_codable_roundtrip() throws {
        let errors: [DaemonError] = [
            .sessionNotFound(5),
            .spawnFailed(13),
            .alreadyAttached(2),
            .internalError("something broke"),
        ]
        for error in errors {
            let data = try JSONEncoder().encode(error)
            let decoded = try JSONDecoder().decode(DaemonError.self, from: data)
            #expect(decoded == error)
        }
    }
}
```

- [ ] **Step 2: Run to verify compilation fails (types don't exist)**

- [ ] **Step 3: Implement DaemonProtocol.swift**

```swift
// TermCore/DaemonProtocol.swift
import Foundation

public typealias SessionID = Int

public enum DaemonRequest: Codable, Sendable, Equatable {
    case listSessions
    case createSession(shell: Shell, rows: UInt16, cols: UInt16)
    case attach(sessionID: SessionID)
    case detach(sessionID: SessionID)
    case input(sessionID: SessionID, data: Data)
    case resize(sessionID: SessionID, rows: UInt16, cols: UInt16)
}

public enum DaemonResponse: Codable, Sendable, Equatable {
    case sessions([SessionInfo])
    case sessionCreated(SessionInfo)
    case screenSnapshot(sessionID: SessionID, snapshot: ScreenSnapshot)
    case sessionEnded(sessionID: SessionID, exitCode: Int32)
    case output(sessionID: SessionID, data: Data)
    case error(DaemonError)
}

public enum DaemonError: Error, Codable, Sendable, Equatable {
    case sessionNotFound(SessionID)
    case spawnFailed(Int32)
    case alreadyAttached(SessionID)
    case internalError(String)
}

public struct SessionInfo: Codable, Sendable, Equatable {
    public let id: SessionID
    public let shell: Shell
    public let tty: String
    public let pid: Int32
    public let createdAt: Date
    public let title: String?
    public let rows: UInt16
    public let cols: UInt16
    public let hasClient: Bool

    public init(
        id: SessionID, shell: Shell, tty: String, pid: Int32,
        createdAt: Date, title: String?, rows: UInt16, cols: UInt16, hasClient: Bool
    ) {
        self.id = id
        self.shell = shell
        self.tty = tty
        self.pid = pid
        self.createdAt = createdAt
        self.title = title
        self.rows = rows
        self.cols = cols
        self.hasClient = hasClient
    }
}
```

- [ ] **Step 4: Run tests**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests -only-testing TermCoreTests/DaemonProtocolTests test 2>&1 | tail -20`

Expected: All PASS

- [ ] **Step 5: Commit**

```
git add TermCore/DaemonProtocol.swift TermCoreTests/DaemonProtocolTests.swift
git commit -m "feat(TermCore): add DaemonRequest, DaemonResponse, DaemonError, SessionInfo protocol types"
```

---

### Task 4: ScreenModel — Add restore(from:) Method

**Files:**
- Modify: `TermCore/ScreenModel.swift`
- Modify: `TermCoreTests/ScreenModelTests.swift`

Needed for reattach: client receives a ScreenSnapshot and resets its local ScreenModel.

- [ ] **Step 1: Write failing test**

Append to `TermCoreTests/ScreenModelTests.swift`:

```swift
@Test func restore_from_snapshot() async {
    let model = ScreenModel(cols: 3, rows: 2)
    await model.apply([.printable("A"), .printable("B"), .printable("C")])

    let snap = await model.snapshot()
    #expect(snap[0, 0].character == "A")

    // Create a new model and restore from snapshot
    let model2 = ScreenModel(cols: 3, rows: 2)
    await model2.restore(from: snap)
    let snap2 = await model2.snapshot()
    #expect(snap2 == snap)
}
```

- [ ] **Step 2: Run to verify failure (method doesn't exist)**

- [ ] **Step 3: Add restore method to ScreenModel**

In `TermCore/ScreenModel.swift`, add:

```swift
public func restore(from snapshot: ScreenSnapshot) {
    precondition(snapshot.cols == cols && snapshot.rows == rows,
                 "Snapshot dimensions (\(snapshot.cols)x\(snapshot.rows)) don't match model (\(cols)x\(rows))")
    grid = snapshot.cells
    cursor = snapshot.cursor
    _latestSnapshot.withLock { $0 = snapshot }
}
```

- [ ] **Step 4: Run test to verify pass**
- [ ] **Step 5: Commit**

```
git add TermCore/ScreenModel.swift TermCoreTests/ScreenModelTests.swift
git commit -m "feat(TermCore): add ScreenModel.restore(from:) for reattach support"
```

---

## Architecture Revision: Single-Queue Concurrency (applies to Phases B and C)

> This revision supersedes the actor-based concurrency model in the original Phase B/C tasks below. The original task descriptions for ShellSpawner (Task 6), Session (Task 7), and the foundation work remain valid. The concurrency model for SessionManager, DaemonPeerHandler, and DaemonClient changes as described here.

### Problem

The original design used `SessionManager` as a Swift actor and bridged from GCD (XPC callbacks) to the actor using `DispatchSemaphore` + `Task`. This is fundamentally broken:

- **Tasks are not threads** — they run on the cooperative thread pool and cannot interact with dispatch semaphores without risking pool starvation and deadlocks.
- **XPC sends on the blocked queue** — `XPCSession.send()` may need the same GCD queue that the semaphore is blocking, causing deadlock.
- **Violates forward-progress guarantees** — Swift Concurrency requires that cooperative threads never block on external synchronization primitives.

### Solution: Single Dispatch Queue

One shared serial `DispatchQueue` serializes all daemon state access. No actors (except DaemonPeerHandler with custom executor), no semaphores, no GCD-to-async bridging.

**Daemon queue ownership:**
- `rtermd/main.swift` creates the serial queue and passes it to `XPCListener` as `targetQueue`
- All XPC callbacks arrive on this queue
- `SessionManager` is a plain class — the queue serializes all access
- `Session` is a class — PTY readability handler also targets this queue
- `DaemonPeerHandler` is an actor with a custom `SerialExecutor` backed by this queue — since XPC callbacks are already on the queue, the actor is already isolated

**DaemonPeerHandler pattern:**
- Implements `XPCPeerHandler` protocol
- Uses `assumeIsolated` from the XPC callback to enter actor context (callback is on the actor's queue)
- For request-reply operations: uses `XPCReceivedMessage.reply()` for deferred replies — returns `nil` from the handler, does the work, calls `message.reply(response)` when done
- For fire-and-forget operations: does the work directly (already on the right queue)
- No semaphores, no Task bridging, no blocking

**SessionManager:**
- Plain class, not an actor
- All methods are synchronous — called directly from DaemonPeerHandler
- No locks, no `@unchecked Sendable`, no async/await

**Session:**
- Class (Dictionary requires Copyable values; needs deinit for FD/process cleanup)
- FileHandle readabilityHandler targets the daemon queue — all state access is single-threaded
- No `OSAllocatedUnfairLock` needed

### XPC API Notes (`import XPC`, macOS 14+)

**Client-side session creation (DaemonClient):**
- Use `XPCSession(machService:targetQueue:options:incomingMessageHandler:cancellationHandler:)` constructor
- Pass handlers in the constructor — session auto-activates, no need for `.inactive` + manual `activate()`
- **Never call `setIncomingMessageHandler` on an active session** — crashes with "XPC API Misuse"
- `targetQueue: nil` uses the system default

**Server-side listener (main.swift):**
- `XPCListener(service:targetQueue:incomingSessionHandler:)` with the daemon queue as targetQueue
- `request.accept { session in DaemonPeerHandler(...) }` for per-client handler objects

**Deferred replies:**
- `XPCReceivedMessage.reply(_:)` sends a reply asynchronously after returning `nil` from the handler
- The client's `sendSync` blocks until `reply()` is called — this is documented XPC behavior

### Race Condition Fix

The client sends `.createSession` and `.attach` as **two separate XPC calls**. After `.createSession` returns `sessionCreated(info)`, the client sends `.attach(sessionID:)` which returns `screenSnapshot`. The snapshot captures whatever the shell produced between creation and attach.

In `Session.attach()`: add client to fan-out list BEFORE taking the snapshot, so no output is lost between those two operations.

---

## Phase B: Daemon Core

> **Tasks 5-6:** ✅ COMPLETE — target configured, ShellSpawner implemented. Do not re-implement.
>
> **Tasks 7-9:** ⚠️ NEED REWORK per the Architecture Revision above. The existing code uses actors + semaphores. Rewrite Session, SessionManager, DaemonPeerHandler, and main.swift to use the single-queue model.

### Task 5: Create rtermd Xcode Target ✅ COMPLETE

**Files:**
- Create rtermd target in Xcode project (command-line tool)
- Create: `rtermd/main.swift` (placeholder)
- Create: `rtermd/Info.plist`
- Create: `rtermd/rtermd.entitlements`

This task requires Xcode project manipulation. Create a new macOS Command Line Tool target named `rtermd` in the Xcode project. Link it against TermCore framework.

- [ ] **Step 1: Create directory and placeholder files**

```bash
mkdir -p rtermd
```

Create `rtermd/main.swift`:
```swift
import Foundation
import TermCore

print("rtermd starting...")
dispatchMain()
```

Create `rtermd/rtermd.entitlements`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.ronnyf.rterm</string>
    </array>
</dict>
</plist>
```

Create `rtermd/group.com.ronnyf.rterm.rtermd.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>group.com.ronnyf.rterm.rtermd</string>
    <key>Program</key>
    <string>/usr/local/bin/rtermd</string>
    <key>MachServices</key>
    <dict>
        <key>group.com.ronnyf.rterm.rtermd</key>
        <true/>
    </dict>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
</dict>
</plist>
```

- [ ] **Step 2: Add target to Xcode project**

Use Xcode MCP or manual project file editing to add the `rtermd` target as a macOS Command Line Tool that links against TermCore.framework.

- [ ] **Step 3: Verify it builds**

Run: `xcodebuild -project rTerm.xcodeproj -scheme rtermd -configuration Debug build 2>&1 | tail -10`

- [ ] **Step 4: Commit**

```
git add rtermd/ rTerm.xcodeproj/
git commit -m "feat: add rtermd command-line tool target with LaunchAgent plist"
```

---

### Task 6: ShellSpawner — forkpty Wrapper ✅ COMPLETE

**Files:**
- Create: `rtermd/ShellSpawner.swift`
- Test via integration test in Task 7

This is the pure-Swift forkpty wrapper with proper signal blocking, FD hygiene, and pre-fork environment construction. See spec Section 1 for the complete implementation.

- [ ] **Step 1: Create ShellSpawner.swift**

```swift
// rtermd/ShellSpawner.swift
import Darwin
import Foundation
import TermCore

struct SpawnResult {
    let pid: pid_t
    let primaryFD: Int32
    let ttyName: String
}

enum ShellSpawner {
    static func spawn(shell: Shell, rows: UInt16, cols: UInt16) throws -> SpawnResult {
        // Build argv and envp BEFORE fork
        let shellPath = shell.executable
        let args = [shellPath] + shell.defaultArguments
        let cArgs = args.map { strdup($0)! }
        defer { cArgs.forEach { free($0) } }
        var argv = cArgs.map { Optional($0) }
        argv.append(nil)

        let envPairs = buildEnvironment(shell: shell)
        let cEnv = envPairs.map { strdup($0)! }
        defer { cEnv.forEach { free($0) } }
        var envp = cEnv.map { Optional($0) }
        envp.append(nil)

        var primaryFD: Int32 = 0
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        var ttyNameBuf = [CChar](repeating: 0, count: 128)

        let pid = forkpty(&primaryFD, &ttyNameBuf, nil, &ws)

        if pid == 0 {
            // === CHILD ===
            closeFDsAboveStderr()
            blockSignalsAndSetForeground()
            // Use cArgs[0] (C pointer), NOT shellPath (Swift String) — String bridging allocates
            argv.withUnsafeMutableBufferPointer { argvBuf in
                envp.withUnsafeMutableBufferPointer { envpBuf in
                    execve(cArgs[0], argvBuf.baseAddress, envpBuf.baseAddress)
                }
            }
            _exit(127)
        }

        guard pid > 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EFAULT)
        }

        // === PARENT ===
        fcntl(primaryFD, F_SETFD, FD_CLOEXEC)
        let ttyName = String(cString: ttyNameBuf)
        return SpawnResult(pid: pid, primaryFD: primaryFD, ttyName: ttyName)
    }

    private static func buildEnvironment(shell: Shell) -> [String] {
        var env: [String] = []
        env.append("TERM=xterm-256color")
        env.append("SHELL=\(shell.executable)")
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            env.append("HOME=\(String(cString: home))")
        }
        env.append("PATH=/usr/bin:/bin:/usr/local/bin:/usr/sbin:/sbin:/opt/homebrew/bin")
        if let lang = getenv("LANG") {
            env.append("LANG=\(String(cString: lang))")
        }
        return env
    }

    private static func closeFDsAboveStderr() {
        if let dir = opendir("/dev/fd") {
            defer { closedir(dir) }
            while let entry = readdir(dir) {
                let namePtr = withUnsafePointer(to: entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen)) {
                        String(cString: $0)
                    }
                }
                if let fd = Int32(namePtr), fd > STDERR_FILENO {
                    close(fd)
                }
            }
        }
    }

    private static func blockSignalsAndSetForeground() {
        var blockSet = sigset_t()
        var savedSet = sigset_t()
        sigemptyset(&blockSet)
        sigaddset(&blockSet, SIGTTIN)
        sigaddset(&blockSet, SIGTTOU)
        sigaddset(&blockSet, SIGTSTP)
        sigprocmask(SIG_BLOCK, &blockSet, &savedSet)
        tcsetpgrp(STDIN_FILENO, getpid())
        sigprocmask(SIG_SETMASK, &savedSet, nil)
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild -project rTerm.xcodeproj -scheme rtermd build 2>&1 | tail -10`

- [ ] **Step 3: Commit**

```
git add rtermd/ShellSpawner.swift
git commit -m "feat(rtermd): add ShellSpawner with forkpty, signal blocking, FD hygiene"
```

---

### Task 7: Session Class ⚠️ REWORK — see Architecture Revision

**Files:**
- Create: `rtermd/Session.swift`

Each Session owns a spawned shell, reads PTY output, parses through TerminalParser, updates ScreenModel, and fans out raw bytes to attached clients.

**Rework notes:**
- Use a **static logger** (`private static let log`) — no reason to allocate a Logger per instance when subsystem/category are identical across all sessions.
- Rename `private let lock` → `private let state` — the name should describe the contents, not the synchronization mechanism. The `OSAllocatedUnfairLock<SessionState>` type already communicates locking.
- **Split output consumption** into sync and async parts. With the daemon queue model, the FileHandle readabilityHandler targets the daemon queue and calls parse → apply → fanOut **synchronously** — no AsyncStream, no Task needed. The stream/task machinery was only needed when crossing isolation boundaries. On a single queue, the readability handler IS the consumer.
- If `OSAllocatedUnfairLock` is no longer needed (all access on daemon queue), remove it and use plain stored properties.

- [ ] **Step 1: Implement Session**

```swift
// rtermd/Session.swift
import Foundation
import TermCore
import os
import XPCOverlay

final class Session: @unchecked Sendable {
    let id: SessionID
    let shell: Shell
    let tty: String
    let pid: pid_t
    let primaryFD: Int32
    let createdAt: Date
    let screenModel: ScreenModel
    private var parser: TerminalParser
    private let log = Logger(subsystem: "rtermd", category: "Session")

    // PTY read via FileHandle.readabilityHandler → AsyncStream (same pattern as PseudoTerminal)
    private let primaryHandle: FileHandle
    private let outputStream: AsyncStream<Data>
    private let outputContinuation: AsyncStream<Data>.Continuation
    private var outputTask: Task<Void, Never>?

    private let lock = OSAllocatedUnfairLock<SessionState>(initialState: .init())

    struct SessionState: Sendable {
        var attachedClients: [XPCSession] = []
        var shellExited = false
        var exitCode: Int32 = 0
    }

    init(id: SessionID, shell: Shell, rows: UInt16, cols: UInt16) throws {
        let result = try ShellSpawner.spawn(shell: shell, rows: rows, cols: cols)
        self.id = id
        self.shell = shell
        self.tty = result.ttyName
        self.pid = result.pid
        self.primaryFD = result.primaryFD
        self.createdAt = Date()
        self.screenModel = ScreenModel(cols: Int(cols), rows: Int(rows))
        self.parser = TerminalParser()
        self.primaryHandle = FileHandle(fileDescriptor: result.primaryFD, closeOnDealloc: false)

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.outputStream = stream
        self.outputContinuation = continuation

        // FileHandle.readabilityHandler runs on a background queue (Foundation manages it)
        self.primaryHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                self?.outputContinuation.finish()
                handle.readabilityHandler = nil
            } else {
                self?.outputContinuation.yield(data)
            }
        }
    }

    /// Consume the output stream: parse → screen model → fan-out to clients.
    func startOutputConsumer() {
        outputTask = Task { [weak self] in
            guard let self else { return }
            for await data in self.outputStream {
                // Parse into screen model FIRST (ordering invariant)
                let events = self.parser.parse(data)
                await self.screenModel.apply(events)

                // Fan out raw bytes to all attached clients
                self.lock.withLock { state in
                    for client in state.attachedClients {
                        do {
                            try client.send(DaemonResponse.output(sessionID: self.id, data: data))
                        } catch {
                            self.log.error("Failed to send output to client: \(error)")
                        }
                    }
                }
            }
            self.log.info("Session \(self.id): output stream ended")
        }
    }

    func attach(client: XPCSession) async -> ScreenSnapshot {
        let snapshot = await screenModel.snapshot()
        lock.withLock { state in
            state.attachedClients.append(client)
        }
        return snapshot
    }

    func detach(client: XPCSession) {
        lock.withLock { state in
            state.attachedClients.removeAll { $0 === client }
        }
    }

    func write(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(primaryFD, ptr + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    log.error("PTY write failed: \(errno)")
                    return
                }
                offset += written
            }
        }
    }

    func resize(rows: UInt16, cols: UInt16) {
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        ioctl(primaryFD, TIOCSWINSZ, &ws)
    }

    func markExited(exitCode: Int32) {
        lock.withLock { state in
            state.shellExited = true
            state.exitCode = exitCode
        }
    }

    var hasClients: Bool {
        lock.withLock { !$0.attachedClients.isEmpty }
    }

    var info: SessionInfo {
        let clientCount = lock.withLock { $0.attachedClients.count }
        return SessionInfo(
            id: id, shell: shell, tty: tty, pid: Int32(pid),
            createdAt: createdAt, title: nil,
            rows: UInt16(screenModel.rows), cols: UInt16(screenModel.cols),
            hasClient: clientCount > 0
        )
    }

    func notifyClientsEnded(exitCode: Int32) {
        lock.withLock { state in
            for client in state.attachedClients {
                try? client.send(DaemonResponse.sessionEnded(sessionID: id, exitCode: exitCode))
            }
            state.attachedClients.removeAll()
        }
    }

    func stop() {
        primaryHandle.readabilityHandler = nil
        outputContinuation.finish()
        outputTask?.cancel()
        close(primaryFD)
        kill(pid, SIGTERM)
    }

    deinit {
        primaryHandle.readabilityHandler = nil
        outputContinuation.finish()
        outputTask?.cancel()
    }
}
```

- [ ] **Step 2: Build**
- [ ] **Step 3: Commit**

```
git add rtermd/Session.swift
git commit -m "feat(rtermd): add Session class — owns forkpty'd shell, PTY I/O, screen model"
```

---

### Task 8: SessionManager Actor ⚠️ REWORK — becomes plain class, see Architecture Revision

**Files:**
- Create: `rtermd/SessionManager.swift`

- [ ] **Step 1: Implement SessionManager**

```swift
// rtermd/SessionManager.swift
import Foundation
import TermCore
import os
import XPCOverlay

actor SessionManager {
    private var sessions: [SessionID: Session] = [:]
    private var nextID: SessionID = 0
    var onEmpty: (@Sendable () -> Void)?
    private let log = Logger(subsystem: "rtermd", category: "SessionManager")

    func createSession(shell: Shell, rows: UInt16, cols: UInt16) throws -> SessionInfo {
        let id = nextID
        nextID += 1
        let session = try Session(id: id, shell: shell, rows: rows, cols: cols)
        sessions[id] = session
        session.startOutputConsumer()
        log.info("Created session \(id), shell=\(shell.executable), pid=\(session.pid)")
        return session.info
    }

    func attach(sessionID: SessionID, client: XPCSession) async throws -> ScreenSnapshot {
        guard let session = sessions[sessionID] else {
            throw DaemonError.sessionNotFound(sessionID)
        }
        return await session.attach(client: client)
    }

    func detach(sessionID: SessionID, client: XPCSession) {
        sessions[sessionID]?.detach(client: client)
    }

    func handleInput(sessionID: SessionID, data: Data) throws {
        guard let session = sessions[sessionID] else {
            throw DaemonError.sessionNotFound(sessionID)
        }
        session.write(data)
    }

    func resize(sessionID: SessionID, rows: UInt16, cols: UInt16) throws {
        guard let session = sessions[sessionID] else {
            throw DaemonError.sessionNotFound(sessionID)
        }
        session.resize(rows: rows, cols: cols)
    }

    func listSessions() -> [SessionInfo] {
        sessions.values.map(\.info)
    }

    func reapChildren() {
        var status: Int32 = 0
        while true {
            let pid = waitpid(-1, &status, WNOHANG)
            if pid <= 0 { break }
            let exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1
            if let (id, session) = sessions.first(where: { $0.value.pid == pid }) {
                log.info("Session \(id) shell exited with code \(exitCode)")
                session.markExited(exitCode: exitCode)
                session.notifyClientsEnded(exitCode: exitCode)
                sessions.removeValue(forKey: id)
                checkEmpty()
            }
        }
    }

    func clientDisconnected(_ client: XPCSession) {
        for session in sessions.values {
            session.detach(client: client)
        }
    }

    func shutdownAll() {
        log.info("Shutting down all \(sessions.count) sessions")
        for session in sessions.values {
            session.stop()
        }
        sessions.removeAll()
    }

    private func checkEmpty() {
        if sessions.isEmpty {
            log.info("No sessions remaining")
            onEmpty?()
        }
    }
}
```

- [ ] **Step 2: Build**
- [ ] **Step 3: Commit**

```
git add rtermd/SessionManager.swift
git commit -m "feat(rtermd): add SessionManager actor — session registry, child reaping, lifecycle"
```

---

### Task 9: DaemonPeerHandler + Daemon main.swift ⚠️ REWORK — actor with custom executor, see Architecture Revision

**Files:**
- Create: `rtermd/DaemonPeerHandler.swift`
- Modify: `rtermd/main.swift`

- [ ] **Step 1: Implement DaemonPeerHandler**

Conforms directly to `XPCPeerHandler` with typed `Input = DaemonRequest`. XPCOverlay's accept overload supports `Input: Decodable` — it handles the XPC message decoding for us. This also handles cancellation (client disconnect) in one type.

```swift
// rtermd/DaemonPeerHandler.swift
import Foundation
import TermCore
import XPCOverlay
import os

final class DaemonPeerHandler: XPCPeerHandler {
    typealias Input = DaemonRequest
    typealias Output = any Encodable

    private let session: XPCSession
    private let manager: SessionManager
    private let log = Logger(subsystem: "rtermd", category: "DaemonPeerHandler")

    init(session: XPCSession, manager: SessionManager) {
        self.session = session
        self.manager = manager
    }

    func handleIncomingRequest(_ request: DaemonRequest) -> (any Encodable)? {
        switch request {
        // Request-reply: client expects a response
        case .listSessions:
            return blockingAwait { await self.manager.listSessions() }
                .map { DaemonResponse.sessions($0) }

        case .createSession(let shell, let rows, let cols):
            return blockingAwait {
                try await self.manager.createSession(shell: shell, rows: rows, cols: cols)
            }.map { DaemonResponse.sessionCreated($0) }
            ?? DaemonResponse.error(.internalError("spawn failed"))

        case .attach(let sessionID):
            return blockingAwait {
                try await self.manager.attach(sessionID: sessionID, client: self.session)
            }.map { DaemonResponse.screenSnapshot(sessionID: sessionID, snapshot: $0) }
            ?? DaemonResponse.error(.sessionNotFound(sessionID))

        // Fire-and-forget: no reply expected
        case .detach(let sessionID):
            Task { await self.manager.detach(sessionID: sessionID, client: self.session) }
            return nil

        case .input(let sessionID, let data):
            Task { try? await self.manager.handleInput(sessionID: sessionID, data: data) }
            return nil

        case .resize(let sessionID, let rows, let cols):
            Task { try? await self.manager.resize(sessionID: sessionID, rows: rows, cols: cols) }
            return nil
        }
    }

    func handleCancellation(error: XPCRichError) {
        log.info("Client disconnected: \(error)")
        Task { await manager.clientDisconnected(session) }
    }

    /// Bridge sync XPC handler → async actor. Safe: XPC runs on GCD concurrent queue, not cooperative pool.
    private func blockingAwait<T>(_ work: @escaping @Sendable () async throws -> T) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: T?
        Task {
            result = try? await work()
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }
}
```

- [ ] **Step 2: Update main.swift**

```swift
// rtermd/main.swift
import Foundation
import TermCore
import XPCOverlay
import os

let log = Logger(subsystem: "rtermd", category: "main")
log.info("rtermd starting (pid=\(getpid()))")

let sessionManager = SessionManager()

let serviceName = "group.com.ronnyf.rterm.rtermd"

do {
    let listener = try XPCListener(service: serviceName) { request in
        request.accept { session in
            DaemonPeerHandler(session: session, manager: sessionManager)
        }
    }
    _ = listener  // Keep reference alive
} catch {
    log.error("Failed to create XPCListener: \(error)")
    exit(1)
}

// SIGTERM: graceful shutdown (DispatchSource is the standard macOS signal API — no alternative)
signal(SIGTERM, SIG_IGN)
let sigTermSource = DispatchSource.makeSignalSource(signal: SIGTERM)
sigTermSource.setEventHandler {
    log.info("Received SIGTERM, shutting down...")
    Task {
        await sessionManager.shutdownAll()
        try? await Task.sleep(for: .seconds(1))
        exit(0)
    }
}
sigTermSource.activate()

// SIGCHLD: reap children
signal(SIGCHLD, SIG_IGN)
let sigChldSource = DispatchSource.makeSignalSource(signal: SIGCHLD)
sigChldSource.setEventHandler {
    Task { await sessionManager.reapChildren() }
}
sigChldSource.activate()

// Exit when empty (with cancellable 5s grace period)
Task {
    await sessionManager.setOnEmpty {
        log.info("No sessions remaining, exiting in 5s...")
        Task {
            try? await Task.sleep(for: .seconds(5))
            let count = await sessionManager.sessionCount
            if count == 0 {
                log.info("Goodbye.")
                exit(0)
            } else {
                log.info("New session created during grace period, staying alive.")
            }
        }
    }
}

dispatchMain()
```

Add helpers to SessionManager:
```swift
// Add to SessionManager
func setOnEmpty(_ handler: @escaping @Sendable () -> Void) {
    onEmpty = handler
}

var sessionCount: Int { sessions.count }
```

- [ ] **Step 3: Build the daemon**

Run: `xcodebuild -project rTerm.xcodeproj -scheme rtermd build 2>&1 | tail -10`

- [ ] **Step 4: Commit**

```
git add rtermd/DaemonPeerHandler.swift rtermd/main.swift rtermd/SessionManager.swift
git commit -m "feat(rtermd): add DaemonPeerHandler and daemon entry point with signal handling"
```

---

## Phase C: Client Side

> **See "Architecture Revision" section above** for the XPC API patterns (constructor with handlers, deferred replies, `import XPC`). The code samples below predate the revision — use them for functional intent, not as literal implementation guides.

### Task 10: DaemonClient — Replacing RemotePTY ⚠️ REWORK — use constructor pattern, see Architecture Revision

**Files:**
- Create: `TermCore/DaemonClient.swift`

- [ ] **Step 1: Implement DaemonClient**

```swift
// TermCore/DaemonClient.swift
import Foundation
import XPCOverlay
import os

public final class DaemonClient: Sendable {
    public enum ConnectionError: Error {
        case notConnected
        case connectionFailed(String)
        case timeout
    }

    private let serviceName: String
    private let log = Logger(subsystem: "rTerm", category: "DaemonClient")
    private let state = OSAllocatedUnfairLock<ClientState>(initialState: .init())

    struct ClientState: Sendable {
        var xpcSession: XPCSession?
        var responseHandler: (@Sendable (DaemonResponse) -> Void)?
    }

    public init(serviceName: String = "group.com.ronnyf.rterm.rtermd") {
        self.serviceName = serviceName
    }

    /// Connect with retry (1s, 2s, 4s backoff, 10s total timeout)
    public func connect() async throws {
        let delays: [UInt64] = [1_000_000_000, 2_000_000_000, 4_000_000_000]
        var lastError: Error?

        for (i, delay) in delays.enumerated() {
            do {
                try connectOnce()
                log.info("Connected to \(self.serviceName)")
                return
            } catch {
                lastError = error
                log.warning("Connection attempt \(i + 1) failed: \(error), retrying in \(delay / 1_000_000_000)s")
                try await Task.sleep(nanoseconds: delay)
            }
        }

        // Final attempt
        do {
            try connectOnce()
        } catch {
            throw ConnectionError.timeout
        }
    }

    private func connectOnce() throws {
        let session = try XPCSession(
            machService: serviceName,
            targetQueue: .global(qos: .userInteractive)
        )

        session.setIncomingMessageHandler { [weak self] (response: DaemonResponse) -> Void in
            self?.state.withLock { $0.responseHandler?(response) }
        }

        session.setCancellationHandler { [weak self] error in
            self?.log.warning("XPC session cancelled: \(error)")
            self?.state.withLock { $0.xpcSession = nil }
        }

        state.withLock { $0.xpcSession = session }
    }

    public func setResponseHandler(_ handler: @escaping @Sendable (DaemonResponse) -> Void) {
        state.withLock { $0.responseHandler = handler }
    }

    public func send(_ request: DaemonRequest) throws {
        guard let session = state.withLock({ $0.xpcSession }) else {
            throw ConnectionError.notConnected
        }
        try session.send(request)
    }

    public func sendSync(_ request: DaemonRequest) throws -> DaemonResponse {
        guard let session = state.withLock({ $0.xpcSession }) else {
            throw ConnectionError.notConnected
        }
        return try session.sendSync(request)
    }

    public func disconnect() {
        state.withLock { state in
            state.xpcSession?.cancel(reason: "disconnect")
            state.xpcSession = nil
        }
    }

    deinit {
        state.withLock { $0.xpcSession?.cancel(reason: "deinit") }
    }
}
```

- [ ] **Step 2: Build**
- [ ] **Step 3: Commit**

```
git add TermCore/DaemonClient.swift
git commit -m "feat(TermCore): add DaemonClient — XPC client for rtermd with connection retry"
```

---

### Task 11: Update TerminalSession to Use DaemonClient ⚠️ REWORK — separate create + attach calls, see Architecture Revision

**Files:**
- Modify: `rTerm/ContentView.swift`

- [ ] **Step 1: Update TerminalSession**

Replace the existing `TerminalSession` class in `ContentView.swift`. Key changes:
- Use `DaemonClient` instead of `RemotePTY`
- Track `sessionID`
- Handle `DaemonResponse` messages
- Support reattach via `screenModel.restore(from:)`

```swift
@Observable @MainActor
class TerminalSession {
    let screenModel: ScreenModel
    private let client: DaemonClient
    private var parser = TerminalParser()
    private var outputTask: Task<Void, Never>?
    private(set) var sessionID: SessionID?
    private let log = Logger(subsystem: "rTerm", category: "TerminalSession")

    init(rows: Int = 24, cols: Int = 80) {
        screenModel = ScreenModel(cols: cols, rows: rows)
        client = DaemonClient()
    }

    func connect() async {
        do {
            try await client.connect()

            // Set up response handler
            client.setResponseHandler { [weak self] response in
                Task { @MainActor [weak self] in
                    await self?.handleResponse(response)
                }
            }

            // Create a new session
            let reply = try client.sendSync(.createSession(
                shell: .zsh,
                rows: UInt16(screenModel.rows),
                cols: UInt16(screenModel.cols)
            ))

            if case .sessionCreated(let info) = reply {
                sessionID = info.id
                log.info("Session \(info.id) created, shell pid=\(info.pid)")
            } else if case .error(let error) = reply {
                log.error("Failed to create session: \(error)")
            }
        } catch {
            log.error("Connection failed: \(error)")
        }
    }

    private func handleResponse(_ response: DaemonResponse) async {
        switch response {
        case .output(let id, let data) where id == sessionID:
            let events = parser.parse(data)
            await screenModel.apply(events)

        case .screenSnapshot(let id, let snapshot) where id == sessionID:
            await screenModel.restore(from: snapshot)

        case .sessionEnded(let id, let exitCode) where id == sessionID:
            log.info("Session \(id) ended with exit code \(exitCode)")
            sessionID = nil

        default:
            break
        }
    }

    func sendInput(_ data: Data) {
        guard let id = sessionID else { return }
        try? client.send(.input(sessionID: id, data: data))
    }

    func resize(rows: UInt16, cols: UInt16) {
        guard let id = sessionID else { return }
        try? client.send(.resize(sessionID: id, rows: rows, cols: cols))
    }

    deinit {
        outputTask?.cancel()
        if let id = sessionID {
            try? client.send(.detach(sessionID: id))
        }
    }
}
```

- [ ] **Step 2: Update ContentView if needed**

The `ContentView` should remain largely unchanged — it creates `TerminalSession` and calls `session.connect()` via `.task`. The `onInput` closure now calls `session.sendInput(data)`.

- [ ] **Step 3: Build the app**

Run: `xcodebuild -project rTerm.xcodeproj -scheme rTerm build 2>&1 | tail -20`

- [ ] **Step 4: Commit**

```
git add rTerm/ContentView.swift
git commit -m "feat(rTerm): update TerminalSession to use DaemonClient for rtermd communication"
```

---

### Task 12: App Entitlements Update ✅ COMPLETE

**Files:**
- Modify: `rTerm/rTerm.entitlements`

- [ ] **Step 1: Add app-group entitlement**

Add to `rTerm/rTerm.entitlements`:
```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.com.ronnyf.rterm</string>
</array>
```

- [ ] **Step 2: Commit**

```
git add rTerm/rTerm.entitlements
git commit -m "feat(rTerm): add app-group entitlement for rtermd Mach service"
```

---

## Phase D: Integration & Cleanup

### Task 13: Remove Old XPC Targets

After the new architecture is working end-to-end:

- [ ] **Step 1: Remove rTermSupport target from Xcode project**
- [ ] **Step 2: Remove rTermLauncher target from Xcode project**
- [ ] **Step 3: Keep the source files for reference but remove from build**
- [ ] **Step 4: Remove RemotePTY import/usage from the app**
- [ ] **Step 5: Commit**

```
git commit -m "chore: remove rTermSupport and rTermLauncher targets (replaced by rtermd)"
```

---

### Task 14: End-to-End Integration Test

- [ ] **Step 1: Build both targets**

```bash
xcodebuild -project rTerm.xcodeproj -scheme rtermd -configuration Debug build
xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build
```

- [ ] **Step 2: Register the LaunchAgent**

```bash
# Copy plist (update Program path to actual build output)
cp rtermd/group.com.ronnyf.rterm.rtermd.plist ~/Library/LaunchAgents/
# Edit the Program path to point to the built binary
launchctl load ~/Library/LaunchAgents/group.com.ronnyf.rterm.rtermd.plist
```

- [ ] **Step 3: Launch the app and verify**

1. Launch rTerm.app
2. Verify shell spawns and prompt appears
3. Type commands, verify output
4. Quit the app
5. Relaunch — verify session list shows the previous session (if still running)
6. Test Ctrl+Z for job control

- [ ] **Step 4: Test detach/reattach**

1. Launch app, create session, run `echo "before detach"`
2. Quit app (Cmd+Q)
3. Verify rtermd is still running: `pgrep rtermd`
4. Relaunch app
5. Verify session is available and screen shows previous content

- [ ] **Step 5: Test crash recovery**

```bash
kill -9 $(pgrep rtermd)
sleep 2
pgrep rtermd  # Should show new PID (launchd restarted it)
```

---

## Verification Summary

| Test | Command | Expected |
|------|---------|----------|
| Protocol Codable | `xcodebuild test -only-testing TermCoreTests/DaemonProtocolTests` | All pass |
| Cell/Shell Codable | `xcodebuild test -only-testing TermCoreTests/CodableTests` | All pass |
| ScreenModel restore | `xcodebuild test -only-testing TermCoreTests/ScreenModelTests` | All pass |
| Daemon builds | `xcodebuild -scheme rtermd build` | Build succeeded |
| App builds | `xcodebuild -scheme rTerm build` | Build succeeded |
| E2E: shell I/O | Launch app with registered daemon | Shell prompt, commands work |
| E2E: detach/reattach | Quit app, relaunch, reattach | Screen state preserved |
| E2E: job control | Ctrl+Z in running command | Process suspends, `fg` resumes |
| E2E: daemon crash | `kill -9 rtermd`, wait | launchd restarts daemon |
