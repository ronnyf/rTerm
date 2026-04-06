//
//  KeyEncoder.swift
//  rTerm
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

/// Translates `NSEvent` key events into the byte sequences a terminal shell expects.
public struct KeyEncoder: Sendable {

    public init() {}

    /// Encodes a key-down `NSEvent` into the `Data` that should be written to the PTY.
    ///
    /// Returns `nil` for unhandled keys.
    public func encode(_ event: NSEvent) -> Data? {
        // 1. Ctrl + letter  (a-z) → control byte
        if event.modifierFlags.contains(.control),
           let raw = event.charactersIgnoringModifiers,
           raw.count == 1,
           let scalar = raw.unicodeScalars.first,
           scalar.value >= UInt32(Character("a").asciiValue!),
           scalar.value <= UInt32(Character("z").asciiValue!) {
            let byte = UInt8(scalar.value) &- 0x60
            return Data([byte])
        }

        // 2. Special keys by keyCode
        switch event.keyCode {
        case 36: // Return / Enter
            return Data([0x0D])
        case 51: // Delete / Backspace
            return Data([0x7F])
        case 48: // Tab
            return Data([0x09])
        default:
            break
        }

        // 3. Printable characters (includes shift, option, etc.)
        if let characters = event.characters, !characters.isEmpty {
            return Data(characters.utf8)
        }

        // 4. Unhandled
        return nil
    }
}
