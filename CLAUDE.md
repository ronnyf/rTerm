# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

rTerm is a terminal emulator for macOS (with iOS/xrOS aspirations) written in Swift and SwiftUI. It uses a LaunchAgent daemon (`rtermd`) to host shell processes out-of-process, enabling tmux-style detach/reattach — sessions survive app quit/crash. Licensed under GPLv3.

## Build Commands

This is an Xcode project (`rTerm.xcodeproj`), not a Swift Package. Use `xcodebuild` from the CLI.

```bash
# Build the main app (includes TermCore, TermUI frameworks + rtermd executable)
xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build

# Build just the TermCore framework
xcodebuild -project rTerm.xcodeproj -scheme TermCore -configuration Debug build

# Run TermCore unit tests
xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test

# Run a single test (Swift Testing framework)
xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests -only-testing TermCoreTests/TermCoreTests/test_circular_collection_sequence test
```

Deployment target: macOS 15.0. Xcode 16+. Swift 5.

## Architecture

### Target Dependency Graph

```
rTerm.app (SwiftUI app)
├── TermCore.framework (core logic, no UI)
├── TermUI.framework (placeholder, currently empty)
└── rtermd (executable, embedded at Contents/MacOS/rtermd via Copy Files phase)
    └── TermCore.framework

TermCoreTests (unit tests — CircularCollection, TerminalParser, ScreenModel, PseudoTerminal, Codable, DaemonProtocol)
rTermTests (unit tests — KeyEncoder)
rTermUITests / TermUITests (UI / placeholder tests)
```

`rtermd` is a standalone Mach-O executable (not an XPC service bundle). It is registered as a LaunchAgent via one of two paths:

- **Debug:** `scripts/install-debug-daemon.sh` runs as a build phase on the `rTerm` target, writes a plist with the absolute `$BUILT_PRODUCTS_DIR/rTerm.app/Contents/MacOS/rtermd` path into `~/Library/LaunchAgents/`, and bootstraps it with `launchctl`.
- **Release:** `Agent.register()` in `TermCore/Agent.swift` (guarded by `#if !DEBUG`) calls `SMAppService.register()`, which picks up the repo plist at `rtermd/com.ronnyf.rterm.rtermd.plist` (uses bundle-relative `BundleProgram = Contents/MacOS/rtermd`).

### Daemon-Based Shell Isolation

The app does **not** run shell processes in-process. Instead:

1. **rTerm app** creates a `DaemonClient` that opens an `XPCSession` to the Mach service `com.ronnyf.rterm.rtermd` (the label constant lives in `DaemonService.machServiceName`).
2. **rtermd** receives a `DaemonRequest.createSession` on its `XPCListener`, spawns a shell via `forkpty` + `execve`, and creates a `Session` owning the PTY file descriptors, a `TerminalParser`, and a per-session `ScreenModel`.
3. On subsequent `.attach(sessionID:)`, the daemon adds the client's `XPCSession` to the session's fan-out list and returns a `ScreenSnapshot` so the client can render the current screen immediately.
4. Shell output is read on the daemon's serial queue, parsed into `TerminalEvent`s, applied to the session's `ScreenModel`, and pushed to all attached clients as `DaemonResponse.output(sessionID:data:)` (raw bytes, which the client re-parses into its local `ScreenModel` mirror).

Key types in this flow:

- `DaemonRequest` / `DaemonResponse` / `DaemonError` / `SessionInfo` — typed XPC protocol (in `TermCore/DaemonProtocol.swift`)
- `DaemonService.machServiceName` — shared Mach service name constant (in `TermCore/DaemonProtocol.swift`)
- `DaemonClient` — client-side `XPCSession` manager with auto-decoded push handler (in `TermCore/DaemonClient.swift`)
- `DaemonPeerHandler` — daemon-side actor with a custom `SerialExecutor` backed by the daemon queue; routes `DaemonRequest` to `SessionManager` synchronously (in `rtermd/DaemonPeerHandler.swift`)
- `SessionManager` — plain class (not an actor) serialized by the daemon queue; owns the session registry, handles `SIGCHLD` reaping and PTY-EOF cleanup (in `rtermd/SessionManager.swift`)
- `Session` — per-session PTY I/O, parser, `ScreenModel`, and attached-client list (in `rtermd/Session.swift`)

### PTY Layer

- `Shell.spawn(rows:cols:)` — the production PTY spawn path. Extension on `Shell` that calls `forkpty` + `execve`, builds `argv`/`envp` pre-fork to avoid Swift runtime in the child, closes FDs above stderr, and sets the child as the foreground process group of its controlling terminal (in `rtermd/ShellSpawner.swift`)
- `Shell` — enum for shell selection (bash, zsh, fish, sh) with path resolution; `Codable`, `Sendable`, `CaseIterable` (in `TermCore/Shell.swift`)
- `Agent` — `SMAppService` wrapper for launch agent management; `register()` is `#if !DEBUG` (in `TermCore/Agent.swift`)
- `AltPTY` / `PseudoTerminal` — original `posix_openpt` + `Foundation.Process` wrapper; now used only by `TermCoreTests/PseudoTerminalTests.swift` (not on the production path) (in `TermCore/PTY.swift`, `TermCore/PseudoTerminal.swift`)
- `termios` / `winsize` — `Codable`/`Equatable` conformances retained for potential future XPC serialization

### Terminal Processing Pipeline

Raw bytes from the PTY are parsed and applied to a screen model on both the daemon side (authoritative) and the client side (mirror):

1. `TerminalParser` — UTF-8 aware parser that converts raw bytes into `TerminalEvent` values. Handles multi-byte sequences and split codepoints across buffer boundaries (in `TermCore/TerminalParser.swift`).
2. `TerminalEvent` — enum representing parsed events: `.printable(Character)`, control characters, newlines, etc. (in `TermCore/TerminalEvent.swift`).
3. `ScreenModel` — actor with a custom serial-queue executor (so the daemon can enter actor context synchronously via `assumeIsolated`). Processes `TerminalEvent` sequences, manages cursor/wrap/scroll, publishes a lock-protected `ScreenSnapshot` for the renderer (in `TermCore/ScreenModel.swift`).
4. `Cell` / `Cursor` / `ScreenSnapshot` — terminal cell model, cursor, and immutable screen state snapshot with `Codable` conformance for `restore(from:)` on reattach (in `TermCore/Cell.swift`).

### Screen Buffer

- `CircularCollection<Container>` — generic O(1) append/prepend ring buffer over any `RandomAccessCollection` (in `TermCore/CircularCollection.swift`)
- `ScreenBuffer<Element>` — actor-isolated screen buffer backed by `CircularCollection` (in `TermCore/ScreenBuffer.swift`)
- `RingBuffer` — byte-level ring buffer over `Data` (in `TermCore/RingBuffer.swift`)

### Rendering

Metal-based terminal rendering with glyph atlas:

- `TermView` — `NSViewRepresentable` wrapping `TerminalMTKView` for SwiftUI integration (in `rTerm/TermView.swift`)
- `TerminalMTKView` — `MTKView` subclass that accepts keyboard input via `NSEvent` (in `rTerm/TermView.swift`)
- `RenderCoordinator` — `MTKViewDelegate` that reads `ScreenModel.latestSnapshot()` and drives the Metal render pipeline (in `rTerm/TermView.swift`)
- `GlyphAtlas` — rasterizes printable ASCII glyphs (0x20–0x7E) to a Metal texture atlas using CoreText (in `rTerm/GlyphAtlas.swift`)
- `Shaders.metal` — vertex and fragment shaders for glyph rendering (in `rTerm/Shaders.metal`)
- `KeyEncoder` — converts `NSEvent` keyboard input to PTY byte sequences (in `rTerm/KeyEncoder.swift`)
- `ContentView` — SwiftUI entry point; creates `TerminalSession` which wires `DaemonClient` → `TerminalParser` → `ScreenModel` → `TermView` (in `rTerm/ContentView.swift`)
- `TerminalSession` — `@Observable @MainActor` class managing the full data flow pipeline; calls `Agent().register()` on first appearance in Release builds (in `rTerm/ContentView.swift`)

### Code Signing

The project uses self-signed **"Apple Engineer"** identities backed by AMFI Trusted Keys (see the `reference_apple_engineer_signing.md` memory for details and Confluence links):

- `CODE_SIGN_IDENTITY = "Apple Engineer:"` at the project level, inherited by all targets (TermCore, TermUI, rtermd, rTerm explicitly)
- `CODE_SIGN_STYLE = Manual`, `CODE_SIGNING_REQUIRES_TEAM = NO`, empty `DEVELOPMENT_TEAM`
- `rtermd` is embedded into `rTerm.app/Contents/MacOS/` via a Copy Files build phase with `CodeSignOnCopy` so it picks up the app's Apple Engineer identity; this also lets `@loader_path/../Frameworks` resolve to the properly-signed framework copies at launch time
- The daemon is a platform binary under AMFI (trusted key treats it as B&I-equivalent), which means every library it loads must share the Apple Engineer signature

### Dependencies

- **XPC** (system framework, `import XPC`, macOS 14+) — `XPCSession`, `XPCListener`, `XPCPeerHandler`, `XPCReceivedMessage`
- **ServiceManagement** — `SMAppService` for Release-path agent registration

`swift-async-algorithms` remains as a Swift Package Manager dependency in the project file but is not currently imported anywhere (residue from the removed `RemotePTY` that used `AsyncChannel`). Safe to drop if build time matters.

### Logging

Uses `OSLog` via `Logger` extensions.

**TermCore** (`Logger.TermCore`, subsystem `com.ronnyf.TermCore`): categories `ScreenBuffer`, `PseudoTerminal`, `ScreenModel`, `DaemonClient`.

**rtermd** (subsystem `com.ronnyf.rtermd`): categories `main`, `Session`, `SessionManager`, `DaemonPeerHandler`.

Stream daemon output with:
```bash
log stream --predicate 'subsystem == "com.ronnyf.rtermd"' --level debug
```

## Key Conventions

- Tests use Swift Testing framework (`import Testing`, `@Test`, `#expect`) — not XCTest. ~93 `@Test` annotations across TermCoreTests (`CircularCollection`, `TerminalParser`, `ScreenModel`, `PseudoTerminal`, `Codable`, `DaemonProtocol`) and rTermTests (`KeyEncoder`).
- UI tests (rTermUITests) use XCTest — this is the only exception.
- TermCore is a framework (not a Swift package), with a public umbrella header `TermCore.h`.
- `BUILD_LIBRARY_FOR_DISTRIBUTION` is enabled for TermCore (Release) and TermUI — module stability is enforced.
- App sandbox is disabled (`ENABLE_APP_SANDBOX = NO`) to allow PTY/process operations.
- `com.apple.security.application-groups` was removed (unused; IPC is via the Mach service, not a shared container).
- Source files carry GPLv3 license headers.

## Data Flow

```
User Input → KeyEncoder → DaemonClient.send(.input(sessionID:, data:))
                              ↓ (XPC Mach service com.ronnyf.rterm.rtermd)
                        DaemonPeerHandler → SessionManager.handleInput → Session.write → PTY primary
                              ↓ shell (zsh/bash) writes back to PTY
                         Session read source (daemon queue)
                              ├─→ TerminalParser → [TerminalEvent] → ScreenModel.apply (daemon)
                              └─→ fanOut: DaemonResponse.output to all attached XPCSessions
                              ↓ (XPC push)
DaemonClient incomingMessageHandler → TerminalParser → [TerminalEvent] → ScreenModel.apply (client mirror)
                                                                                ↓
                                              RenderCoordinator → Metal → TermView
```

On `.createSession` + `.attach`, the client receives a full `ScreenSnapshot` to restore its local `ScreenModel` — this is what enables detach/reattach across app launches.
