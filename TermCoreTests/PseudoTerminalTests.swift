//
//  PseudoTerminalTests.swift
//  TermCoreTests
//

import Testing
import Darwin
import System
@testable import TermCore

struct PseudoTerminalTests {

    @Test("write() sends bytes through PTY primary to secondary")
    func test_write_sends_bytes() throws {
        let pt = try PseudoTerminal()
        let testData = Data("hello".utf8)

        pt.write(testData)

        // Read from secondary FD to verify bytes arrived
        var buffer = [UInt8](repeating: 0, count: 64)
        let bytesRead = read(pt.pty.secondary.rawValue, &buffer, buffer.count)
        #expect(bytesRead > 0)
        let received = Data(buffer[..<bytesRead])
        #expect(received == testData)
    }

    @Test("resize() propagates winsize via TIOCSWINSZ")
    func test_resize_propagates_winsize() throws {
        let pt = try PseudoTerminal()

        pt.resize(rows: 40, cols: 120)

        // Read winsize from secondary FD to verify propagation
        var ws = Darwin.winsize()
        let rc = ioctl(pt.pty.secondary.rawValue, TIOCGWINSZ, &ws)
        #expect(rc == 0)
        #expect(ws.ws_row == 40)
        #expect(ws.ws_col == 120)
        #expect(pt.winsize.ws_row == 40)
        #expect(pt.winsize.ws_col == 120)
    }
}
