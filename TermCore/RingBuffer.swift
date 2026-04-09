//
//  RingBuffer.swift
//  TermCore
//
//  Created by Ronny Falk on 8/19/24.
//

import Foundation

public struct RingBuffer {
    private var buffer: Data
    private var insertIndex: Data.Index
    
    private var headIndex: Data.Index
    private var tailIndex: Data.Index
    
    public init(capactiy: Int) {
        buffer = Data(capacity: capactiy)
        insertIndex = buffer.startIndex
        headIndex = buffer.startIndex
        tailIndex = headIndex
    }
    
    /*
        got: [0,0,0,0]
              ^ (insertIndex)
     
        append(1) =>
             [1,0,0,0]
                ^
        append(1) =>
            [1,1,0,0]
                 ^
        append(1) =>
            [1,1,1,0]
                   ^
        append(1) =>
            [1,1,1,1]
             ^
     */
    mutating public func append(_ element: Data.Element) {
        buffer[insertIndex] = element
        insertIndex = insertIndex.advanced(by: MemoryLayout.stride(ofValue: element)) % buffer.count
    }
    
    public func prepend(_ element: Data.Element) {
        
    }
}
