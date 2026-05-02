//
//  KeyEncoderTests.swift
//  rTermTests
//
//  Created by Ronny Falk on 6/19/24.
//
//  This file is part of rTerm.
//
//  Terminal App is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Terminal App is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Terminal App. If not, see <https://www.gnu.org/licenses/>.
//

import AppKit
import Foundation
import Testing
@testable import rTerm

// MARK: - Helper

/// Creates an `NSEvent` key-down event for testing.
///
/// - Parameters:
///   - characters: The `characters` property of the event.
///   - charactersIgnoringModifiers: The `charactersIgnoringModifiers` property.
///   - modifierFlags: Modifier flags (e.g., `.control`).
///   - keyCode: The virtual key code.
/// - Returns: An `NSEvent`, or `nil` if AppKit refuses to create one.
private func makeKeyEvent(
    characters: String = "",
    charactersIgnoringModifiers: String = "",
    modifierFlags: NSEvent.ModifierFlags = [],
    keyCode: UInt16 = 0
) -> NSEvent? {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifierFlags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        isARepeat: false,
        keyCode: keyCode
    )
}

/// Creates a key-down event for Phase 2 T7 tests (arrow/navigation keys that
/// have no `characters` payload by default). Matches the helper name used in
/// the Phase 2 plan.
@MainActor
private func mockKeyDown(
    keyCode: UInt16,
    characters: String = "",
    modifierFlags: NSEvent.ModifierFlags = []
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifierFlags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    )!
}

// MARK: - Tests

@MainActor
struct KeyEncoderTests {

    private let encoder = KeyEncoder()

    // MARK: Printable characters

    @Test("Printable 'a' encodes to UTF-8 0x61")
    func printableA() throws {
        let event = try #require(makeKeyEvent(
            characters: "a",
            charactersIgnoringModifiers: "a",
            keyCode: 0
        ))
        let result = encoder.encode(event)
        #expect(result == Data([0x61]))
    }

    // MARK: Special keys

    @Test("Return (keyCode 36) encodes to 0x0D")
    func returnKey() throws {
        let event = try #require(makeKeyEvent(
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            keyCode: 36
        ))
        let result = encoder.encode(event)
        #expect(result == Data([0x0D]))
    }

    @Test("Delete (keyCode 51) encodes to 0x7F")
    func deleteKey() throws {
        let event = try #require(makeKeyEvent(
            characters: "\u{7F}",
            charactersIgnoringModifiers: "\u{7F}",
            keyCode: 51
        ))
        let result = encoder.encode(event)
        #expect(result == Data([0x7F]))
    }

    @Test("Tab (keyCode 48) encodes to 0x09")
    func tabKey() throws {
        let event = try #require(makeKeyEvent(
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            keyCode: 48
        ))
        let result = encoder.encode(event)
        #expect(result == Data([0x09]))
    }

    // MARK: Ctrl + letter

    @Test("Ctrl+C encodes to 0x03 (ETX)")
    func ctrlC() throws {
        let event = try #require(makeKeyEvent(
            characters: "\u{03}",
            charactersIgnoringModifiers: "c",
            modifierFlags: .control,
            keyCode: 8
        ))
        let result = encoder.encode(event)
        #expect(result == Data([0x03]))
    }

    @Test("Ctrl+D encodes to 0x04 (EOT)")
    func ctrlD() throws {
        let event = try #require(makeKeyEvent(
            characters: "\u{04}",
            charactersIgnoringModifiers: "d",
            modifierFlags: .control,
            keyCode: 2
        ))
        let result = encoder.encode(event)
        #expect(result == Data([0x04]))
    }

    @Test("Ctrl+Z encodes to 0x1A (SUB)")
    func ctrlZ() throws {
        let event = try #require(makeKeyEvent(
            characters: "\u{1A}",
            charactersIgnoringModifiers: "z",
            modifierFlags: .control,
            keyCode: 6
        ))
        let result = encoder.encode(event)
        #expect(result == Data([0x1A]))
    }

    // MARK: Unhandled keys

    @Test("Unhandled key (F1, keyCode 122) returns nil")
    func unhandledF1() throws {
        let event = try #require(makeKeyEvent(
            characters: "",
            charactersIgnoringModifiers: "",
            modifierFlags: [.function],
            keyCode: 122
        ))
        let result = encoder.encode(event)
        #expect(result == nil)
    }

    // MARK: - Arrow keys (Phase 2 T7)

    // The two single-keyCode tests below are kept alongside the table tests
    // (`test_all_arrows_*`) on purpose: they fire first, name the full VT
    // sequence in their titles, and isolate a DECCKM regression to one keyCode
    // so debugging is a single bisect — not a discovery of which row in the
    // table failed.
    @Test("Up arrow normal-mode → ESC [ A")
    func test_arrow_up_normal_mode() {
        // keyCode 126 = up arrow
        let event = mockKeyDown(keyCode: 126)
        let encoded = KeyEncoder().encode(event, cursorKeyMode: .normal)
        #expect(encoded == Data([0x1B, 0x5B, 0x41]))
    }

    @Test("Up arrow application-mode → ESC O A")
    func test_arrow_up_application_mode() {
        let event = mockKeyDown(keyCode: 126)
        let encoded = KeyEncoder().encode(event, cursorKeyMode: .application)
        #expect(encoded == Data([0x1B, 0x4F, 0x41]))
    }

    @Test("All four arrows match VT/xterm: A=up B=down C=right D=left")
    func test_all_arrows_normal_mode() {
        let cases: [(keyCode: UInt16, suffix: UInt8)] = [
            (126, 0x41),  // up    → A
            (125, 0x42),  // down  → B
            (124, 0x43),  // right → C
            (123, 0x44),  // left  → D
        ]
        for (keyCode, suffix) in cases {
            let event = mockKeyDown(keyCode: keyCode)
            let encoded = KeyEncoder().encode(event, cursorKeyMode: .normal)
            #expect(encoded == Data([0x1B, 0x5B, suffix]),
                    "keyCode \(keyCode) normal-mode")
        }
    }

    @Test("All four arrows in application mode use ESC O")
    func test_all_arrows_application_mode() {
        let cases: [(keyCode: UInt16, suffix: UInt8)] = [
            (126, 0x41), (125, 0x42), (124, 0x43), (123, 0x44),
        ]
        for (keyCode, suffix) in cases {
            let event = mockKeyDown(keyCode: keyCode)
            let encoded = KeyEncoder().encode(event, cursorKeyMode: .application)
            #expect(encoded == Data([0x1B, 0x4F, suffix]),
                    "keyCode \(keyCode) application-mode")
        }
    }

    // MARK: - Home / End (Phase 2 T7)

    @Test("Home key → ESC [ H")
    func test_home_key() {
        // keyCode 115 = Home (fn + left arrow on Mac compact keyboards)
        let event = mockKeyDown(keyCode: 115)
        let encoded = KeyEncoder().encode(event, cursorKeyMode: .normal)
        #expect(encoded == Data([0x1B, 0x5B, 0x48]))
    }

    @Test("End key → ESC [ F")
    func test_end_key() {
        let event = mockKeyDown(keyCode: 119)
        let encoded = KeyEncoder().encode(event, cursorKeyMode: .normal)
        #expect(encoded == Data([0x1B, 0x5B, 0x46]))
    }

    // MARK: - PgUp / PgDn (Phase 2 T7)

    @Test("Page Up → ESC [ 5 ~")
    func test_page_up() {
        let event = mockKeyDown(keyCode: 116)
        let encoded = KeyEncoder().encode(event, cursorKeyMode: .normal)
        #expect(encoded == Data([0x1B, 0x5B, 0x35, 0x7E]))
    }

    @Test("Page Down → ESC [ 6 ~")
    func test_page_down() {
        let event = mockKeyDown(keyCode: 121)
        let encoded = KeyEncoder().encode(event, cursorKeyMode: .normal)
        #expect(encoded == Data([0x1B, 0x5B, 0x36, 0x7E]))
    }

    // MARK: - Forward Delete (Phase 2 T7)

    @Test("Forward Delete (fn-Delete) → ESC [ 3 ~")
    func test_forward_delete() {
        // keyCode 117 = forward delete on Mac compact keyboards (fn + delete)
        let event = mockKeyDown(keyCode: 117)
        let encoded = KeyEncoder().encode(event, cursorKeyMode: .normal)
        #expect(encoded == Data([0x1B, 0x5B, 0x33, 0x7E]))
    }
}
