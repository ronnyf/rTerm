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

// MARK: - Cell Codable

struct CellCodableTests {

    @Test("Cell round-trips through JSON for a normal character")
    func normalCharacterRoundTrip() throws {
        let cell = Cell(character: "A")
        let data = try JSONEncoder().encode(cell)
        let decoded = try JSONDecoder().decode(Cell.self, from: data)
        #expect(decoded == cell)
    }

    @Test("Cell.empty round-trips through JSON")
    func emptyCellRoundTrip() throws {
        let cell = Cell.empty
        let data = try JSONEncoder().encode(cell)
        let decoded = try JSONDecoder().decode(Cell.self, from: data)
        #expect(decoded == cell)
        #expect(decoded.character == " ")
    }

    @Test("Cell round-trips through JSON for emoji and unicode", arguments: [
        Character("\u{1F600}"),  // grinning face emoji
        Character("\u{00E9}"),   // e-acute
        Character("\u{4E16}"),   // CJK character (shi4, "world")
    ])
    func unicodeRoundTrip(character: Character) throws {
        let cell = Cell(character: character)
        let data = try JSONEncoder().encode(cell)
        let decoded = try JSONDecoder().decode(Cell.self, from: data)
        #expect(decoded == cell)
    }

    @Test("Cell decoding rejects multi-character strings")
    func rejectsMultiCharacterString() throws {
        let json = Data(#"{"character":"AB"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Cell.self, from: json)
        }
    }

    @Test("Cell decoding rejects empty strings")
    func rejectsEmptyString() throws {
        let json = Data(#"{"character":""}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Cell.self, from: json)
        }
    }
}

// MARK: - Cursor Codable

struct CursorCodableTests {

    @Test("Cursor round-trips through JSON")
    func roundTrip() throws {
        let cursor = Cursor(row: 5, col: 42)
        let data = try JSONEncoder().encode(cursor)
        let decoded = try JSONDecoder().decode(Cursor.self, from: data)
        #expect(decoded == cursor)
    }

    @Test("Cursor at origin round-trips through JSON")
    func originRoundTrip() throws {
        let cursor = Cursor(row: 0, col: 0)
        let data = try JSONEncoder().encode(cursor)
        let decoded = try JSONDecoder().decode(Cursor.self, from: data)
        #expect(decoded == cursor)
    }
}

// MARK: - ScreenSnapshot Codable

struct ScreenSnapshotCodableTests {

    @Test("ScreenSnapshot round-trips through JSON for a small grid")
    func roundTrip() throws {
        // 2x3 grid: "Hi " / "   "
        let cells: ContiguousArray<Cell> = [
            Cell(character: "H"), Cell(character: "i"), .empty,
            .empty, .empty, .empty,
        ]
        let snapshot = ScreenSnapshot(
            activeCells: cells,
            cols: 3,
            rows: 2,
            cursor: Cursor(row: 0, col: 2),
            version: 0
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ScreenSnapshot.self, from: data)

        #expect(decoded == snapshot)
        #expect(decoded.cols == 3)
        #expect(decoded.rows == 2)
        #expect(decoded.cursor == Cursor(row: 0, col: 2))
        #expect(decoded[0, 0].character == "H")
        #expect(decoded[0, 1].character == "i")
        #expect(decoded[1, 2] == .empty)
    }

    @Test("ScreenSnapshot round-trips an all-empty grid")
    func emptyGridRoundTrip() throws {
        let cells = ContiguousArray<Cell>(repeating: .empty, count: 4)
        let snapshot = ScreenSnapshot(
            activeCells: cells,
            cols: 2,
            rows: 2,
            cursor: Cursor(row: 0, col: 0),
            version: 0
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ScreenSnapshot.self, from: data)

        #expect(decoded == snapshot)
    }
}

// MARK: - AttachPayload Codable

struct AttachPayloadCodableTests {

    @Test("AttachPayload round-trips through JSON")
    func attach_payload_roundtrip() throws {
        let snap = ScreenSnapshot(
            activeCells: ContiguousArray([Cell(character: "X")]),
            cols: 1,
            rows: 1,
            cursor: Cursor(row: 0, col: 0),
            cursorVisible: true,
            activeBuffer: .main,
            windowTitle: "t",
            version: 42
        )
        let payload = AttachPayload(snapshot: snap)
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(AttachPayload.self, from: data)
        #expect(decoded.snapshot == payload.snapshot)
        #expect(decoded.recentHistory.isEmpty)
    }
}

// MARK: - ScreenSnapshot Phase 2 backward compat + round-trip

struct ScreenSnapshotPhase2CodableTests {

    @Test("ScreenSnapshot decodes a Phase 1-shaped JSON payload (missing new fields)")
    func test_snapshot_decodes_phase1_payload() throws {
        // A minimal Phase 1-shaped snapshot — no cursorKeyApplication / bracketedPaste / bellCount / autoWrap.
        let json = """
        {
            "activeCells": [],
            "cols": 0,
            "rows": 0,
            "cursor": {"row": 0, "col": 0},
            "cursorVisible": true,
            "activeBuffer": "main",
            "version": 0
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ScreenSnapshot.self, from: json)
        #expect(decoded.cursorKeyApplication == false)
        #expect(decoded.bracketedPaste == false)
        #expect(decoded.bellCount == 0)
        #expect(decoded.autoWrap == true,
                "autoWrap defaults to true to match VT power-on state")
    }

    @Test("ScreenSnapshot Codable round-trip preserves all Phase 2 fields")
    func test_snapshot_roundtrip_phase2_fields() throws {
        let original = ScreenSnapshot(
            activeCells: ContiguousArray(repeating: .empty, count: 6),
            cols: 3, rows: 2,
            cursor: Cursor(row: 1, col: 2),
            cursorVisible: false,
            activeBuffer: .alt,
            windowTitle: "vim",
            cursorKeyApplication: true,
            bracketedPaste: true,
            bellCount: 42,
            autoWrap: false,
            version: 7
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScreenSnapshot.self, from: encoded)
        #expect(decoded == original)
    }
}
