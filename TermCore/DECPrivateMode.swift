//
//  DECPrivateMode.swift
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

/// DEC private mode parameters for `CSI ? Pm h/l`. Phase 1 parses them all;
/// Phase 2 implements their behavior.
///
/// Non-`@frozen`: more modes exist in the wild than we enumerate.
public enum DECPrivateMode: Sendable, Equatable {
    case cursorKeyApplication    // 1    DECCKM
    case autoWrap                // 7    DECAWM
    case cursorVisible           // 25   DECTCEM
    case alternateScreen1049     // 1049 (save + alt + clear)
    case alternateScreen1047     // 1047 (alt + clear)
    case alternateScreen47       // 47   (legacy)
    case saveCursor1048          // 1048 (save cursor only)
    case bracketedPaste          // 2004
    case unknown(Int)            // preserves param for logging
}
