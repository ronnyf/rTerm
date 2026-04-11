//
//  Shell.swift
//  TermCore
//
//  Created by Ronny Falk on 6/20/24.
//

import Foundation

public enum Shell: Codable, Sendable, Equatable, CaseIterable {
    case bash
    case zsh
    case fish
    case sh
}

extension Shell {
    public var executable: String {
        switch self {
            case .bash:
                return "/bin/bash"

            case .zsh:
                return "/bin/zsh"

            case .fish:
                return "/bin/fish"

            case .sh:
                return "/bin/sh"
        }
    }

    public var defaultArguments: [String] {
        switch self {
            case .bash:
                return ["--norc", "--noprofile"]

            case .zsh:
                return ["-f"]

            default:
                return []
        }
    }

    public func process() throws -> Process {
        let home = NSHomeDirectory()
        let shellProcess = Process()

        shellProcess.executableURL = URL(filePath: executable)
        shellProcess.arguments = defaultArguments
        shellProcess.environment = [
            "HOME": home,
            "SHELL": executable,
            "PATH": "/usr/bin:/bin:/opt/homebrew/bin",
            "TERM": "dumb"
        ]
        shellProcess.currentDirectoryURL = URL(filePath: home)

        //TODO: incorporate some config (e.g. pickl for those things maybe?)

        return shellProcess
    }
}
