//
//  C0Control.swift
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

/// C0 (ASCII 0x00-0x1F + 0x7F) control codes. Closed set by VT spec —
/// `@frozen` to avoid library-evolution resilience overhead under
/// `BUILD_LIBRARY_FOR_DISTRIBUTION`.
@frozen public enum C0Control: Sendable, Equatable {
    case nul             // 0x00
    case bell            // 0x07
    case backspace       // 0x08
    case horizontalTab   // 0x09
    case lineFeed        // 0x0A
    case verticalTab     // 0x0B  — behaves like lineFeed
    case formFeed        // 0x0C  — behaves like lineFeed
    case carriageReturn  // 0x0D
    case shiftOut        // 0x0E  — ignored (alt charset out of scope)
    case shiftIn         // 0x0F  — ignored
    case delete          // 0x7F  — ignored
}
