//
//  TerminalEvent.swift
//  TermCore
//
//  Created by Ronny Falk on 4/6/26.
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

/// A parsed terminal event produced by `TerminalParser` and consumed by `ScreenModel`.
///
/// All cases carry only value-typed, `Sendable` payloads, so the enum is safe
/// to pass across actor and task boundaries without additional synchronization.
public enum TerminalEvent: Sendable, Equatable {
    /// A displayable Unicode character (graphic, printable).
    case printable(Character)
    /// Line feed — ASCII 0x0A.
    case newline
    /// Carriage return — ASCII 0x0D.
    case carriageReturn
    /// Backspace — ASCII 0x08.
    case backspace
    /// Horizontal tab — ASCII 0x09.
    case tab
    /// Bell — ASCII 0x07.
    case bell
    /// A byte that the parser does not yet handle; passed through for future use.
    case unrecognized(UInt8)
}
