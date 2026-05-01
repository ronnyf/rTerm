//
//  CellStyle.swift
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

import Foundation

/// SGR attribute bitfield — compact representation for the per-cell style.
@frozen public struct CellAttributes: OptionSet, Sendable, Equatable, Codable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let bold          = CellAttributes(rawValue: 1 << 0)
    public static let dim           = CellAttributes(rawValue: 1 << 1)
    public static let italic        = CellAttributes(rawValue: 1 << 2)
    public static let underline     = CellAttributes(rawValue: 1 << 3)
    public static let blink         = CellAttributes(rawValue: 1 << 4)
    public static let reverse       = CellAttributes(rawValue: 1 << 5)
    public static let strikethrough = CellAttributes(rawValue: 1 << 6)
}

/// Per-cell visual style. Mirrors the "current pen" state that SGR modifies.
public struct CellStyle: Sendable, Equatable, Codable {
    public var foreground: TerminalColor
    public var background: TerminalColor
    public var attributes: CellAttributes

    public init(foreground: TerminalColor = .default,
                background: TerminalColor = .default,
                attributes: CellAttributes = []) {
        self.foreground = foreground
        self.background = background
        self.attributes = attributes
    }

    public static let `default` = CellStyle()
}
