//
//  BracketedPasteTests.swift
//  rTermTests
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

import Foundation
import Testing
@testable import rTerm

@Suite("Bracketed paste")
struct BracketedPasteTests {

    @Test("Wrap when enabled adds ESC[200~ ... ESC[201~ envelope")
    func test_wrap_enabled() {
        let wrapped = TerminalSession.bracketedPasteWrap("hello", enabled: true)
        let expected =
            Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])  // ESC [ 2 0 0 ~
            + "hello".data(using: .utf8)!
            + Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])  // ESC [ 2 0 1 ~
        #expect(wrapped == expected)
    }

    @Test("Wrap when disabled returns raw UTF-8 bytes")
    func test_wrap_disabled() {
        let raw = TerminalSession.bracketedPasteWrap("hello", enabled: false)
        #expect(raw == "hello".data(using: .utf8))
    }

    @Test("Empty string still receives the envelope when enabled")
    func test_wrap_empty_enabled() {
        let wrapped = TerminalSession.bracketedPasteWrap("", enabled: true)
        let expected =
            Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E,
                  0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])
        #expect(wrapped == expected)
    }

    @Test("Multi-byte UTF-8 (emoji + accented chars) is preserved inside the envelope")
    func test_wrap_multibyte_utf8() {
        let wrapped = TerminalSession.bracketedPasteWrap("café 🍰", enabled: true)
        let payload = "café 🍰".data(using: .utf8)!
        #expect(wrapped.starts(with: [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]))
        #expect(wrapped.suffix(6) == Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]))
        let middleStart = 6
        let middleEnd = wrapped.count - 6
        let middle = wrapped.subdata(in: middleStart..<middleEnd)
        #expect(middle == payload)
    }
}
