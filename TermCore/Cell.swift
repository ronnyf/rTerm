//
//  Cell.swift
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

public struct Cell: Sendable, Equatable, Codable {
    public var character: Character
    public var style: CellStyle

    public init(character: Character, style: CellStyle = .default) {
        self.character = character
        self.style = style
    }

    /// A blank cell — space with default style. SGR-styled blanks are produced by the screen model's pen.
    public static let empty = Cell(character: " ")

    private enum CodingKeys: String, CodingKey {
        case character
        case style
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let charString = try container.decode(String.self, forKey: .character)
        guard let first = charString.first, charString.count == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .character, in: container,
                debugDescription: "Cell.character must be exactly one Character")
        }
        self.character = first
        self.style = try container.decodeIfPresent(CellStyle.self, forKey: .style) ?? .default
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(String(character), forKey: .character)
        if style != .default {
            try container.encode(style, forKey: .style)
        }
    }
}
