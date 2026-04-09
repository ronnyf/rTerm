//
//  TermCoreTests.swift
//  TermCoreTests
//
//  Created by Ronny Falk on 6/19/24.
//

import Testing
@testable import TermCore

struct TermCoreTests {
    
    @Test("CircularCollection Sequence Conformance")
    func test_circular_collection_sequence() throws {
        let array = [1,2,3,4]
        var c = CircularCollection(array)
        
        #expect(c.count == array.count)
        
        c.append(5)
        #expect(Array(c) == [2,3,4,5]) //removed 1
        #expect(c.elements == [5,2,3,4])
        #expect(c.offset == 0)
        
        c.append(6)
        #expect(Array(c) == [3,4,5,6]) //removed 2
        #expect(c.elements == [5,6,3,4])
        #expect(c.offset == 1)
        
        c.prepend(2)
        #expect(Array(c) == [2,3,4,5]) //removed 6
        #expect(c.elements == [5,2,3,4])
        #expect(c.offset == 0)
        
        c.prepend(1)
        #expect(Array(c) == [1,2,3,4]) //removed 5
        #expect(c.elements == [1,2,3,4])
        #expect(c.offset == 3)
        
        c.prepend(0)
        #expect(Array(c) == [0,1,2,3]) //removed 4
        #expect(c.elements == [1,2,3,0])
        #expect(c.offset == 2)
    }
    
    @Test("CircularCollection Collection Conformance")
    func test_circular_collection_collection() throws {
        var cc = CircularCollection([1,2,3,4])
        
        cc.append(5)
        #expect(Array(cc) == [2,3,4,5])
        #expect(cc.elements == [5,2,3,4])
        #expect(cc.offset == 0)
        
        #expect(cc.first == 2)
        #expect(cc.last == 5)
        #expect(cc.firstIndex(of: 3) == 1)
        #expect(cc.lastIndex(of: 4) == 2)
    }
    
    @Test("CircularCollection Contiguous Collection Conformance")
    func test_circular_collection_contiguous_collection() throws {
        var cc = CircularCollection(ContiguousArray([1,2,3,4]))
        
        cc.append(5)
        #expect(Array(cc) == [2,3,4,5])
        #expect(cc.elements == [5,2,3,4])
        #expect(cc.offset == 0)
        
        #expect(cc.first == 2)
        #expect(cc.last == 5)
        #expect(cc.firstIndex(of: 3) == 1)
        #expect(cc.lastIndex(of: 4) == 2)
    }
}
