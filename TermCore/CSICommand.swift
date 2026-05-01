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
    // Cursor motion.
    //
    // Index convention is split deliberately to match the VT/ANSI spec:
    //
    // - `cursorPosition` (CSI H / HVP) is pre-normalized to 0-indexed at parse
    //   time — the row/col values already sit in `[0, dim)` bounds.
    // - `cursorHorizontalAbsolute` (CSI G) and `verticalPositionAbsolute`
    //   (CSI d) carry the VT 1-indexed value as-received on the wire; the
    //   ScreenModel subtracts 1 at apply time. This preserves the original
    //   parameter for logging/debug and avoids info loss when the parameter
    //   is 0 (which VT treats as "default of 1").
    // - The relative motions (`cursorUp`/`cursorDown`/`cursorForward`/
    //   `cursorBack`) carry a positive delta already defaulted to 1 by the
    //   parser's `p(_:default:)` helper. The model applies them via
    //   `max(1, n)` defensively but values from `mapCSI` are always ≥ 1.
    //
    // `ScreenModel.handleCSI` clamps the final cursor position to the
    // screen dimensions after each motion.
    case cursorUp(Int)
    case cursorDown(Int)
    case cursorForward(Int)
    case cursorBack(Int)
    case cursorPosition(row: Int, col: Int)
    case cursorHorizontalAbsolute(Int)    // VT 1-indexed (see note above)
    case verticalPositionAbsolute(Int)    // VT 1-indexed (see note above)
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
