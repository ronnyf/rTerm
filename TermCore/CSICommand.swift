//
//  CSICommand.swift
//  TermCore
//
//  Created by Ronny Falk on 4/30/26.
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

/// Region argument for `CSI J` (erase in display) and `CSI K` (erase in line).
/// Closed set — `@frozen`.
@frozen public enum EraseRegion: Sendable, Equatable {
    case toEnd       // 0: cursor to end
    case toBegin     // 1: begin to cursor
    case all         // 2: entire area
    case scrollback  // 3: scrollback buffer (ED only; Phase 2)
}

/// A CSI (Control Sequence Introducer) command: `ESC [ params intermediates final`.
///
/// Non-`@frozen`: phases may add cases. `.unknown` is the open-world escape hatch
/// so consumers still switch exhaustively without `@unknown default`.
public enum CSICommand: Sendable, Equatable {
    // Cursor motion — 0-indexed after parser normalization; model clamps to screen.
    case cursorUp(Int)
    case cursorDown(Int)
    case cursorForward(Int)
    case cursorBack(Int)
    case cursorPosition(row: Int, col: Int)
    case cursorHorizontalAbsolute(Int)
    case verticalPositionAbsolute(Int)
    case saveCursor                         // CSI s
    case restoreCursor                      // CSI u

    // Erasing
    case eraseInDisplay(EraseRegion)        // CSI J
    case eraseInLine(EraseRegion)           // CSI K

    // Modes (Phase 2 primarily; parser may emit them now)
    case setMode(DECPrivateMode, enabled: Bool)

    // Scroll region (Phase 2 primarily)
    case setScrollRegion(top: Int?, bottom: Int?)

    // SGR — nested here because structurally it's just CSI with final byte 'm'.
    case sgr([SGRAttribute])

    case unknown(params: [Int], intermediates: [UInt8], final: UInt8)
}
