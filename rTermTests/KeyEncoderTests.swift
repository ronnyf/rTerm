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
}
