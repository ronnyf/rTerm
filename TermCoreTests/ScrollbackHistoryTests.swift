//
//  ScrollbackHistoryTests.swift
//  TermCoreTests
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

import Testing
@testable import TermCore

@Suite("ScrollbackHistory")
struct ScrollbackHistoryTests {

    typealias Row = ScrollbackHistory.Row

    private func row(_ s: String) -> Row {
        ContiguousArray(s.map { Cell(character: $0) })
    }

    @Test("Empty history returns count = 0 and tail returns empty")
    func test_empty() {
        let h = ScrollbackHistory(capacity: 10)
        #expect(h.count == 0)
        #expect(h.tail(5) == [])
        #expect(h.all() == [])
    }

    @Test("Push grows count up to capacity")
    func test_push_grows() {
        var h = ScrollbackHistory(capacity: 3)
        h.push(row("a"))
        #expect(h.count == 1)
        h.push(row("b"))
        h.push(row("c"))
        #expect(h.count == 3)
        let all = h.all()
        #expect(all.count == 3)
        #expect(all[0] == row("a"))
        #expect(all[1] == row("b"))
        #expect(all[2] == row("c"))
    }

    @Test("Push beyond capacity evicts the oldest row")
    func test_push_evicts() {
        var h = ScrollbackHistory(capacity: 3)
        h.push(row("a"))
        h.push(row("b"))
        h.push(row("c"))
        h.push(row("d"))
        #expect(h.count == 3, "Capacity-bound count")
        let all = h.all()
        #expect(all == [row("b"), row("c"), row("d")])
    }

    @Test("tail(n) returns the last n rows in chronological order")
    func test_tail() {
        var h = ScrollbackHistory(capacity: 5)
        for c in "abcde" { h.push(row(String(c))) }
        let last2 = h.tail(2)
        #expect(last2 == [row("d"), row("e")])
    }

    @Test("tail(n) caps at validCount when n > validCount")
    func test_tail_caps() {
        var h = ScrollbackHistory(capacity: 10)
        h.push(row("x"))
        h.push(row("y"))
        let t = h.tail(100)
        #expect(t == [row("x"), row("y")])
    }

    @Test("tail(0) returns empty regardless of validCount")
    func test_tail_zero() {
        var h = ScrollbackHistory(capacity: 10)
        #expect(h.tail(0) == [], "tail(0) on empty history is empty")
        h.push(row("x"))
        h.push(row("y"))
        #expect(h.tail(0) == [], "tail(0) on populated history is also empty")
    }
}
