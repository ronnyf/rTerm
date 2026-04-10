//
//  main.swift
//  rTermSupport
//
//  Created by Ronny Falk on 6/22/24.
//

import Darwin
import Foundation
import TermCore
import XPC

if #available(macOS 14.0, *) {
    let listener = try XPCListener(service: "com.ronnyf.rTermSupport") { request in
        request.accept { session in
            SessionHandler(session: session, queue: nil, responder: PTYResponder())
        }
    }
    print("DEBUG: Created Listener: \(listener)")
    
    let pid = setsid()
    if pid < 0 {
        print("DEBUG: setSid -> \(pid)")
    }
    
} else {
    fatalError("macOS 14.0 required")
}

dispatchMain()

