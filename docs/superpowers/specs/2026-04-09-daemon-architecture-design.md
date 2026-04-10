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
├── DaemonClient — XPCSession(machService: "com.ronnyf.rtermd")
├── TerminalParser (local copy for real-time rendering)
├── ScreenModel (local copy for rendering)
└── TermView / Metal renderer

rtermd (LaunchAgent daemon)
├── XPCListener(machService: "com.ronnyf.rtermd")
├── SessionManager
│   ├── Session 0: forkpty'd shell + TerminalParser + ScreenModel
│   ├── Session 1: forkpty'd shell + TerminalParser + ScreenModel
│   └── ...
└── Lifecycle: exits when last session ends; launchd restarts on crash
```

### Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| IPC transport | XPC via Mach service | Reuses existing XPC infrastructure; free IPC, serialization, credential handling |
| Daemon lifecycle | LaunchAgent, on-demand start, self-managed exit | launchd starts on first connection; daemon exits when last session ends; `KeepAlive.SuccessfulExit=false` for crash recovery |
| Shell spawning | `forkpty()` called directly from Swift via Darwin module | Handles setsid + controlling terminal + FD setup automatically. No C/ObjC helper needed. |
| Session model | Multiple sessions per daemon, one client per session (initially) | B-ready: data structures support multiple clients per session for future shared view |
| Screen state on reattach | Send current ScreenSnapshot | Daemon maintains authoritative ScreenModel. Scrollback deferred to persistence layer (future). |
| Persistence | Planned but not built. In-memory for v1. | SessionStore protocol defined as extension point. File-based or KV store (RocksDB) can be added later. |
| Protocol-agnostic | Message types are Codable, transport is XPC | TCP/WebSocket listener can be added alongside XPC for iOS connectivity (future) |
| forkpty interop | Pure Swift (Darwin module) | No ObjC/C helper. Swift can safely call tcsetpgrp + execve between fork and exec for this narrow use case. |

---

## Section 1: Daemon Binary (`rtermd`)

### LaunchAgent Registration

```xml
<!-- ~/Library/LaunchAgents/com.ronnyf.rtermd.plist -->
<dict>
    <key>Label</key>
    <string>com.ronnyf.rtermd</string>
    <key>Program</key>
    <string>/path/to/rtermd</string>
    <key>MachServices</key>
    <dict>
        <key>com.ronnyf.rtermd</key>
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

### Daemon Startup

```swift
// rtermd/main.swift
let sessionManager = SessionManager()
let listener = try XPCListener(machService: "com.ronnyf.rtermd") { request in
    request.accept { session in
        DaemonSessionHandler(session: session, manager: sessionManager)
    }
}
sessionManager.onEmpty = { exit(0) }  // Clean exit when last session ends
dispatchMain()
```

### Shell Spawning via `forkpty()` (Pure Swift)

```swift
import Darwin

func spawnShell(shell: Shell, rows: UInt16, cols: UInt16) throws -> (pid: pid_t, primaryFD: Int32) {
    var primaryFD: Int32 = 0
    var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
    let pid = forkpty(&primaryFD, nil, nil, &ws)

    if pid == 0 {
        // Child: forkpty already did setsid + controlling terminal + dup2
        tcsetpgrp(STDIN_FILENO, getpid())
        // Set up environment
        setenv("TERM", "xterm-256color", 1)
        setenv("SHELL", shell.path, 1)
        // execve the shell
        execve(shell.path, argv, envp)
        _exit(127)
    } else if pid < 0 {
        throw POSIXError(.EFAULT)
    }

    return (pid, primaryFD)
}
```

**Why forkpty over current posix_openpt + Process:**
- `setsid()` happens automatically — new session, proper isolation
- Controlling terminal set up correctly — `TIOCSCTTY` done automatically
- No race condition with `tcsetpgrp()` from parent
- Full job control works: Ctrl+Z, bg, fg, process groups

### Session Identity

Auto-incrementing integer IDs: `0`, `1`, `2` (like tmux's `%0`, `%1`). `SessionManager` maps ID to session state.

---

## Section 2: Message Protocol

### Message Types

```swift
// TermCore/DaemonProtocol.swift

typealias SessionID = Int

enum DaemonRequest: Codable {
    // Session management
    case listSessions
    case createSession(shell: Shell, rows: UInt16, cols: UInt16)
    case attach(sessionID: SessionID)
    case detach(sessionID: SessionID)

    // Session I/O
    case input(sessionID: SessionID, data: Data)
    case resize(sessionID: SessionID, rows: UInt16, cols: UInt16)
}

enum DaemonResponse: Codable {
    // Session management
    case sessions([SessionInfo])
    case sessionCreated(SessionInfo)
    case screenSnapshot(sessionID: SessionID, snapshot: ScreenSnapshot)
    case sessionEnded(sessionID: SessionID, exitCode: Int32)

    // Session I/O
    case output(sessionID: SessionID, data: Data)

    // Errors
    case error(String)
}

struct SessionInfo: Codable {
    let id: SessionID
    let shell: Shell
    let tty: String
    let pid: pid_t
    let createdAt: Date
    let title: String?
    let rows: UInt16
    let cols: UInt16
    let hasClient: Bool  // B-ready: tracks attached clients
}
```

### Message Flow

- **Create:** Client sends `.createSession` → daemon does `forkpty()` → replies `.sessionCreated`
- **Attach (reattach):** Client sends `.attach(id)` → daemon replies `.screenSnapshot` from its ScreenModel → then streams `.output` for new data
- **I/O:** Client sends `.input(id, data)` → daemon writes to PTY. Daemon streams `.output(id, data)` as shell produces output.
- **Detach:** Client sends `.detach(id)` or XPC peer disconnect → daemon removes client from session, shell keeps running.
- **Shell exits:** Daemon detects EOF on PTY → sends `.sessionEnded` to attached clients.

---

## Section 3: Session Manager (Daemon-side)

### Session Lifecycle

```
[*] → Created (forkpty succeeds)
Created → Running (client attached)
Running → Running (clients attach/detach)
Running → Detached (last client disconnects)
Detached → Running (client reattaches)
Running → Ended (shell exits)
Detached → Ended (shell exits)
Ended → [*] (cleanup, if last session → daemon exits)
```

### Output Flow

1. PTY primary FD → `DispatchSource.makeReadSource()` on background queue
2. Raw bytes → daemon's `TerminalParser` → `ScreenModel.apply(events)` (keeps screen current)
3. Raw bytes → fan-out to all attached clients via `.output(id, data)`
4. On attach: send `ScreenModel`'s current snapshot

Daemon's `ScreenModel` is the source of truth. Clients maintain their own local `ScreenModel` from the raw byte stream for rendering. On reattach, the snapshot resets the client's state.

### B-Ready Design

`attachedClients: [XPCSession]` per session — fan-out already supports multiple clients. Future shared-session work would add input arbitration and resize negotiation. Not built now.

### Persistence (Future Extension Point)

```swift
protocol SessionStore {
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
| `RemotePTY` | `DaemonClient` | `XPCSession(machService:)` instead of `XPCSession(xpcService:)`. Speaks `DaemonRequest`/`DaemonResponse`. |
| `TerminalSession` | `TerminalSession` (updated) | Session-aware: tracks `sessionID`, supports `reattach(to:)`, handles `.screenSnapshot` for reattach |
| `RemoteCommand`/`RemoteResponse` | `DaemonRequest`/`DaemonResponse` | Session-aware protocol with session management messages |

### What Stays The Same

- `TermView` / Metal renderer (renders `ScreenSnapshot`)
- `KeyEncoder` (converts NSEvent to bytes)
- `ScreenModel` (client keeps local copy for rendering)
- `TerminalParser` (client parses raw bytes locally)
- `GlyphAtlas` / `Shaders.metal`

### v1 App Behavior

On launch: auto-create a new session (same as today). Session picker / reattach UI is a future enhancement.

---

## Section 5: Migration — Keep, Move, Drop

### Keep in TermCore (shared framework)

- `TerminalParser`, `ScreenModel`, `Cell`, `Cursor`, `ScreenSnapshot`
- `Shell` enum
- `CircularCollection`, `ScreenBuffer`, `RingBuffer`
- `DaemonRequest`/`DaemonResponse`, `SessionInfo` (new, replaces `RemoteCommand`/`RemoteResponse`)
- `XPCOverlay` dependency (still using XPC)

### Replace

- `RemotePTY` → `DaemonClient` (new)
- `SessionHandler` → `DaemonSessionHandler` (new)
- `PTYResponder` → `SessionManager` (new)
- `PseudoTerminal` → `Session` class in daemon (owns forkpty + parser + screen)
- `AltPTY` → replaced by `forkpty()` (forkpty handles everything AltPTY + PseudoTerminal did)

### Drop

- `RemoteCommand` / `RemoteResponse` (replaced by `DaemonRequest`/`DaemonResponse`)
- `rTermSupport` XPC service target (replaced by rtermd)
- `rTermLauncher` target (diverged, superseded)

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
6. **Shell exit:** Exit shell → verify `.sessionEnded` received → verify daemon exits if last session

### Unit Tests

- `DaemonRequest`/`DaemonResponse` Codable round-trip
- `SessionManager` create/attach/detach/remove lifecycle
- `SessionInfo` serialization
- forkpty wrapper (integration test: spawn shell, write, read output)

---

## Scope Summary

**v1 builds:**
- `rtermd` daemon binary with LaunchAgent registration
- `SessionManager` with create/attach/detach/list
- `forkpty()` shell spawning (pure Swift)
- `DaemonRequest`/`DaemonResponse` protocol in TermCore
- `DaemonClient` replacing `RemotePTY` in the app
- Drop `rTermSupport` XPC service and `rTermLauncher`

**Deferred:**
- Persistence layer (SessionStore protocol defined, not implemented)
- Scrollback via persistent store
- Session restoration after daemon crash
- Shared session view (multiple clients on one session)
- Session picker / reattach UI in the app
- TCP/WebSocket listener for iOS connectivity
