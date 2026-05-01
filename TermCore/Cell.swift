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

// MARK: - Cursor

/// The current write position within the terminal screen grid.
///
/// Row and column are zero-based indices into the grid produced by
/// `ScreenSnapshot`.
public struct Cursor: Sendable, Equatable, Codable {
    /// Zero-based row index (top = 0).
    public var row: Int
    /// Zero-based column index (left = 0).
    public var col: Int

    /// Creates a cursor positioned at the given row and column.
    public init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }
}

// MARK: - ScreenSnapshot

/// An immutable snapshot of the full terminal screen at a point in time.
///
/// The grid is stored as a flat, row-major `ContiguousArray<Cell>` for
/// cache-friendly iteration. Use the `(row:col:)` subscript for
/// two-dimensional access.
///
/// - Note: `ScreenSnapshot` is `Sendable` because all stored properties
///   are value types that are themselves `Sendable`.
public struct ScreenSnapshot: Sendable, Equatable, Codable {
    /// Flat row-major storage: `cells[row * cols + col]`.
    public let cells: ContiguousArray<Cell>
    /// Number of columns in the grid.
    public let cols: Int
    /// Number of rows in the grid.
    public let rows: Int
    /// Cursor position at the time of the snapshot.
    public let cursor: Cursor

    /// Creates a snapshot with the provided grid data and cursor position.
    ///
    /// - Parameters:
    ///   - cells: Flat row-major array of cells; must have exactly `rows * cols` elements.
    ///   - cols: Number of columns.
    ///   - rows: Number of rows.
    ///   - cursor: Cursor position.
    public init(cells: ContiguousArray<Cell>, cols: Int, rows: Int, cursor: Cursor) {
        self.cells = cells
        self.cols = cols
        self.rows = rows
        self.cursor = cursor
    }

    /// Accesses the cell at the specified row and column.
    ///
    /// - Parameters:
    ///   - row: Zero-based row index.
    ///   - col: Zero-based column index.
    public subscript(row: Int, col: Int) -> Cell {
        cells[row * cols + col]
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case cells, cols, rows, cursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let array = try container.decode([Cell].self, forKey: .cells)
        self.cols = try container.decode(Int.self, forKey: .cols)
        self.rows = try container.decode(Int.self, forKey: .rows)
        self.cursor = try container.decode(Cursor.self, forKey: .cursor)
        guard array.count == rows * cols else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Expected \(rows * cols) cells (\(rows)x\(cols)), got \(array.count)"
                )
            )
        }
        self.cells = ContiguousArray(array)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Array(cells), forKey: .cells)
        try container.encode(cols, forKey: .cols)
        try container.encode(rows, forKey: .rows)
        try container.encode(cursor, forKey: .cursor)
    }
}
