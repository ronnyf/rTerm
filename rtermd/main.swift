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

private let serviceName = "com.ronnyf.rterm.rtermd"
private let idleExitDelay: TimeInterval = 5
private let log = Logger(subsystem: "com.ronnyf.rtermd", category: "main")

// MARK: - Bootstrap

log.info("rtermd starting (pid=\(getpid()))")

let sessionManager = SessionManager()

// MARK: - XPC Listener

let listener: XPCListener
do {
    listener = try XPCListener(service: serviceName) { request in
        request.accept { session in
            DaemonPeerHandler(session: session, manager: sessionManager)
        }
    }
} catch {
    log.fault("Failed to create XPC listener: \(error)")
    exit(EXIT_FAILURE)
}

log.info("XPC listener active on \(serviceName)")

// MARK: - Signal handling: SIGTERM

/// Graceful shutdown on SIGTERM. Stops all sessions, then exits.
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
signal(SIGTERM, SIG_IGN)
sigtermSource.setEventHandler {
    log.info("Received SIGTERM — shutting down")
    Task {
        await sessionManager.shutdownAll()
        log.info("Shutdown complete, exiting")
        exit(EXIT_SUCCESS)
    }
}
sigtermSource.activate()

// MARK: - Signal handling: SIGCHLD

/// Reap child processes when they exit. This prevents zombie accumulation
/// and triggers session cleanup inside SessionManager.
let sigchldSource = DispatchSource.makeSignalSource(signal: SIGCHLD, queue: .main)
signal(SIGCHLD, SIG_IGN)
sigchldSource.setEventHandler {
    Task {
        await sessionManager.reapChildren()
    }
}
sigchldSource.activate()

// MARK: - Exit-when-empty

/// When the last session is removed, wait `idleExitDelay` seconds and exit
/// if no new sessions have been created in the meantime. This allows the
/// daemon to be relaunched on demand by launchd rather than lingering idle.
let exitTimer = OSAllocatedUnfairLock<DispatchWorkItem?>(initialState: nil)

Task {
    await sessionManager.setOnEmpty {
        let item = DispatchWorkItem {
            Task {
                let count = await sessionManager.sessionCount
                if count == 0 {
                    log.info("Idle timeout reached with no sessions — exiting")
                    exit(EXIT_SUCCESS)
                } else {
                    log.info("Idle timeout fired but \(count) session(s) exist — staying alive")
                }
            }
        }

        // Cancel any previously scheduled idle exit (e.g. if a session was
        // created and destroyed rapidly).
        exitTimer.withLock { pending in
            pending?.cancel()
            pending = item
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + idleExitDelay,
            execute: item
        )

        log.info("Idle exit scheduled in \(idleExitDelay)s")
    }
}

// MARK: - Run loop

dispatchMain()
