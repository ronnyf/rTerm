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
- Modify: `rtermd/Session.swift`

**Behavioral description:**

Session is a class that represents a single terminal session in the daemon. It owns a spawned shell process, the PTY file descriptor, a TerminalParser, a ScreenModel, and the list of attached XPC clients. Each Session is created by SessionManager and stored in its dictionary.

**Why a class (not a struct, not an actor, not ~Copyable):**

Session needs reference semantics — SessionManager holds it in a Dictionary and passes references to DaemonPeerHandler. It needs `deinit` for deterministic resource cleanup (close FD, kill process). We explored `~Copyable` structs for unique ownership enforcement, but `Dictionary` requires `Copyable` values in Swift 6.4. An actor is unnecessary because the daemon queue already serializes all access.

**Initialization:**

`init(id:shell:rows:cols:)` calls `ShellSpawner.spawn()` to create the PTY and shell process. Wraps the primary FD in a `FileHandle`. Stores immutable identity (id, shell, tty, pid, createdAt) and creates a `TerminalParser` and `ScreenModel`.

**PTY output — the critical data path:**

The FileHandle readability handler is installed targeting the **daemon queue** (not Foundation's default queue). This is the key single-queue design decision: when PTY output arrives, the handler runs synchronously on the daemon queue — the same queue as all other daemon state access. No AsyncStream, no Task, no cross-queue synchronization needed.

The readability handler does three things synchronously:
1. Parse raw bytes through `TerminalParser` → `[TerminalEvent]`
2. Apply events to `ScreenModel` (the daemon maintains screen state so it can provide a snapshot when a client reattaches)
3. Encode `DaemonResponse.output(sessionID:data:)` and send to each attached client via `XPCSession.send()`

On EOF (empty data from `availableData`), nil the handler and notify SessionManager that the session ended.

**Client management:**

Clients (XPCSession references) are tracked in a plain array. No lock needed — all access is on the daemon queue.

`attach(client:)` — adds the client to the array FIRST, then takes a `ScreenSnapshot` from `ScreenModel` and returns it. The ordering matters: if the client is added first, any output that arrives between the add and the snapshot will be both fanned out to the client AND captured in the snapshot. The client may receive some data twice (once via fan-out, once in the snapshot), but `restore(from:)` on the client side overwrites with the authoritative snapshot. If we took the snapshot first and then added the client, output arriving in the gap would be lost.

`detach(client:)` — removes by identity (`===`).

`hasClients` — simple emptiness check on the array.

**PTY write:**

`write(_ data: Data)` performs a full-write loop using `Darwin.write` with EINTR retry and partial-write handling. Same pattern as `PseudoTerminal.write()` in TermCore.

**Resize:**

`resize(rows:cols:)` sends `TIOCSWINSZ` via `ioctl` to the PTY. Updates stored rows/cols so `info` reports correct dimensions.

**Exit handling:**

`markExited(exitCode:)` records the exit status. `notifyClientsEnded(exitCode:)` sends `.sessionEnded` to all clients and clears the client list. These are called by SessionManager when `waitpid` reaps the child.

**Teardown:**

`stop()` — nil the readability handler, send SIGTERM (gives shell a chance to save history/run traps), then close the FD. Guard against double-stop with a flag.

`deinit` — safety net that performs the same cleanup if `stop()` wasn't called. Check the flag to avoid double-close/double-kill.

**Style notes:**
- Use a **static logger** (`private static let log`) — subsystem/category are identical across all sessions, no reason to allocate per instance.
- If mutable state needs protection beyond queue serialization, name the lock `state` not `lock` — describe the contents, not the mechanism.
- `info` computed property returns a `SessionInfo` snapshot with current dimensions, client count, etc.

- [ ] **Step 1: Rewrite Session per architecture revision**
- [ ] **Step 2: Build**
- [ ] **Step 3: Commit**

---

### Task 8: SessionManager ⚠️ REWORK — becomes plain class, see Architecture Revision

**Files:**
- Modify: `rtermd/SessionManager.swift`

**Behavioral description:**

SessionManager is the central registry for all terminal sessions in the daemon. It's a **plain class** — not an actor. The daemon queue serializes all access, so no locks, no `@unchecked Sendable`, no async/await are needed. Every method is synchronous.

**Why not an actor?**

The original implementation used `SessionManager` as a Swift actor, which required a semaphore-based GCD-to-async bridge in `DaemonPeerHandler`. This was the root cause of the deadlock: blocking a GCD thread with a semaphore while a Task on the cooperative pool tried to send on the same blocked queue. By making SessionManager a plain class on the daemon queue, all calls from DaemonPeerHandler are direct synchronous method calls — no bridging, no hopping, no deadlock risk.

**State:**

- `[SessionID: Session]` dictionary — the session registry
- `nextID: SessionID` — monotonic counter, starts at 0
- `onEmpty: (() -> Void)?` — callback fired when the last session is removed

**Session lifecycle methods:**

`createSession(shell:rows:cols:)` — allocates the next ID, creates a `Session` (which spawns the shell via `ShellSpawner`), stores it in the dictionary, starts the output consumer (installs the FileHandle readability handler), and returns `SessionInfo`. Wraps `SpawnError` into `DaemonError.spawnFailed`.

`destroySession(sessionID:)` — looks up the session, calls `stop()` on it (SIGTERM + close FD), removes from dictionary, checks empty. Throws `.sessionNotFound` for unknown IDs.

**Client routing methods:**

These are thin wrappers that look up the session by ID and delegate to the corresponding `Session` method. All throw `.sessionNotFound` for unknown IDs.

- `attach(sessionID:client:)` → `session.attach(client:)` → returns `ScreenSnapshot`
- `detach(sessionID:client:)` → `session.detach(client:)`
- `handleInput(sessionID:data:)` → `session.write(data)`
- `resize(sessionID:rows:cols:)` → `session.resize(rows:cols:)`
- `listSessions()` → `sessions.values.map(\.info)`

**Child reaping:**

`reapChildren()` — called from the SIGCHLD signal handler (which runs on the daemon queue via DispatchSource). Loops `waitpid(-1, &status, WNOHANG)` to collect all exited children in one pass. Extracts exit code using inline bit arithmetic (`(status & 0x7F) == 0` for WIFEXITED, `(status >> 8) & 0xFF` for WEXITSTATUS — Swift cannot use C function-like macros). For each reaped PID, finds the matching session, calls `markExited` + `notifyClientsEnded`, removes the session from the dictionary, and calls `checkEmpty`. Logs a warning for unknown PIDs (shouldn't happen but defensive).

**Client disconnect:**

`clientDisconnected(client:)` — called when an XPC connection drops (app quit, crash). Iterates all sessions and calls `detach(client:)` on each. The session continues running — disconnect doesn't terminate it.

**Shutdown:**

`shutdownAll()` — stops every session (SIGTERM + close), clears the dictionary. Called from SIGTERM handler.

**Empty check:**

`checkEmpty()` — private method called after any session removal. If the dictionary is empty, fires the `onEmpty` callback. The callback (set by main.swift) starts a 5-second grace period before exiting.

- [ ] **Step 1: Rewrite SessionManager as plain class**
- [ ] **Step 2: Build**
- [ ] **Step 3: Commit**
- `clientDisconnected(client:)` — detach from all sessions
- `shutdownAll()` — stop all, clear dictionary

All methods throw `DaemonError.sessionNotFound` for unknown IDs.

- [ ] **Step 1: Rewrite SessionManager as plain class**
- [ ] **Step 2: Build**
- [ ] **Step 3: Commit**

---

### Task 9: DaemonPeerHandler + Daemon main.swift ⚠️ REWORK — actor with custom executor, see Architecture Revision

**Files:**
- Modify: `rtermd/DaemonPeerHandler.swift`
- Modify: `rtermd/main.swift`

**Behavioral description:**

**main.swift — the daemon entry point:**

Creates a serial `DispatchQueue` — the "daemon queue." This single queue is the backbone of the entire daemon's concurrency model. Every piece of mutable state in the daemon is accessed exclusively from this queue, eliminating the need for locks, actors, or async/await bridging.

Creates `SessionManager` (a plain class). Creates `XPCListener` with the daemon queue as `targetQueue` and service name `"com.ronnyf.rterm.rtermd"`. The `targetQueue` parameter is critical — it means ALL XPC callbacks (incoming messages, session accept, cancellation) arrive on the daemon queue. In the accept closure, creates a `DaemonPeerHandler` per client connection, passing it the XPC session, the session manager, and the daemon queue.

Signal handling: uses `DispatchSource.makeSignalSource` for both SIGTERM and SIGCHLD, targeting the daemon queue. This ensures signal handler callbacks also run on the daemon queue — no separate synchronization needed.

- SIGTERM: call `sessionManager.shutdownAll()`, then exit after a brief delay
- SIGCHLD: call `sessionManager.reapChildren()` to collect zombie processes

Exit-when-empty: register an `onEmpty` callback on SessionManager that fires when the last session is removed. The callback starts a cancellable 5-second grace period — if no new session is created within 5 seconds, the daemon exits. This prevents the daemon from running indefinitely when the user has closed all terminals. Use a `DispatchWorkItem` scheduled on the daemon queue for the timer (not `Task.sleep` — we're avoiding the cooperative pool).

Calls `dispatchMain()` as the run loop.

**DaemonPeerHandler — the core design insight:**

DaemonPeerHandler is an **actor with a custom `SerialExecutor`** backed by the daemon queue. This is the key architectural decision that eliminates all GCD-to-async bridging.

**Why an actor with custom executor?**

The XPC framework delivers `handleIncomingRequest` callbacks on a GCD dispatch queue. Swift actors normally run on the cooperative thread pool. Bridging between these two worlds is where the original semaphore anti-pattern came from — blocking a cooperative thread with a semaphore to wait for an actor.

By giving the actor a custom executor backed by the daemon queue, we make the actor's isolation context the SAME as the XPC callback context. When XPC calls `handleIncomingRequest`, we're already on the actor's queue. No hop, no bridge, no semaphore. The actor can use `assumeIsolated` to enter its isolation context synchronously from the XPC callback.

**Why not just a plain class?**

A plain class conforming to `XPCPeerHandler` would work functionally — all access is on the same queue. But Swift's type system doesn't know that. The actor + custom executor makes the single-queue isolation visible to the compiler, enabling proper Sendable checking and preventing accidental off-queue access.

**XPCPeerHandler conformance:**

Conforms to `XPCPeerHandler`. The `handleIncomingRequest` method receives `XPCReceivedMessage`, decodes `DaemonRequest`, and routes to SessionManager.

For **request-reply** operations (listSessions, createSession, attach):
- Do the work immediately — SessionManager methods are synchronous, we're on the same queue
- Call `message.reply(response)` to send the deferred reply
- Return `nil` from the handler (tells XPC runtime the reply will come later via `reply()`)
- The client's `sendSync` blocks until `reply()` is called — this is documented XPC behavior

For **fire-and-forget** operations (detach, input, resize, destroySession):
- Do the work directly — already on the right queue
- Return `nil` (no reply expected)

**Why deferred reply instead of returning the response directly?**

The `handleIncomingRequest` protocol method returns `(any Encodable)?`. We COULD return the response directly for request-reply operations since SessionManager is synchronous. However, using `message.reply()` gives us flexibility to handle errors uniformly and keeps the pattern consistent. If we later need async work (e.g., awaiting a ScreenModel actor for snapshots), the deferred reply pattern already supports it without changing the handler structure.

`handleCancellation`: called when the XPC connection drops (client quit, crash). Calls `sessionManager.clientDisconnected(session)` to detach the client from all sessions. Runs on the daemon queue (same as everything else).

**No semaphores. No Task bridging. No blocking. No cooperative pool involvement.**

- [ ] **Step 1: Rewrite DaemonPeerHandler as actor with custom executor**
- [ ] **Step 2: Rewrite main.swift with daemon queue**
- [ ] **Step 3: Build**
- [ ] **Step 4: Commit**
git commit -m "feat(rtermd): add DaemonPeerHandler and daemon entry point with signal handling"
```

---

## Phase C: Client Side

### Task 10: DaemonClient — Replacing RemotePTY ⚠️ REWORK — use constructor pattern, see Architecture Revision

**Files:**
- Create: `TermCore/DaemonClient.swift`

**Behavioral description:**

DaemonClient is a `Sendable` class in TermCore that manages a single XPC connection to the rtermd daemon's Mach service (`"com.ronnyf.rterm.rtermd"`). It replaces the old `RemotePTY` class which used the XPC Application Service model.

**Sendability and thread safety:**

Mutable state (xpcSession, responseHandler) is protected by `OSAllocatedUnfairLock`. This is necessary because `setResponseHandler` is called from the main thread, while the incoming message handler runs on the XPC dispatch queue. The response handler must be fetched from the lock and called OUTSIDE the lock — calling user code while holding a lock risks deadlock if the user code tries to call back into the client.

**XPC session lifecycle — this is critical, we burned hours on this:**

Use the `XPCSession(machService:targetQueue:options:incomingMessageHandler:cancellationHandler:)` constructor. This constructor accepts handlers at creation time and auto-activates the session. The session is immediately ready to send/receive after construction.

**NEVER call `setIncomingMessageHandler` on an already-active session.** The XPC runtime crashes with "XPC API Misuse: Session must be inactive to set the message handler, not Active". If you need to set handlers after construction, you must create the session with `options: .inactive`, set handlers, then call `activate()`. But the constructor pattern avoids this entirely — prefer it.

`targetQueue: nil` uses the system default queue. Do not pass an explicit GCD queue unless there's a reason to control which queue the incoming message handler runs on.

**Connection retry:**

`connect()` is async. It attempts `connectOnce()` up to 4 times with exponential backoff (1s, 2s, 4s delays between the first three failures). The final attempt propagates the error as `.timeout`. This covers the case where the daemon hasn't started yet when the app launches — launchd starts it on demand when the Mach service is first looked up, but there may be a brief delay.

**Incoming message handler:**

The daemon pushes unsolicited messages to the client (`.output` with PTY data, `.sessionEnded` when a shell exits). The incoming message handler receives these as `DaemonResponse` values and forwards them to whatever response handler the client has registered. The handler closure captures the lock (not `self`) so it can read the current response handler. It returns `nil` (no reply to push messages).

**Public API:**
- `connect() async throws` — with retry
- `setResponseHandler(_:)` — register push message handler (can be changed at any time)
- `send(_: DaemonRequest) throws` — fire-and-forget (keyboard input, resize, detach)
- `sendSync(_: DaemonRequest) throws -> DaemonResponse` — request-reply (createSession, attach, listSessions)
- `disconnect()` — cancel session
- `isConnected: Bool`

`deinit` cancels any active session.

- [ ] **Step 1: Implement DaemonClient**
- [ ] **Step 2: Add to TermCore target in project.pbxproj**
- [ ] **Step 3: Build**
- [ ] **Step 4: Commit**

---

### Task 11: Update TerminalSession to Use DaemonClient ⚠️ REWORK — separate create + attach calls, see Architecture Revision

**Files:**
- Modify: `rTerm/ContentView.swift`

**Behavioral description:**

TerminalSession is an `@Observable @MainActor` class that manages the connection between the app UI and the daemon. It replaces the old RemotePTY-based flow with DaemonClient.

**Connection flow — two separate XPC calls, not one:**

The client must send `.createSession` and `.attach` as TWO separate `sendSync` calls. The original implementation tried to do both in a single `blockingAwaitResult` closure on the daemon side, which deadlocked because the semaphore blocked the XPC queue while the Task tried to send on the same queue.

1. `Agent().register()` — registers the LaunchAgent (no-op in Debug builds, SMAppService in Release)
2. `client.connect()` — async with retry, establishes XPC session
3. Install response handler via `client.setResponseHandler`
4. `client.sendSync(.createSession(shell:rows:cols:))` — creates the shell session, returns `SessionInfo`
5. `client.sendSync(.attach(sessionID:))` — attaches to receive output, returns `ScreenSnapshot`
6. `screenModel.restore(from: snapshot)` — renders the initial shell prompt

The attach snapshot is essential: between `createSession` and `attach`, the shell may have already produced output (its prompt). That output went to the daemon's ScreenModel but wasn't fanned out to any client (no client was attached yet). The snapshot captures whatever the daemon has, so the client doesn't start with a blank screen.

**Response handler threading:**

The response handler closure runs on the XPC dispatch queue, not MainActor. Any work that touches the ScreenModel or other UI state must be dispatched to MainActor. The TerminalParser is a mutating struct — protect it with an `OSAllocatedUnfairLock` for Sendable capture, or dispatch all parsing to MainActor.

Response cases:
- `.output(sessionID, data)` — parse through TerminalParser → `[TerminalEvent]` → `screenModel.apply(events)` on MainActor
- `.screenSnapshot(sessionID, snapshot)` — `screenModel.restore(from:)` on MainActor
- `.sessionEnded(sessionID, exitCode)` — log, clear sessionID
- `.error(daemonError)` — log

**Input/resize:**

`sendInput(_:)` sends `.input(sessionID:data:)` via fire-and-forget `client.send()`.
`resize(rows:cols:)` sends `.resize(sessionID:rows:cols:)` via fire-and-forget.

**No deinit detach** — the daemon handles client disconnect via the XPC cancellation handler (`DaemonPeerHandler.handleCancellation` calls `sessionManager.clientDisconnected`). When the app quits or the XPC connection drops, the daemon automatically detaches the client from all sessions. The session continues running for potential reattach.

ContentView stays unchanged — creates TerminalSession, calls connect in `.task`, passes input via `sendInput`.

- [ ] **Step 1: Update TerminalSession**
- [ ] **Step 2: Build**
- [ ] **Step 3: Commit**

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
