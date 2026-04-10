//
//  CodableTests.swift
//  TermCoreTests
//
//  Created by Ronny Falk on 4/9/26.
//

import Testing
import Foundation
@testable import TermCore

struct ShellTests {

    // MARK: - Codable Round-Trip

    @Test("Shell encodes and decodes via JSON round-trip", arguments: Shell.allCases)
    func codableRoundTrip(shell: Shell) throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(shell)
        let decoded = try decoder.decode(Shell.self, from: data)

        #expect(decoded == shell)
    }

    @Test("Shell JSON representation is stable across all cases")
    func codableAllCases() throws {
        let allShells = Shell.allCases
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(allShells)
        let decoded = try decoder.decode([Shell].self, from: data)

        #expect(decoded == allShells)
    }

    // MARK: - Sendable

    @Test("Shell is Sendable across isolation boundaries")
    func sendable() async {
        let shell: Shell = .zsh
        let result = await Task { shell }.value
        #expect(result == .zsh)
    }

    // MARK: - Executable Paths

    @Test("Shell executable paths point to /bin", arguments: [
        (Shell.bash, "/bin/bash"),
        (Shell.zsh, "/bin/zsh"),
        (Shell.fish, "/bin/fish"),
        (Shell.sh, "/bin/sh"),
    ])
    func executable(shell: Shell, expected: String) {
        #expect(shell.executable == expected)
    }

    // MARK: - Default Arguments

    @Test("bash default arguments exclude +m flag")
    func bashArguments() {
        let args = Shell.bash.defaultArguments
        #expect(args.contains("--norc"))
        #expect(args.contains("--noprofile"))
        #expect(!args.contains("+m"))
    }

    @Test("zsh default arguments exclude +m flag")
    func zshArguments() {
        let args = Shell.zsh.defaultArguments
        #expect(args.contains("-f"))
        #expect(!args.contains("+m"))
    }

    @Test("fish and sh have empty default arguments", arguments: [
        Shell.fish,
        Shell.sh,
    ])
    func emptyArguments(shell: Shell) {
        #expect(shell.defaultArguments.isEmpty)
    }

    // MARK: - Process Configuration

    @Test("process() configures environment with SHELL variable")
    func processEnvironment() throws {
        let shell = Shell.zsh
        let proc = try shell.process()

        #expect(proc.environment?["SHELL"] == "/bin/zsh")
        #expect(proc.environment?["HOME"] == NSHomeDirectory())
        #expect(proc.environment?["TERM"] == "dumb")
    }

    @Test("process() uses NSHomeDirectory for current directory")
    func processCurrentDirectory() throws {
        let proc = try Shell.bash.process()
        let expected = URL(fileURLWithPath: NSHomeDirectory())

        #expect(proc.currentDirectoryURL == expected)
    }
}
