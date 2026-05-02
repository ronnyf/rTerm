//
//  ScrollbackHistory.swift
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

import Foundation

/// Bounded scrollback buffer of rendered rows. Evictions are O(1) via the
/// underlying `CircularCollection<Row>` ring buffer, with `validCount`
/// distinguishing "real history" from the pre-allocated empty slots.
///
/// Spec §4 names `CircularCollection<Row>` as the storage shape; this wrapper
/// adds the count-of-valid-rows semantics needed for "starts empty, grows up
/// to capacity, evicts oldest beyond capacity".
public struct ScrollbackHistory: Sendable {

    /// Single rendered row of cells (matches `AttachPayload.Row`).
    public typealias Row = ContiguousArray<Cell>

    /// Maximum number of rows retained. Excess rows evict the oldest.
    public let capacity: Int

    /// Underlying ring buffer. Always `capacity`-sized; `validCount`
    /// determines how many of the slots hold real (non-placeholder) rows.
    private var ring: CircularCollection<ContiguousArray<Row>>

    /// Number of real rows currently held (`0 ... capacity`).
    public private(set) var validCount: Int = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "ScrollbackHistory capacity must be > 0")
        self.capacity = capacity
        self.ring = CircularCollection(ContiguousArray(repeating: Row(), count: capacity))
    }

    /// Number of real rows held (alias for `validCount`; kept for ergonomics).
    public var count: Int { validCount }

    /// Push a row to the tail. Once `validCount == capacity`, oldest row evicts.
    ///
    /// **Invariant:** rows are stored by whole-row replacement. The underlying
    /// `CircularCollection.append` overwrites the slot wholesale; existing
    /// row buffers are never mutated in place. This is what lets the
    /// renderer hold a published `HistoryBox.rows` snapshot whose row buffers
    /// share storage with the actor's `ring.elements[i]` via CoW — the
    /// actor's next push drops its reference to the prior row, but the
    /// reader's reference keeps the buffer alive. A future "patch a row in
    /// place" optimization would silently break this assumption.
    public mutating func push(_ row: Row) {
        ring.append(row)
        if validCount < capacity { validCount += 1 }
    }

    /// Snapshot of the most recent `n` rows (or all rows if `n > validCount`),
    /// in chronological order (oldest first → newest last).
    public func tail(_ n: Int) -> ContiguousArray<Row> {
        guard validCount > 0, n > 0 else { return [] }
        let take = Swift.min(n, validCount)
        var result = ContiguousArray<Row>()
        result.reserveCapacity(take)
        // CircularCollection iterates oldest → newest after the most recent
        // append. We want the LAST `take` of `validCount` real rows, where
        // "real" rows occupy the most-recently-written `validCount` slots.
        // Iterate and skip the first (validCount - take) real rows.
        let skip = validCount - take
        var seen = 0
        for (i, row) in ring.enumerated() {
            // Only the first `validCount` slots from the tail are real, but
            // CircularCollection iteration order already aligns with
            // append-order. Skip the (capacity - validCount) leading
            // placeholder slots.
            if i < (capacity - validCount) { continue }
            if seen < skip { seen += 1; continue }
            result.append(row)
        }
        return result
    }

    /// Snapshot of every real row in chronological order.
    public func all() -> ContiguousArray<Row> { tail(validCount) }
}
