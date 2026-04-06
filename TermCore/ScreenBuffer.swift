//
//  ScreenBuffer.swift
//  TermCore
//
//  Created by Ronny Falk on 7/2/24.
//

import Foundation
import OSLog

public actor ScreenBuffer<Element> {
    
    private var elements: CircularCollection<ContiguousArray<Element?>>

    public init(capacity: Int) {
        elements = CircularCollection(ContiguousArray(repeating: nil, count: capacity))
    }
    
    public func append(data: some DataProtocol) {
        let string = String(data: Data(data), encoding: .utf8)
        Logger.TermCore.screenBuffer.log("appending data: \(String(describing: data)), text: \(string ?? "")")
    }
    
    public func append(line elements: [Element]) {
        self.elements.append(elements)
    }
    
    public func prepend(line elements: [Element]) {
        self.elements.prepend(elements)
    }
}

struct ScreenGrid {
    var columns: Int
    var rows: Int
    var elements: [UInt8]
}

public actor YAScreenBuffer {
    var dimensions: (Int, Int)
    var elements: ContiguousArray<UInt8>
    var currentIndex: Int
    var current: (row: Int, col: Int)
    
    init(columns: Int, rows: Int, elements: Int) {
        self.dimensions = (columns, rows)
        self.elements = ContiguousArray(repeating: UInt8(0), count: 5000);
        self.currentIndex = self.elements.startIndex;
        self.current = (0, 0)
    }
    
    public var currentRow: Int {
        0
    }
    
    public var currentColumn: Int {
        0
    }
    
    public func append(data: some DataProtocol) {
        
    }
    
    public func insert(data: some DataProtocol, at index: Int) {
        
    }
    
    public func insert(data: some DataProtocol, row: Int, column: Int) {
        
    }
    
    public func prepend(data: some DataProtocol) {
        
    }
}
