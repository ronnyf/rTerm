# rTerm Daemon Architecture: XPC LaunchAgent with Detach/Reattach

## Context

rTerm currently uses an XPC Application Service (`rTermSupport`) to host shell processes. This architecture has fundamental limitations:

- **XPC Application Services are launchd-managed** — they auto-terminate ~30s after the last client disconnects. The shell dies with them.
- **No session persistence** — no session IDs, no reconnection, no state tracking. App quit = everything lost.
- **Limited job control** — `setsid()` works in the service but child shells spawned via `posix_spawn` don't get proper session/controlling-terminal setup. `tcsetpgrp()` workaround is fragile.
- **Single session per connection** — no multiplexing, no session management.

The goal is a tmux-like architecture where shell sessions outlive the UI app, supporting both crash recovery and intentional detach/reattach.

## Architecture: XPC LaunchAgent Daemon (`rtermd`)

### Overview

Replace the XPC Application Service with a standalone LaunchAgent daemon that uses Mach service-based XPC for IPC. The daemon owns shell processes via `forkpty()`, manages sessions by ID, and survives app restarts.

```
rTerm.app (UI client)
├── DaemonClient — XPCSession(machService: "group.com.ronnyf.rterm.rtermd")
├── TerminalParser (local copy for real-time rendering)
├── ScreenModel (local copy for rendering)
└── TermView / Metal renderer

rtermd (LaunchAgent daemon)
├── XPCListener(service: "group.com.ronnyf.rterm.rtermd")
├── SessionManager (actor)
│   ├── Session 0: forkpty'd shell + TerminalParser + ScreenModel
│   ├── Session 1: forkpty'd shell + TerminalParser + ScreenModel
│   └── ...
└── Lifecycle: exits when last session ends; launchd restarts on crash
```

### Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| IPC transport | XPC via Mach service | Reuses existing XPC infrastructure; free IPC, serialization, credential handling |
| Mach service name | `group.com.ronnyf.rterm.rtermd` | App-group prefixed for future sandbox compatibility |
| Daemon lifecycle | LaunchAgent, on-demand start, self-managed exit | launchd starts on first connection; daemon exits when last session ends; `KeepAlive.SuccessfulExit=false` for crash recovery |
| Shell spawning | `forkpty()` called directly from Swift via Darwin module | Handles setsid + controlling terminal + FD setup automatically. No C/ObjC helper needed. |
| Session model | Multiple sessions per daemon; `[XPCSession]` array per session | v1 enforces max 1 client at protocol level, but uses array internally for B-ready shared session support |
| Screen state on reattach | Send current ScreenSnapshot | Daemon maintains authoritative ScreenModel. Scrollback deferred to persistence layer (future). |
| Persistence | Planned but not built. In-memory for v1. | SessionStore protocol defined as extension point. File-based or KV store (RocksDB) can be added later. |
| Protocol-agnostic | Message types are Codable, transport is XPC | TCP/WebSocket listener can be added alongside XPC for iOS connectivity (future) |
| forkpty interop | Pure Swift (Darwin module) | No ObjC/C helper. Environment and argv constructed before fork; only async-signal-safe calls in child. |
| SessionManager | Actor | Multiple XPC sessions call into it concurrently; actor isolation prevents data races |
| Daemon setsid | Daemon does NOT call `setsid()` | Each child shell gets its own session via `forkpty()`. Daemon as session leader would interfere. |
| Orphan processes | Ignored in v1 | Shells receive SIGHUP when daemon dies (PTY primary closes). Shells that trap HUP are an edge case. |

---

## Section 1: Daemon Binary (`rtermd`)

### LaunchAgent Registration

```xml
<!-- ~/Library/LaunchAgents/group.com.ronnyf.rterm.rtermd.plist -->
<dict>
    <key>Label</key>
    <string>group.com.ronnyf.rterm.rtermd</string>
    <key>Program</key>
    <string>/path/to/rtermd</string>
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
```

- `MachServices`: launchd holds the Mach port. First client connection starts the daemon.
- `KeepAlive.SuccessfulExit = false`: launchd restarts on crash (non-zero exit), leaves dead on clean exit (last session ended, exit 0).

Both the app and daemon require the `com.apple.security.application-groups` entitlement with group `group.com.ronnyf.rterm` for future sandbox compatibility.

### Daemon Startup

```swift
// rtermd/main.swift
let sessionManager = SessionManager()
let listener = try XPCListener(
    service: "group.com.ronnyf.rterm.rtermd",  // XPCListener uses service:, not machService:
    incomingSessionHandler: { request in
        request.accept { session in
            DaemonSessionHandler(session: session, manager: sessionManager)
        }
    }
)

// Graceful shutdown on SIGTERM (launchctl unload, system shutdown)
let sigSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigSource.setEventHandler {
    Task { await sessionManager.shutdownAll() }
    // After sessions cleaned up, exit(0) via onEmpty
}
signal(SIGTERM, SIG_IGN) // Let dispatch source handle it
sigSource.activate()

// SIGCHLD for reaping child processes
let chldSource = DispatchSource.makeSignalSource(signal: SIGCHLD, queue: .main)
chldSource.setEventHandler {
    Task { await sessionManager.reapChildren() }
}
signal(SIGCHLD, SIG_IGN)
chldSource.activate()

// Exit when last session ends (with 5s grace period for reconnections)
sessionManager.onEmpty = {
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
        exit(0)
    }
}

dispatchMain()
```

**Note:** The daemon does NOT call `setsid()`. Each child shell creates its own session via `forkpty()`.

### Shell Spawning via `forkpty()` (Pure Swift)

**Environment and argv must be constructed BEFORE `forkpty()`.** Only async-signal-safe functions may be called in the child between fork and exec. `setenv()` is NOT async-signal-safe. `execve()`, `tcsetpgrp()`, `sigprocmask()`, `_exit()` are safe.

```swift
import Darwin

func spawnShell(shell: Shell, rows: UInt16, cols: UInt16) throws -> (pid: pid_t, primaryFD: Int32) {
    // Build argv and envp BEFORE fork (malloc is not async-signal-safe)
    let shellPath = strdup(shell.executable)!
    defer { free(shellPath) }  // Only frees in parent; child calls execve
    let argv: [UnsafeMutablePointer<CChar>?] = [shellPath, nil]
    let envPairs = buildEnvironment(shell: shell)  // ["TERM=xterm-256color", "HOME=...", ...]
    let envp: [UnsafeMutablePointer<CChar>?] = envPairs.map { strdup($0)! } + [nil]
    defer { envp.forEach { if let p = $0 { free(p) } } }  // Parent cleanup

    var primaryFD: Int32 = 0
    var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
    let pid = forkpty(&primaryFD, nil, nil, &ws)

    if pid == 0 {
        // === CHILD PROCESS ===
        // forkpty already did: setsid(), open PTY secondary as controlling terminal, dup2 to 0/1/2

        // Close leaked FDs from system frameworks (macOS Big Sur+)
        if let dir = opendir("/dev/fd") {
            while let entry = readdir(dir) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen)) {
                        String(cString: $0)
                    }
                }
                if let fd = Int32(name), fd > STDERR_FILENO {
                    close(fd)
                }
            }
            closedir(dir)
        }

        // Block job-control signals before tcsetpgrp (prevent SIGTTIN/SIGTTOU/SIGTSTP)
        var blockSet = sigset_t()
        var savedSet = sigset_t()
        sigemptyset(&blockSet)
        sigaddset(&blockSet, SIGTTIN)
        sigaddset(&blockSet, SIGTTOU)
        sigaddset(&blockSet, SIGTSTP)
        sigprocmask(SIG_BLOCK, &blockSet, &savedSet)
        tcsetpgrp(STDIN_FILENO, getpid())
        sigprocmask(SIG_SETMASK, &savedSet, nil)

        // exec — does not return on success
        argv.withUnsafeBufferPointer { argvBuf in
            envp.withUnsafeBufferPointer { envpBuf in
                execve(shellPath, argvBuf.baseAddress, envpBuf.baseAddress)
            }
        }
        _exit(127)  // Only reached if execve fails
    } else if pid < 0 {
        throw POSIXError(.init(rawValue: errno) ?? .EFAULT)
    }

    // === PARENT PROCESS ===
    // Set FD_CLOEXEC on primary FD so it doesn't leak to future children
    fcntl(primaryFD, F_SETFD, FD_CLOEXEC)

    return (pid, primaryFD)
}

private func buildEnvironment(shell: Shell) -> [String] {
    var env: [String] = []
    env.append("TERM=xterm-256color")
    env.append("SHELL=\(shell.executable)")
    if let home = getpwuid(getuid())?.pointee.pw_dir {
        env.append("HOME=\(String(cString: home))")
    }
    env.append("PATH=/usr/bin:/bin:/usr/local/bin:/usr/sbin:/sbin")
    if let lang = getenv("LANG") {
        env.append("LANG=\(String(cString: lang))")
    }
    return env
}
```

**Why forkpty over current posix_openpt + Process:**
- `setsid()` happens automatically — new session, proper isolation
- Controlling terminal set up correctly — `TIOCSCTTY` done automatically
- No race condition with `tcsetpgrp()` from parent
- Full job control works: Ctrl+Z, bg, fg, process groups

**Note:** The `Shell` enum needs `Codable` and `Sendable` conformance added. The `.custom` case needs a proper implementation (or removal). The `+m` flag (disables job control) must be removed from shell arguments — `forkpty()` provides proper session setup, so job control works correctly.

### Session Identity

Auto-incrementing integer IDs: `0`, `1`, `2` (like tmux's `%0`, `%1`). `SessionManager` maps ID to session state.

### Resource Limits

Default macOS soft FD limit is 256. Each session uses 1 FD (PTY primary). No artificial session cap in v1. Call `setrlimit` to raise the soft limit if needed for many sessions.

---

## Section 2: Message Protocol

### Message Types

```swift
// TermCore/DaemonProtocol.swift

public typealias SessionID = Int

public enum DaemonRequest: Codable, Sendable {
    // Session management
    case listSessions
    case createSession(shell: Shell, rows: UInt16, cols: UInt16)
    case attach(sessionID: SessionID)
    case detach(sessionID: SessionID)

    // Session I/O
    case input(sessionID: SessionID, data: Data)
    case resize(sessionID: SessionID, rows: UInt16, cols: UInt16)
}

public enum DaemonResponse: Codable, Sendable {
    // Session management
    case sessions([SessionInfo])
    case sessionCreated(SessionInfo)
    case screenSnapshot(sessionID: SessionID, snapshot: ScreenSnapshot)
    case sessionEnded(sessionID: SessionID, exitCode: Int32)

    // Session I/O
    case output(sessionID: SessionID, data: Data)

    // Errors
    case error(DaemonError)
}

public enum DaemonError: Error, Codable, Sendable {
    case sessionNotFound(SessionID)
    case spawnFailed(Int32)  // errno
    case alreadyAttached(SessionID)
    case internalError(String)
}

public struct SessionInfo: Codable, Sendable {
    public let id: SessionID
    public let shell: Shell
    public let tty: String
    public let pid: Int32  // pid_t is Int32 on Apple platforms
    public let createdAt: Date
    public let title: String?
    public let rows: UInt16
    public let cols: UInt16
    public let hasClient: Bool  // B-ready: tracks attached clients
}
```

**Codable conformance requirements:** `Shell`, `Cell`, `Cursor`, `ScreenSnapshot`, and `Character` all need `Codable` conformance added. `Character` requires custom encode/decode (store as `String`, validate single-character on decode). `ScreenSnapshot` contains `ContiguousArray<Cell>` which needs a custom Codable implementation (encode as `[Cell]`).

### Message Flow

- **Create:** Client sends `.createSession` → daemon does `forkpty()` → replies `.sessionCreated`
- **Attach (reattach):** Client sends `.attach(id)` → daemon replies `.screenSnapshot` from its ScreenModel → then streams `.output` for new data
- **I/O:** Client sends `.input(id, data)` → daemon writes to PTY. Daemon streams `.output(id, data)` as shell produces output.
- **Detach:** Client sends `.detach(id)` or XPC peer disconnect → daemon removes client from session, shell keeps running.
- **Shell exits:** Daemon detects via SIGCHLD → `waitpid()` reaps child → sends `.sessionEnded` to attached clients.

---

## Section 3: Session Manager (Daemon-side)

### Session Class

```swift
// rtermd/Session.swift

package class Session {
    let id: SessionID
    let shellPID: pid_t
    let primaryFD: Int32
    let parser: TerminalParser
    let screenModel: ScreenModel
    var attachedClients: [XPCSession]  // Array for B-ready; v1 enforces max 1
    let shell: Shell
    let tty: String
    let createdAt: Date

    // PTY read → parse → fan-out
    private var readStream: AsyncStream<Data>
    private var outputTask: Task<Void, Never>?
}
```

### SessionManager (Actor)

```swift
// rtermd/SessionManager.swift

package actor SessionManager {
    private var sessions: [SessionID: Session] = [:]
    private var nextID: SessionID = 0
    var onEmpty: (() -> Void)?

    func createSession(shell: Shell, rows: UInt16, cols: UInt16) throws -> SessionInfo { ... }
    func attach(sessionID: SessionID, client: XPCSession) throws -> ScreenSnapshot { ... }
    func detach(sessionID: SessionID, client: XPCSession) { ... }
    func handleInput(sessionID: SessionID, data: Data) throws { ... }
    func resize(sessionID: SessionID, rows: UInt16, cols: UInt16) throws { ... }
    func listSessions() -> [SessionInfo] { ... }
    func reapChildren() { ... }     // Called from SIGCHLD handler
    func shutdownAll() { ... }      // Called from SIGTERM handler
    func clientDisconnected(_ client: XPCSession) { ... }  // Called from XPC cancellation handler
}
```

### Session Lifecycle

```
[*] → Created (forkpty succeeds)
Created → Running (client attached)
Running → Running (clients attach/detach)
Running → Detached (last client disconnects)
Detached → Running (client reattaches)
Running → Ended (shell exits, detected via SIGCHLD + waitpid)
Detached → Ended (shell exits)
Ended → [*] (cleanup, if last session → 5s grace period → daemon exits)
```

### Output Flow

**Ordering invariant:** ScreenModel is updated BEFORE bytes are forwarded to clients. This ensures reattach snapshots reflect all forwarded data.

1. PTY primary FD → `AsyncStream<Data>` (backed by `read(2)` on a dedicated Task)
2. Raw bytes → daemon's `TerminalParser` → `ScreenModel.apply(events)` (sequential, same task)
3. **Then:** raw bytes → fan-out to all attached clients via `.output(id, data)`
4. On attach: send `ScreenModel`'s current snapshot (guaranteed up-to-date)

Daemon's `ScreenModel` is the source of truth. Clients maintain their own local `ScreenModel` from the raw byte stream for rendering. On reattach, the snapshot resets the client's state.

### Client Disconnect Handling

XPC cancellation handler fires when a client disconnects (crash or quit). The daemon catches the error, removes the client from `session.attachedClients`, and logs it. The shell keeps running.

### B-Ready Design

`attachedClients: [XPCSession]` per session — fan-out already supports multiple clients. v1 enforces max 1 client per session at the protocol level (`.attach` returns `.alreadyAttached` if someone is connected). Future shared-session work would add input arbitration and resize negotiation.

### Persistence (Future Extension Point)

```swift
package protocol SessionStore: Sendable {
    func appendOutput(sessionID: SessionID, data: Data) async throws
    func readOutput(sessionID: SessionID, range: Range<Int>) async throws -> Data
    func saveSession(_ info: SessionPersistenceInfo) async throws
    func loadSession(id: SessionID) async throws -> SessionPersistenceInfo?
    func removeSession(id: SessionID) async throws
    func allSessions() async throws -> [SessionPersistenceInfo]
}
```

Not implemented in v1. All state is in-memory. The protocol is defined so file-based, SQLite, or RocksDB backing stores can be added without changing the session manager.

---

## Section 4: Client-Side Changes (rTerm.app)

### What Changes

| Current | New | Change |
|---------|-----|--------|
| `RemotePTY` | `DaemonClient` | `XPCSession(machService:)` with `"group.com.ronnyf.rterm.rtermd"`. Speaks `DaemonRequest`/`DaemonResponse`. |
| `TerminalSession` | `TerminalSession` (updated) | Session-aware: tracks `sessionID`, supports `reattach(to:)`, handles `.screenSnapshot` for reattach |
| `RemoteCommand`/`RemoteResponse` | `DaemonRequest`/`DaemonResponse` | Session-aware protocol with typed errors |

### Connection Retry

If the daemon is unreachable on first connection, the client retries with exponential backoff: 1s, 2s, 4s, up to 10s total. Shows a "Connecting to rtermd..." status in the terminal view. After 10s, shows an error with instructions to register the LaunchAgent.

### What Stays The Same

- `TermView` / Metal renderer (renders `ScreenSnapshot`)
- `KeyEncoder` (converts NSEvent to bytes)
- `ScreenModel` (client keeps local copy for rendering)
- `TerminalParser` (client parses raw bytes locally)
- `GlyphAtlas` / `Shaders.metal`

### v1 App Behavior

On launch: auto-create a new session (same as today). Session picker / reattach UI is a future enhancement.

### Security

v1: no client identity validation (sandbox disabled, local only). Note: `XPCListener.IncomingSessionRequest.withUnsafeAuditToken()` (macOS 14.5+) is available for future use when sandbox is enabled.

---

## Section 5: Migration — Keep, Move, Drop

### Keep in TermCore (shared framework)

- `TerminalParser`, `ScreenModel`, `Cell`, `Cursor`, `ScreenSnapshot` (add `Codable` conformance)
- `Shell` enum (add `Codable` + `Sendable` conformance; resolve `.custom` case; remove `+m` flag)
- `CircularCollection`, `ScreenBuffer`, `RingBuffer`
- `DaemonRequest`/`DaemonResponse`/`DaemonError`/`SessionInfo` (new, replaces `RemoteCommand`/`RemoteResponse`)
- `XPCOverlay` dependency (still using XPC)

Use `package` access for framework-internal types. `public` only for the true external API surface.

### Replace

- `RemotePTY` → `DaemonClient` (new)
- `SessionHandler` → `DaemonSessionHandler` (new)
- `PTYResponder` → `SessionManager` (new, actor)
- `PseudoTerminal` → `Session` class in daemon (owns forkpty + parser + screen)
- `AltPTY` → replaced by `forkpty()` (forkpty handles everything AltPTY + PseudoTerminal did)

### Drop

- `RemoteCommand` / `RemoteResponse` (replaced by `DaemonRequest`/`DaemonResponse`)
- `rTermSupport` XPC service target (replaced by rtermd)
- `rTermLauncher` target (diverged, superseded — dropped in same PR)

### New Targets

| Target | Type | Purpose |
|--------|------|---------|
| `rtermd` | macOS command-line executable | LaunchAgent daemon binary |

---

## Verification

### End-to-End Test Plan

1. **Basic flow:** Build rtermd + rTerm.app → register LaunchAgent → launch app → verify shell spawns and I/O works
2. **Detach/reattach:** Launch app → create session → type commands → quit app → relaunch app → attach to existing session → verify screen state matches
3. **Crash recovery:** Kill rtermd with SIGKILL → verify launchd restarts it → verify sessions are lost (expected in v1, no persistence)
4. **Multiple sessions:** Create session 0 → create session 1 → verify independent I/O
5. **Job control:** Run a command, Ctrl+Z → verify it suspends → `fg` → verify it resumes (validates forkpty's proper session setup)
6. **Shell exit:** Exit shell → verify `.sessionEnded` received → verify daemon exits if last session (after 5s grace period)
7. **Client disconnect:** Force-quit app mid-session → verify daemon keeps shell alive → relaunch and reattach
8. **SIGTERM:** Send SIGTERM to daemon → verify graceful shutdown (sessions notified, children reaped)
9. **Connection retry:** Start app without daemon registered → verify retry with backoff → register daemon → verify connection succeeds

### Unit Tests (Swift Testing)

- `DaemonRequest`/`DaemonResponse`/`DaemonError` Codable round-trip
- `SessionInfo` serialization (including `Shell` Codable)
- `ScreenSnapshot` Codable round-trip (including `Cell`, `Cursor`, `Character`)
- `SessionManager` create/attach/detach/remove lifecycle (actor tests)
- `SessionManager.reapChildren()` with mock processes
- forkpty wrapper (integration test: spawn shell, write, read output, verify foreground group)

---

## Scope Summary

**v1 builds:**
- `rtermd` daemon binary with LaunchAgent registration (app-group compatible)
- `SessionManager` (actor) with create/attach/detach/list
- `forkpty()` shell spawning (pure Swift, proper signal blocking, FD hygiene, pre-fork env construction)
- `DaemonRequest`/`DaemonResponse`/`DaemonError` protocol in TermCore
- `Codable` conformance for `Shell`, `Cell`, `Cursor`, `ScreenSnapshot`
- `DaemonClient` replacing `RemotePTY` in the app (with connection retry)
- SIGCHLD handling (child reaping via `waitpid`)
- SIGTERM handling (graceful shutdown)
- Drop `rTermSupport` XPC service and `rTermLauncher`

**Deferred:**
- Persistence layer (SessionStore protocol defined, not implemented)
- Scrollback via persistent store
- Session restoration after daemon crash
- Shared session view (multiple clients on one session — data structures ready)
- Session picker / reattach UI in the app
- TCP/WebSocket listener for iOS connectivity
- Audit token validation (API available, implementation deferred)
