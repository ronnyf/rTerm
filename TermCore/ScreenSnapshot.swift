//
//  ScreenSnapshot.swift
//  TermCore
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

// MARK: - BufferKind

@frozen public enum BufferKind: Sendable, Equatable, Codable {
    case main
    case alt
}

// MARK: - ScreenSnapshot

/// Render-facing snapshot. Published on every state-changing apply; held in
/// `Mutex<SnapshotBox>` so the lock guards only a pointer swap.
///
/// All fields are immutable `let` — readers pull a reference out of the mutex
/// and use it without further synchronization.
public struct ScreenSnapshot: Sendable, Equatable, Codable {
    public let activeCells: ContiguousArray<Cell>
    public let cols: Int
    public let rows: Int
    public let cursor: Cursor
    public let cursorVisible: Bool
    public let activeBuffer: BufferKind
    public let windowTitle: String?
    public let version: UInt64

    public init(activeCells: ContiguousArray<Cell>,
                cols: Int,
                rows: Int,
                cursor: Cursor,
                cursorVisible: Bool = true,
                activeBuffer: BufferKind = .main,
                windowTitle: String? = nil,
                version: UInt64) {
        self.activeCells = activeCells
        self.cols = cols
        self.rows = rows
        self.cursor = cursor
        self.cursorVisible = cursorVisible
        self.activeBuffer = activeBuffer
        self.windowTitle = windowTitle
        self.version = version
    }

    /// 2D convenience subscript — preserved for existing renderer call sites.
    public subscript(row: Int, col: Int) -> Cell {
        activeCells[row * cols + col]
    }

    private enum CodingKeys: String, CodingKey {
        case activeCells, cols, rows, cursor, cursorVisible, activeBuffer, windowTitle, version
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let activeCells = try container.decode(ContiguousArray<Cell>.self, forKey: .activeCells)
        let cols = try container.decode(Int.self, forKey: .cols)
        let rows = try container.decode(Int.self, forKey: .rows)
        guard cols >= 0, rows >= 0 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "ScreenSnapshot dimensions must be non-negative; got \(cols)x\(rows)"))
        }
        guard activeCells.count == rows * cols else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "ScreenSnapshot.activeCells length \(activeCells.count) does not match dimensions \(rows)x\(cols) (expected \(rows * cols))"))
        }
        self.activeCells = activeCells
        self.cols = cols
        self.rows = rows
        self.cursor = try container.decode(Cursor.self, forKey: .cursor)
        self.cursorVisible = try container.decode(Bool.self, forKey: .cursorVisible)
        self.activeBuffer = try container.decode(BufferKind.self, forKey: .activeBuffer)
        self.windowTitle = try container.decodeIfPresent(String.self, forKey: .windowTitle)
        self.version = try container.decode(UInt64.self, forKey: .version)
    }
}
