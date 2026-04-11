# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

rTerm is a terminal emulator for macOS (with iOS/xrOS aspirations) written in Swift and SwiftUI. It uses an XPC service architecture to isolate shell process management from the main app. Licensed under GPLv3.

## Build Commands

This is an Xcode project (`rTerm.xcodeproj`), not a Swift Package. Use `xcodebuild` from the CLI.

```bash
# Build the main app (includes TermCore, TermUI frameworks + rTermSupport XPC service)
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
└── rTermSupport.xpc (XPC service, shell process host)
    └── TermCore.framework

rTermLauncher (CLI tool, launch agent for XPC)
    └── has duplicate SessionHandler.swift (diverged from TermCore's)
TermCoreTests (unit tests — CircularCollection, TerminalParser, ScreenModel, PseudoTerminal)
rTermTests (unit tests — KeyEncoder)
```

### XPC-Based Shell Isolation

The app does **not** run shell processes in-process. Instead:

1. **rTerm app** creates a `RemotePTY` which opens an `XPCSession` to the `rTermSupport` XPC service (`com.ronnyf.rTermSupport`).
2. **rTermSupport** (XPC service) receives a `RemoteCommand.spawn`, creates a `PseudoTerminal`, sets up the PTY file descriptors, and runs a `Shell` `Process` with stdin/stdout/stderr redirected to the PTY secondary.
3. Shell output flows back to the app via XPC messages (`RemoteResponse.stdout`/`.stderr`) and feeds into a `ScreenBuffer`.

Key types in this flow:
- `RemoteCommand` / `RemoteResponse` — XPC message protocol (in `TermCore/XPCRequest.swift`)
- `RemotePTY` — client-side XPC session manager (in `TermCore/RemotePTY.swift`)
- `PTYResponder` — server-side XPC handler that spawns shells (in `rTermSupport/PTYResponder.swift`)
- `SessionHandler<Responder>` — generic XPC peer handler (in `TermCore/SessionHandler.swift`)
- `XPCSyncResponder` / `XPCResponder` — protocols for XPC request/response handling

### PTY Layer

- `AltPTY` — creates a primary/secondary pseudo-terminal pair via `posix_openpt`/`grantpt`/`unlockpt` (in `TermCore/PTY.swift`)
- `PseudoTerminal` — wraps `AltPTY` + `Shell` + window size, provides `write()`, `resize()`, and `start()` with FileHandle-based output streaming (in `TermCore/PseudoTerminal.swift`)
- `Shell` — enum for shell selection (bash, zsh, fish, sh) with path resolution (in `TermCore/Shell.swift`)
- `Agent` — `SMAppService` wrapper for launch agent management (in `TermCore/Agent.swift`)
- `termios` and `winsize` have `Codable`/`Equatable` conformances for XPC serialization

### Terminal Processing Pipeline

Raw bytes from the PTY are parsed and applied to a screen model:

1. `TerminalParser` — UTF-8 aware parser that converts raw bytes into `TerminalEvent` values. Handles multi-byte sequences and split codepoints across buffer boundaries (in `TermCore/TerminalParser.swift`).
2. `TerminalEvent` — enum representing parsed events: `.printable(Character)`, control characters, newlines, etc. (in `TermCore/TerminalEvent.swift`).
3. `ScreenModel` — actor-isolated screen grid that processes `TerminalEvent` sequences. Manages cursor position, line wrapping, scrolling, and produces `ScreenSnapshot` for rendering (in `TermCore/ScreenModel.swift`).
4. `Cell` / `Cursor` / `ScreenSnapshot` — terminal cell model, 2D cursor position, and immutable screen state snapshot (in `TermCore/Cell.swift`).

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
- `ContentView` — SwiftUI entry point; creates `TerminalSession` which wires `RemotePTY` → `TerminalParser` → `ScreenModel` → `TermView` (in `rTerm/ContentView.swift`)
- `TerminalSession` — `@Observable` class managing the full data flow pipeline (in `rTerm/ContentView.swift`)

### Dependencies

- **AsyncAlgorithms** (apple/swift-async-algorithms v1.1.3) — used in TermCore for `AsyncChannel` and `merge`
- **swift-collections** (apple/swift-collections v1.4.1) — transitive dependency of AsyncAlgorithms
- **XPC** (system framework, `import XPC`, macOS 14+) — `XPCSession`, `XPCListener`, `XPCPeerHandler`, `XPCReceivedMessage`

### Logging

Uses `OSLog` via `Logger` extensions namespaced under `Logger.TermCore` (subsystem: `com.ronnyf.TermCore`). Categories: `SessionHandler`, `RemotePTY`, `ScreenBuffer`.

## Key Conventions

- Tests use Swift Testing framework (`import Testing`, `@Test`, `#expect`) — not XCTest. ~42 test cases across TermCoreTests and rTermTests.
- UI tests (rTermUITests) use XCTest — this is the only exception.
- TermCore is a framework (not a Swift package), with a public umbrella header `TermCore.h`.
- `BUILD_LIBRARY_FOR_DISTRIBUTION` is enabled for TermCore (Release) and TermUI — module stability is enforced.
- App sandbox is disabled (`ENABLE_APP_SANDBOX = NO`) to allow PTY/process operations.
- Source files carry GPLv3 license headers.

## Data Flow

```
User Input → KeyEncoder → RemotePTY.send(.input(data))
                              ↓ (XPC)
                        PTYResponder → PseudoTerminal → Shell (zsh/bash)
                              ↓ (XPC: RemoteResponse.stdout)
RemotePTY → TerminalParser → [TerminalEvent] → ScreenModel → ScreenSnapshot
                                                                   ↓
                                              RenderCoordinator → Metal → TermView
```
