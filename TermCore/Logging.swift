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
        
        static let sessionHandler = Logger(subsystem: subsystem, category: "SessionHandler")
        static let remotePTY = Logger(subsystem: subsystem, category: "RemotePTY")
        static let screenBuffer = Logger(subsystem: subsystem, category: "ScreenBuffer")
    }
//    static let general = Logger(subsystem: subsystem, category: "TermCore")
}
