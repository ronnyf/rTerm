//
//  DaemonProtocolTests.swift
//  TermCoreTests
//
//  Created by Ronny Falk on 4/9/26.
//

import Testing
import Foundation
@testable import TermCore

// MARK: - Test Helpers

/// Encodes a value to JSON and decodes it back, returning the round-tripped result.
private func roundTrip<T: Codable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
}

// MARK: - DaemonRequest Codable

struct DaemonRequestTests {

    @Test("DaemonRequest.listSessions round-trips through JSON")
    func listSessionsRoundTrip() throws {
        let request = DaemonRequest.listSessions
        let decoded = try roundTrip(request)
        #expect(decoded == request)
    }

    @Test("DaemonRequest.createSession round-trips through JSON")
    func createSessionRoundTrip() throws {
        let request = DaemonRequest.createSession(shell: .zsh, rows: 24, cols: 80)
        let decoded = try roundTrip(request)
        #expect(decoded == request)
    }

    @Test("DaemonRequest.attach round-trips through JSON")
    func attachRoundTrip() throws {
        let request = DaemonRequest.attach(sessionID: 42)
        let decoded = try roundTrip(request)
        #expect(decoded == request)
    }

    @Test("DaemonRequest.detach round-trips through JSON")
    func detachRoundTrip() throws {
        let request = DaemonRequest.detach(sessionID: 7)
        let decoded = try roundTrip(request)
        #expect(decoded == request)
    }

    @Test("DaemonRequest.input round-trips through JSON")
    func inputRoundTrip() throws {
        let payload = Data("ls -la\n".utf8)
        let request = DaemonRequest.input(sessionID: 1, data: payload)
        let decoded = try roundTrip(request)
        #expect(decoded == request)
    }

    @Test("DaemonRequest.resize round-trips through JSON")
    func resizeRoundTrip() throws {
        let request = DaemonRequest.resize(sessionID: 3, rows: 50, cols: 132)
        let decoded = try roundTrip(request)
        #expect(decoded == request)
    }

    @Test("All DaemonRequest cases survive an array round-trip")
    func allCasesRoundTrip() throws {
        let requests: [DaemonRequest] = [
            .listSessions,
            .createSession(shell: .bash, rows: 24, cols: 80),
            .attach(sessionID: 1),
            .detach(sessionID: 2),
            .input(sessionID: 3, data: Data([0x1B, 0x5B, 0x41])),
            .resize(sessionID: 4, rows: 40, cols: 120),
        ]
        let decoded = try roundTrip(requests)
        #expect(decoded == requests)
    }
}

// MARK: - DaemonResponse Codable

struct DaemonResponseTests {

    private static let sampleSessionInfo = SessionInfo(
        id: 1,
        shell: .zsh,
        tty: "/dev/ttys003",
        pid: 12345,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        title: "zsh",
        rows: 24,
        cols: 80,
        hasClient: true
    )

    @Test("DaemonResponse.sessions round-trips through JSON")
    func sessionsRoundTrip() throws {
        let response = DaemonResponse.sessions([Self.sampleSessionInfo])
        let decoded = try roundTrip(response)
        #expect(decoded == response)
    }

    @Test("DaemonResponse.sessions round-trips an empty list")
    func sessionsEmptyRoundTrip() throws {
        let response = DaemonResponse.sessions([])
        let decoded = try roundTrip(response)
        #expect(decoded == response)
    }

    @Test("DaemonResponse.sessionCreated round-trips through JSON")
    func sessionCreatedRoundTrip() throws {
        let response = DaemonResponse.sessionCreated(Self.sampleSessionInfo)
        let decoded = try roundTrip(response)
        #expect(decoded == response)
    }

    @Test("DaemonResponse.screenSnapshot round-trips through JSON with nested types")
    func screenSnapshotRoundTrip() throws {
        let cells: ContiguousArray<Cell> = [
            Cell(character: "$"), Cell(character: " "),
            .empty, .empty,
        ]
        let snapshot = ScreenSnapshot(
            cells: cells,
            cols: 2,
            rows: 2,
            cursor: Cursor(row: 0, col: 1)
        )
        let response = DaemonResponse.screenSnapshot(sessionID: 5, snapshot: snapshot)
        let decoded = try roundTrip(response)
        #expect(decoded == response)
    }

    @Test("DaemonResponse.sessionEnded round-trips through JSON")
    func sessionEndedRoundTrip() throws {
        let response = DaemonResponse.sessionEnded(sessionID: 10, exitCode: 0)
        let decoded = try roundTrip(response)
        #expect(decoded == response)
    }

    @Test("DaemonResponse.sessionEnded preserves non-zero exit codes")
    func sessionEndedNonZeroExitCode() throws {
        let response = DaemonResponse.sessionEnded(sessionID: 2, exitCode: -1)
        let decoded = try roundTrip(response)
        #expect(decoded == response)
    }

    @Test("DaemonResponse.output round-trips through JSON")
    func outputRoundTrip() throws {
        let response = DaemonResponse.output(sessionID: 1, data: Data("hello\n".utf8))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
    }

    @Test("DaemonResponse.error round-trips through JSON")
    func errorRoundTrip() throws {
        let response = DaemonResponse.error(.sessionNotFound(99))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
    }
}

// MARK: - DaemonError Codable

struct DaemonErrorTests {

    @Test("DaemonError.sessionNotFound round-trips through JSON")
    func sessionNotFoundRoundTrip() throws {
        let error = DaemonError.sessionNotFound(42)
        let decoded = try roundTrip(error)
        #expect(decoded == error)
    }

    @Test("DaemonError.spawnFailed round-trips through JSON")
    func spawnFailedRoundTrip() throws {
        let error = DaemonError.spawnFailed(2)
        let decoded = try roundTrip(error)
        #expect(decoded == error)
    }

    @Test("DaemonError.alreadyAttached round-trips through JSON")
    func alreadyAttachedRoundTrip() throws {
        let error = DaemonError.alreadyAttached(7)
        let decoded = try roundTrip(error)
        #expect(decoded == error)
    }

    @Test("DaemonError.internalError round-trips through JSON")
    func internalErrorRoundTrip() throws {
        let error = DaemonError.internalError("unexpected state")
        let decoded = try roundTrip(error)
        #expect(decoded == error)
    }

    @Test("All DaemonError cases survive an array round-trip")
    func allCasesRoundTrip() throws {
        let errors: [DaemonError] = [
            .sessionNotFound(0),
            .spawnFailed(-1),
            .alreadyAttached(100),
            .internalError("test message"),
        ]
        let decoded = try roundTrip(errors)
        #expect(decoded == errors)
    }

    @Test("DaemonError conforms to Error protocol")
    func conformsToError() {
        let error: any Error = DaemonError.internalError("fail")
        #expect(error is DaemonError)
    }
}

// MARK: - SessionInfo Codable

struct SessionInfoTests {

    @Test("SessionInfo round-trips through JSON")
    func roundTripTest() throws {
        let info = SessionInfo(
            id: 1,
            shell: .bash,
            tty: "/dev/ttys001",
            pid: 9999,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            title: "bash",
            rows: 24,
            cols: 80,
            hasClient: false
        )
        let decoded = try roundTrip(info)
        #expect(decoded == info)
    }

    @Test("SessionInfo preserves all fields after round-trip")
    func fieldPreservation() throws {
        let date = Date(timeIntervalSince1970: 1_712_700_000)
        let info = SessionInfo(
            id: 42,
            shell: .fish,
            tty: "/dev/ttys007",
            pid: 54321,
            createdAt: date,
            title: "vim main.swift",
            rows: 50,
            cols: 132,
            hasClient: true
        )
        let decoded = try roundTrip(info)

        #expect(decoded.id == 42)
        #expect(decoded.shell == .fish)
        #expect(decoded.tty == "/dev/ttys007")
        #expect(decoded.pid == 54321)
        #expect(decoded.createdAt == date)
        #expect(decoded.title == "vim main.swift")
        #expect(decoded.rows == 50)
        #expect(decoded.cols == 132)
        #expect(decoded.hasClient == true)
    }

    @Test("SessionInfo array round-trips through JSON")
    func arrayRoundTrip() throws {
        let sessions = [
            SessionInfo(
                id: 1, shell: .zsh, tty: "/dev/ttys001", pid: 100,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                title: "zsh", rows: 24, cols: 80, hasClient: true
            ),
            SessionInfo(
                id: 2, shell: .bash, tty: "/dev/ttys002", pid: 200,
                createdAt: Date(timeIntervalSince1970: 1_700_000_001),
                title: "bash", rows: 30, cols: 100, hasClient: false
            ),
        ]
        let decoded = try roundTrip(sessions)
        #expect(decoded == sessions)
    }
}

// MARK: - Sendable

struct DaemonProtocolSendableTests {

    @Test("DaemonRequest is Sendable across isolation boundaries")
    func requestSendable() async {
        let request = DaemonRequest.createSession(shell: .zsh, rows: 24, cols: 80)
        let result = await Task { request }.value
        #expect(result == request)
    }

    @Test("DaemonResponse is Sendable across isolation boundaries")
    func responseSendable() async {
        let response = DaemonResponse.output(sessionID: 1, data: Data("hi".utf8))
        let result = await Task { response }.value
        #expect(result == response)
    }

    @Test("DaemonError is Sendable across isolation boundaries")
    func errorSendable() async {
        let error = DaemonError.sessionNotFound(5)
        let result = await Task { error }.value
        #expect(result == error)
    }

    @Test("SessionInfo is Sendable across isolation boundaries")
    func sessionInfoSendable() async {
        let info = SessionInfo(
            id: 1, shell: .sh, tty: "/dev/ttys000", pid: 1,
            createdAt: Date(timeIntervalSince1970: 0),
            title: "sh", rows: 24, cols: 80, hasClient: false
        )
        let result = await Task { info }.value
        #expect(result == info)
    }
}
