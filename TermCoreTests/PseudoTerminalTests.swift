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

        // Set raw mode so read() returns immediately without waiting for newline
        var rawTermios = Darwin.termios()
        tcgetattr(pt.pty.secondary.rawValue, &rawTermios)
        cfmakeraw(&rawTermios)
        tcsetattr(pt.pty.secondary.rawValue, TCSANOW, &rawTermios)

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

    @Test("start() spawns shell and outputStream yields data")
    func test_start_and_output_stream() async throws {
        let pt = try PseudoTerminal(shell: .sh)
        let ttyName = try pt.start()

        #expect(!ttyName.isEmpty)

        // Send a command that produces known output
        let command = Data("echo hello\r".utf8)
        pt.write(command)

        // Read first chunk from outputStream with a timeout
        let result = try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask {
                for await data in pt.outputStream {
                    return data
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                return nil
            }

            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }

        #expect(result != nil)
        #expect(result!.count > 0)
    }

    @Test("shell echo reaches ScreenModel through parser pipeline")
    func test_shell_echo_through_parser_to_screen() async throws {
        let pt = try PseudoTerminal(shell: .sh)
        let _ = try pt.start()

        let screenModel = ScreenModel(cols: 80, rows: 24)

        // Send a command that produces known output
        pt.write(Data("echo hello\r".utf8))

        // Single consumer with timeout — AsyncStream is single-consumer,
        // so we must not create multiple `for await` iterators.
        let found = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                var parser = TerminalParser()
                for await data in pt.outputStream {
                    let events = parser.parse(data)
                    await screenModel.apply(events)

                    let snap = await screenModel.snapshot()
                    let text = (0..<snap.rows).map { row in
                        (0..<snap.cols).map { col in
                            String(snap[row, col].character)
                        }.joined()
                    }.joined()

                    if text.contains("hello") {
                        return true
                    }
                }
                return false
            }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                return false
            }

            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }

        if !found {
            let snap = await screenModel.snapshot()
            let firstRowText = (0..<snap.cols).map { String(snap[0, $0].character) }.joined()
            Issue.record("Expected 'hello' in screen model, first row: '\(firstRowText.trimmingCharacters(in: .whitespaces))'")
        }
    }
}
