//
//  Shell.swift
//  TermCore
//
//  Created by Ronny Falk on 6/20/24.
//

import Foundation
import System

public enum Shell {
    case bash
    case zsh
    case fish
    case sh
    case custom
}

extension Shell {
    var executable: String {
        switch self {
            case .bash:
                return "/bin/bash"
                
            case .zsh:
                return "/bin/zsh"
                
            case .fish:
                return "/bin/fish"
                
            case .sh:
                return "/bin/sh"
                
            case .custom:
                fatalError("not yet")
        }
    }
    
    var defaultArguments: [String] {
        switch self {
            case .bash:
                return ["-i"]
                
            default:
                return []
        }
    }
    
    public func process() throws -> Process {
        let shellProcess = Process()

        shellProcess.executableURL = URL(filePath: executable)
        shellProcess.arguments = defaultArguments
        shellProcess.environment = ["HOME": "/Users/ronny", "PATH": "/usr/bin:/bin:/opt/homebrew/bin"]
        shellProcess.currentDirectoryURL = URL(fileURLWithPath: "/Users/ronny")
        
        //TODO: incorporate some config (e.g. pickl for those things maybe?)
        
        return shellProcess
    }
}
