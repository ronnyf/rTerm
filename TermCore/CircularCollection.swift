//
//  CircularCollection.swift
//  TermCore
//
//  Created by Ronny Falk on 7/9/24.
//

import Foundation

/// Requirements:
/// Prepend and append O(1)
public struct CircularCollection<Container: RandomAccessCollection> {
    
    @usableFromInline
    var elements: Container
    
    @usableFromInline
    var offset: Container.Index
    
    public init(_ elements: Container) {
        self.elements = elements
        self.offset = elements.index(before: elements.endIndex)
    }

    @inlinable
    public mutating func append(_ element: Container.Element) where Container: MutableCollection, Container.Index == Int {
        // move offset to the right
        let newOffset = offset.advanced(by: 1) % elements.count
        elements[newOffset] = element
        offset = newOffset
    }
    
    @inlinable
    public mutating func append<S: Sequence>(_ elements: S) where S.Element == Container.Element, Container: MutableCollection, Container.Index == Int {
        for element in elements {
            append(element)
        }
    }
    
    @inlinable
    public mutating func prepend(_ element: Container.Element) where Container: MutableCollection, Container.Index == Int {
        elements[offset] = element
        //move the offset marker to the left
        if offset == elements.startIndex {
            offset = elements.index(before: elements.endIndex)
        } else {
            offset = elements.index(before: offset)
        }
    }
    
    @inlinable
    public mutating func prepend<S: Sequence>(_ elements: S) where S.Element == Container.Element, Container: MutableCollection, Container.Index == Int {
        // TODO: we can split the payload into before and after slices, and apply them, 2 steps instead of n
        for element in elements {
            prepend(element)
        }
    }
    
    @inlinable
    public var count: Int { elements.count }
}

extension CircularCollection: Sequence where Container.Index == Int {
    
    public struct Iterator: IteratorProtocol {
        
        let elements: Container
        var currentIndex: Container.Index
        var elementCount: Int = 0
        
        init(elements: Container, offsetMarker: Container.Index) {
            self.elements = elements
            self.currentIndex = offsetMarker.advanced(by: 1) % elements.count
        }
        
        public mutating func next() -> Container.Element? {
            guard elementCount < elements.count else { return nil }
            let element = elements[currentIndex]
            currentIndex = currentIndex.advanced(by: 1) % elements.count
            elementCount += 1
            return element
        }
    }
    
    public func makeIterator() -> CircularCollection.Iterator {
        Iterator(elements: elements, offsetMarker: offset)
    }
}

extension CircularCollection: Collection where Container.Index == Int {
    
    @inlinable
    public var startIndex: Container.Index {
        elements.startIndex
    }
    
    @inlinable
    public var endIndex: Container.Index {
        elements.endIndex
    }
    
    public func index(after i: Container.Index) -> Container.Index {
        elements.index(after: i)
    }
    
    @inlinable
    public subscript(position: Container.Index) -> Container.Element {
        let mappedPosition = offset.advanced(by: 1).advanced(by: position) % elements.count
        return elements[mappedPosition]
    }
}

extension CircularCollection: BidirectionalCollection where Container.Index == Int {
    
    public func index(before i: Container.Index) -> Container.Index {
        elements.index(before: i)
    }
}
