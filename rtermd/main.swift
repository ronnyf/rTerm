//
//  main.swift
//  rtermd
//
//  Created by Ronny Falk on 4/9/26.
//  Copyright (C) 2026 RFx Software Inc. All rights reserved.
//
//  This file is part of rTerm.
//
//  Terminal App is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Terminal App is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Terminal App.  If not, see <https://www.gnu.org/licenses/>.
//

import Darwin
import Foundation
import os
import TermCore
import XPC

// MARK: - Configuration

private let idleExitDelay: TimeInterval = 5
private let log = Logger(subsystem: "com.ronnyf.rtermd", category: "main")

// MARK: - Bootstrap

log.info("rtermd starting (pid=\(getpid()))")

// Single serial queue -- the backbone of the daemon's concurrency model.
// Every piece of mutable state is accessed exclusively from this queue:
// SessionManager, Session instances, DaemonPeerHandler instances, signal
// handlers, and the idle-exit timer.
//
// `nonisolated` is required here because Swift 6.2's approachable-concurrency
// mode promotes top-level executable code to @MainActor by default, but this
// daemon has no main runloop -- everything runs on `daemonQueue`. Without
// these annotations, the MainActor-isolated lets couldn't be referenced from
// the @Sendable XPCListener closure (which runs on the daemon queue).
nonisolated let daemonQueue = DispatchQueue(label: "com.ronnyf.rtermd.daemon")

nonisolated let sessionManager = SessionManager(queue: daemonQueue)

// MARK: - XPC Listener

let listener: XPCListener
do {
    listener = try XPCListener(service: DaemonService.machServiceName, targetQueue: daemonQueue) { request in
        request.accept { session in
            DaemonPeerHandler(session: session, manager: sessionManager)
        }
    }
} catch {
    log.fault("Failed to create XPC listener: \(error)")
    exit(EXIT_FAILURE)
}

log.info("XPC listener active on \(DaemonService.machServiceName)")

// MARK: - Signal handling

// Block SIGTERM so the dispatch source handles it instead of terminating us.
// SIGCHLD is left at the default (SIG_DFL) -- setting it to SIG_IGN would
// tell the kernel to auto-reap children, defeating waitpid() in reapChildren.
signal(SIGTERM, SIG_IGN)

// SIGTERM: graceful shutdown -- stop all sessions, then exit.
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: daemonQueue)
sigtermSource.setEventHandler {
    log.info("Received SIGTERM -- shutting down")
    sessionManager.shutdownAll()
    log.info("Shutdown complete, exiting")
    exit(EXIT_SUCCESS)
}
sigtermSource.activate()

// SIGCHLD: reap child processes -- prevents zombies, triggers session cleanup.
let sigchldSource = DispatchSource.makeSignalSource(signal: SIGCHLD, queue: daemonQueue)
sigchldSource.setEventHandler {
    sessionManager.reapChildren()
}
sigchldSource.activate()

// MARK: - Exit-when-empty

// When the last session is removed, wait idleExitDelay seconds and exit
// if no new sessions were created. Prevents the daemon from lingering idle.
var exitWorkItem: DispatchWorkItem?

sessionManager.onEmpty = {
    // Cancel any previously scheduled idle exit (e.g. if a session was
    // created and destroyed rapidly).
    exitWorkItem?.cancel()

    let item = DispatchWorkItem {
        if sessionManager.sessionCount == 0 {
            log.info("Idle timeout reached with no sessions -- exiting")
            exit(EXIT_SUCCESS)
        } else {
            log.info("Idle timeout fired but \(sessionManager.sessionCount) session(s) exist -- staying alive")
        }
    }

    exitWorkItem = item
    daemonQueue.asyncAfter(deadline: .now() + idleExitDelay, execute: item)
    log.info("Idle exit scheduled in \(idleExitDelay)s")
}

// MARK: - Run loop

dispatchMain()
