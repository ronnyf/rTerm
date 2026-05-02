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

/// Whether arrow keys (and Home / End) emit application-mode (`ESC O X`) or
/// normal-mode (`ESC [ X`) sequences. Mirrors DECCKM (DEC private mode 1).
@frozen public enum CursorKeyMode: Sendable, Equatable {
    case normal
    case application
}

/// Translates `NSEvent` key events into the byte sequences a terminal shell expects.
public struct KeyEncoder: Sendable {

    public init() {}

    private enum CursorKey { case up, down, right, left }

    /// Encode an arrow key. Final byte: A=up, B=down, C=right, D=left.
    /// Intro byte: `O` (0x4F) in application mode, `[` (0x5B) in normal mode.
    private func cursorKey(_ key: CursorKey, mode: CursorKeyMode) -> Data {
        let final: UInt8
        switch key {
        case .up:    final = 0x41
        case .down:  final = 0x42
        case .right: final = 0x43
        case .left:  final = 0x44
        }
        let intro: UInt8 = (mode == .application) ? 0x4F /* O */ : 0x5B /* [ */
        return Data([0x1B, intro, final])
    }

    /// Encode a key-down event into the bytes to write to the PTY.
    ///
    /// - Parameter event: The AppKit key-down event.
    /// - Parameter cursorKeyMode: Selects between application and normal cursor
    ///   key sequences. Read from `ScreenModel.latestSnapshot().cursorKeyApplication`
    ///   at call time — KeyEncoder is stateless so the same instance is safe to
    ///   reuse across keystrokes.
    /// - Returns: The encoded bytes, or `nil` for unhandled keys.
    public func encode(_ event: NSEvent, cursorKeyMode: CursorKeyMode = .normal) -> Data? {
        // 1. Special keys by keyCode (handled before printable-character paths).
        switch event.keyCode {
        case 36:  return Data([0x0D])                  // Return / Enter
        case 51:  return Data([0x7F])                  // Delete / Backspace (sends DEL — matches POSIX terminals)
        case 48:  return Data([0x09])                  // Tab

        // Cursor keys — DECCKM-aware.
        case 126: return cursorKey(.up,    mode: cursorKeyMode)
        case 125: return cursorKey(.down,  mode: cursorKeyMode)
        case 124: return cursorKey(.right, mode: cursorKeyMode)
        case 123: return cursorKey(.left,  mode: cursorKeyMode)

        // Home / End. xterm uses ESC [ H / ESC [ F regardless of DECCKM in the
        // most common configurations; some apps also accept ESC O H / ESC O F.
        // We follow xterm's "linux"/"vt220" preset: always CSI form.
        case 115: return Data([0x1B, 0x5B, 0x48])      // Home → ESC [ H
        case 119: return Data([0x1B, 0x5B, 0x46])      // End  → ESC [ F

        // Page Up / Page Down — DEC-style ~ tilde sequences.
        case 116: return Data([0x1B, 0x5B, 0x35, 0x7E])  // PgUp → ESC [ 5 ~
        case 121: return Data([0x1B, 0x5B, 0x36, 0x7E])  // PgDn → ESC [ 6 ~

        // Forward delete (fn-Delete on compact keyboards).
        case 117: return Data([0x1B, 0x5B, 0x33, 0x7E])  // ESC [ 3 ~

        default:
            break
        }

        // 2. Ctrl + letter (a-z) → control byte (Phase 1 behavior, preserved).
        if event.modifierFlags.contains(.control),
           let raw = event.charactersIgnoringModifiers,
           raw.count == 1,
           let scalar = raw.unicodeScalars.first,
           scalar.value >= UInt32(Character("a").asciiValue!),
           scalar.value <= UInt32(Character("z").asciiValue!) {
            let byte = UInt8(scalar.value) &- 0x60
            return Data([byte])
        }

        // 3. Printable characters (handles shift, option-modified glyphs, etc.).
        if let characters = event.characters, !characters.isEmpty {
            return Data(characters.utf8)
        }

        return nil
    }
}
