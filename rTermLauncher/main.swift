//
//  main.swift
//  rTermLauncher
//
//  Created by Ronny Falk on 6/22/24.
//

import Foundation
import XPC

if #available(macOS 14.0, *) {
    let listener = try XPCListener(service: "com.ronnyf.rTermLauncher.support") { request in
        request.accept { session in
            SessionHandler(session: session, queue: nil)
        }
    }
} else {
    fatalError("macOS 14.0 required")
}

dispatchMain()
