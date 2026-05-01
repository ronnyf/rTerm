//
//  AttachPayload.swift
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

/// Wire-facing payload returned from `.attach`. Carries the live snapshot plus
/// bounded scrollback history so the attaching client can restore state.
///
/// Phase 1: `recentHistory` is always empty (no scrollback yet). Phase 2 fills
/// it; existing wire format stays stable.
public struct AttachPayload: Sendable, Equatable, Codable {

    /// Single row of cells in the scrollback history.
    public typealias Row = ContiguousArray<Cell>

    public let snapshot: ScreenSnapshot
    public let recentHistory: ContiguousArray<Row>
    public let historyCapacity: Int

    public init(snapshot: ScreenSnapshot,
                recentHistory: ContiguousArray<Row> = [],
                historyCapacity: Int = 0) {
        self.snapshot = snapshot
        self.recentHistory = recentHistory
        self.historyCapacity = historyCapacity
    }
}
