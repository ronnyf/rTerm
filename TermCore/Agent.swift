//
//  Agent.swift
//  TermCore
//
//  Created by Ronny Falk on 6/22/24.
//

import Foundation
import ServiceManagement
import XPCOverlay

public class Agent {
    
    let service: SMAppService
    
    public convenience init() {
        self.init(name: "group.com.ronnyf.rterm.rtermd.plist")
    }
    
    init(name: String) {
        self.service = SMAppService.agent(plistName: name)
    }
    
    public var status: SMAppService.Status {
        service.status
    }
    
    public func register() throws {
        try service.register()
    }
    
    public func unregister() throws {
        try service.unregister()
    }
}
