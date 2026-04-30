//
//  Logging.swift
//  TermCore
//
//  Created by Ronny Falk on 7/2/24.
//

import Foundation
import OSLog

extension Logger {
    enum TermCore {
        static let subsystem = "com.ronnyf.TermCore"

        static let screenBuffer = Logger(subsystem: subsystem, category: "ScreenBuffer")
        static let pseudoTerminal = Logger(subsystem: subsystem, category: "PseudoTerminal")
        static let screenModel = Logger(subsystem: subsystem, category: "ScreenModel")
        static let daemonClient = Logger(subsystem: subsystem, category: "DaemonClient")
    }
}
