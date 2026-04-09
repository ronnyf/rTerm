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
TermCoreTests (unit tests, uses Swift Testing framework)
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
- `PseudoTerminal` — wraps `AltPTY` + `Shell` + window size, provides `DispatchIO` channels (in `TermCore/PseudoTerminal.swift`)
- `termios` and `winsize` have `Codable`/`Equatable` conformances for XPC serialization

### Screen Buffer

- `CircularCollection<Container>` — generic O(1) append/prepend ring buffer over any `RandomAccessCollection` (in `TermCore/CircularCollection.swift`)
- `ScreenBuffer<Element>` — actor-isolated screen buffer backed by `CircularCollection` (in `TermCore/ScreenBuffer.swift`)
- `RingBuffer` — byte-level ring buffer over `Data` (in `TermCore/RingBuffer.swift`)

### Rendering (WIP)

- `TermView` — Metal-based rendering via `MTKView` + `NSViewRepresentable` (in `rTerm/TermView.swift`)
- `TermViewController` — `NSViewController` subclass with Metal pipeline setup
- `ContentView` — current SwiftUI entry point; wires up `RemotePTY` output to a `TextEditor` as interim display

### Dependencies

- **AsyncAlgorithms** (apple/swift-async-algorithms) — used in TermCore for `AsyncChannel` and `merge`
- **XPCOverlay** — XPC session/listener abstractions (`XPCSession`, `XPCListener`, `XPCPeerHandler`, `XPCReceivedMessage`)

### Logging

Uses `OSLog` via `Logger` extensions namespaced under `Logger.TermCore` (subsystem: `com.ronnyf.TermCore`). Categories: `SessionHandler`, `RemotePTY`, `ScreenBuffer`.

## Key Conventions

- Tests use Swift Testing framework (`import Testing`, `@Test`, `#expect`) — not XCTest.
- TermCore is a framework (not a Swift package), with a public umbrella header `TermCore.h`.
- `BUILD_LIBRARY_FOR_DISTRIBUTION` is enabled for TermCore (Release) and TermUI — module stability is enforced.
- App sandbox is disabled (`ENABLE_APP_SANDBOX = NO`) to allow PTY/process operations.
- Source files carry GPLv3 license headers.
