//
//  PTY.swift
//  TermCore
//
//  Created by Ronny Falk on 6/22/24.
//

import Foundation
import Darwin
import System

public enum FileDescriptorError: Error {
    case open
    case grant
    case unlock
    case noPtsName
    case ioctl(Int32)
}

extension FileDescriptor {
    
    static func makePrimary() throws -> FileDescriptor {
        let fdm = posix_openpt(O_RDWR);
        guard fdm >= 0 else { throw FileDescriptorError.open }
        
        let result = FileDescriptor(rawValue: fdm)
        
        guard grantpt(result.rawValue) == 0 else {
            try result.close()
            throw FileDescriptorError.grant
        }
        
        guard unlockpt(result.rawValue) == 0 else {
            try result.close()
            throw FileDescriptorError.unlock
        }
    
        return result
    }
    
    func makeSecondary(accessMode: AccessMode = .readWrite, options: OpenOptions = []) throws -> FileDescriptor {
        guard let ptsName else { throw FileDescriptorError.noPtsName }
        return try FileDescriptor.open(ptsName, accessMode, options: options)
    }
}

// TODO: some consumable stuff would work nicely here
public struct AltPTY: Sendable {
    
    public let primary: FileDescriptor
    public let secondary: FileDescriptor
    
    public init() throws {
        self.primary = try FileDescriptor.makePrimary()
        self.secondary = try self.primary.makeSecondary()
    }
}

extension AltPTY: Codable {}

extension FileDescriptor {
    
    public func dispatchIO(queue: DispatchQueue = DispatchQueue.global(qos: .userInteractive), closeWhenDone: Bool = false) throws -> DispatchIO {
        DispatchIO(type: .stream, fileDescriptor: rawValue, queue: queue, cleanupHandler: { error in
            if closeWhenDone == true {
                print("DEBUG: closing file desciptor: \(self)")
                try? self.close()
            }
            print("DEBUG: dispatchIO cleanup for \(self)")
            if error != 0 {
                print("ERROR: io: \(error)")
            }
        })
    }
}

extension DispatchIO {
    public enum Errors: Error {
        case write(Int32)
        case read(Int32)
    }
    
//    public func write(offset: Int = 0, data: DispatchData, queue: DispatchQueue = DispatchQueue.global(qos: .userInteractive)) async throws {
//        try await withCheckedThrowingContinuation { continuation in
//            write(offset: 0, data: data, queue: queue) { isDone, data, error in
//                if error == 0 && isDone == true {
//                    continuation.resume()
//                } else {
//                    continuation.resume(throwing: Errors.write(error))
//                }
//            }
//        }
//    }
//    
//    public func write(_ data: Data, queue: DispatchQueue = DispatchQueue.global(qos: .userInteractive)) async throws {
//        try await withCheckedThrowingContinuation { continuation in
//            data.withUnsafeBytes {
//                let dd = DispatchData(bytesNoCopy: $0, deallocator: .custom(nil, {
//                    //nothing to see here... we will dealloc this ourselves, don't worry.
//                }))
//                write(offset: 0, data: dd, queue: queue) { isDone, data, error in
//                    if error == 0 && isDone == true {
//                        continuation.resume()
//                    } else {
//                        continuation.resume(throwing: Errors.write(error))
//                    }
//                }
//            }
//        }
//    }
    
    public func read(
        length: Int = .max,
        queue: DispatchQueue = DispatchQueue.global(qos: .userInteractive),
        completion: @escaping ((Bool, DispatchData?, Int32) -> Void)
    ) {
        self.read(offset: 0, length: length, queue: queue, ioHandler: completion)
    }
    
//    public func values(queue: DispatchQueue = DispatchQueue.global(qos: .userInteractive)) -> some AsyncSequence<Data, Error> {
//        AsyncThrowingStream(Data.self) { continuation in
//            setLimit(lowWater: 1)
//            setLimit(highWater: 8192)
//            
//            read(queue: queue) { isDone, data, error in
//                guard error == 0 else {
//                    continuation.finish(throwing: Errors.read(error))
//                    return
//                }
//                
//                if let data, data.count > 0 {
//                    var resultData = Data(count: data.count)
//                    let copiedBytes = resultData.withUnsafeMutableBytes {
//                        data.copyBytes(to: $0)
//                    }
//                    precondition(copiedBytes <= data.count)
//                    continuation.yield(resultData)
//                }
//                
//                if isDone == true {
//                    continuation.finish()
//                }
//            }
//            
//            continuation.onTermination = { @Sendable _ in
//                self.close()
//            }
//        }
//    }
    
//    public func stream() -> AsyncThrowingStream<Data, Error> {
//        AsyncThrowingStream { continuation in
//            let queue = DispatchQueue.global(qos: .userInteractive)
//            self.read(queue: queue) { isDone, data, error in
//                guard error == 0 else {
//                    continuation.finish(throwing: Errors.read(error))
//                    return
//                }
//                
//                // copy incoming data
//                let count = data?.count ?? 0
//                var resultData = Data(count: count)
//                if count > 0 {
//                    resultData.withUnsafeMutableBytes { buffer in
//                        _ = data?.copyBytes(to: buffer)
//                    }
//                }
//                continuation.yield(resultData)
//                
//                if isDone == true {
//                    continuation.finish()
//                }
//            }
//        }
//    }
}

extension termios: @retroactive Decodable {
    
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let data = try container.decode(Data.self)
        
        guard data.count == MemoryLayout<termios>.size else {
            throw DecodingError.dataCorrupted(DecodingError.Context.init(codingPath: [], debugDescription: "data size should be equal to MemoryLayout<termios>.size, but it's \(data.count) instead"))
        }
        
        self = data.withUnsafeBytes({ $0.load(as: termios.self) })
    }
}

extension termios: @retroactive Encodable {
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        var selfCopy = self
        let rawData = withUnsafeBytes(of: &selfCopy) { Data($0) }
        try container.encode(rawData)
    }
}

extension termios: @retroactive Equatable {
    
    public static func ==(lhs: termios, rhs: termios) -> Bool {
        lhs.c_iflag == rhs.c_iflag &&
        lhs.c_oflag == rhs.c_oflag &&
        lhs.c_cflag == rhs.c_cflag &&
        lhs.c_lflag == rhs.c_lflag &&
        lhs.c_ispeed == rhs.c_ispeed &&
        lhs.c_ospeed == rhs.c_ospeed &&
       
        lhs.c_cc.0 == rhs.c_cc.0 &&
        lhs.c_cc.1 == rhs.c_cc.1 &&
        lhs.c_cc.2 == rhs.c_cc.2 &&
        lhs.c_cc.3 == rhs.c_cc.3 &&
        lhs.c_cc.4 == rhs.c_cc.4 &&
        lhs.c_cc.5 == rhs.c_cc.5 &&
        lhs.c_cc.6 == rhs.c_cc.6 &&
        lhs.c_cc.7 == rhs.c_cc.7 &&
        lhs.c_cc.8 == rhs.c_cc.8 &&
        lhs.c_cc.9 == rhs.c_cc.9 &&
        
        lhs.c_cc.10 == rhs.c_cc.10 &&
        lhs.c_cc.11 == rhs.c_cc.11 &&
        lhs.c_cc.12 == rhs.c_cc.12 &&
        lhs.c_cc.13 == rhs.c_cc.13 &&
        lhs.c_cc.14 == rhs.c_cc.14 &&
        lhs.c_cc.15 == rhs.c_cc.15 &&
        lhs.c_cc.16 == rhs.c_cc.16 &&
        lhs.c_cc.17 == rhs.c_cc.17 &&
        lhs.c_cc.18 == rhs.c_cc.18 &&
        lhs.c_cc.19 == rhs.c_cc.19
    }
}

extension winsize: @retroactive Decodable {
    
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let data = try container.decode(Data.self)
        
        guard data.count == MemoryLayout<winsize>.size else {
            throw DecodingError.dataCorrupted(DecodingError.Context.init(codingPath: [], debugDescription: "data size should be equal to MemoryLayout<winsize>.size, but it's \(data.count) instead"))
        }
        
        self = data.withUnsafeBytes({ $0.load(as: winsize.self) })
    }
}

extension winsize: @retroactive Encodable {
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        var selfCopy = self
        let rawData = withUnsafeBytes(of: &selfCopy) { Data($0) }
        try container.encode(rawData)
    }
}

extension winsize: @retroactive Equatable {
    
    public static func ==(lhs: winsize, rhs: winsize) -> Bool {
        lhs.ws_col == rhs.ws_col &&
        lhs.ws_row == rhs.ws_row &&
        lhs.ws_xpixel == rhs.ws_xpixel &&
        lhs.ws_ypixel == rhs.ws_ypixel
    }
}

//func withCStrings(_ strings: [String], scoped: ([UnsafeMutablePointer<CChar>?]) throws -> Void) rethrows {
//    let cStrings = strings.map { strdup($0) }
//    try scoped(cStrings + [nil])
//    cStrings.forEach { free($0) }
//}

extension FileDescriptor {
    
    public enum Errors: Error {
        case io(Int32)
        case eol(Int32)
    }
    
    public var name: String? {
        guard let namePtr = ttyname(rawValue) else { return nil }
        return String(cString: namePtr)
    }
    
    public var ptsName: String? {
        guard let name = ptsname(rawValue) else { return nil }
        return String(cString: name)
    }
    
//    public func dataWriter(data: Data, queue: DispatchQueue = DispatchQueue.global(qos: .userInteractive)) async throws {
//        try await withCheckedThrowingContinuation { continuation in
//            let writeIO = DispatchIO(type: .stream, fileDescriptor: rawValue, queue: queue) { error in
//                try? close()
//            }
//            
//            let inputDD = data.withUnsafeBytes { DispatchData(bytes: $0) }
//            writeIO.write(offset: 0, data: inputDD, queue: queue) { done, data, error in
//                writeIO.close()
//                if done == true && error == 0 {
//                    continuation.resume()
//                } else {
//                    continuation.resume(throwing: Errors.io(error))
//                }
//            }
//            writeIO.activate()
//        }
//    }
//    
//    public func dataReader(queue: DispatchQueue = DispatchQueue.global(qos: .userInteractive), readBuffer: Int = 8192) -> some AsyncSequence<Data, Error> {
//        
//        AsyncThrowingStream(Data.self) { continuation in
//            
//            let dio = DispatchIO(type: .stream, fileDescriptor: rawValue, queue: queue) { errorCode in
//                // cleanup handler
//                if errorCode == 0 {
//                    continuation.finish()
//                } else {
//                    continuation.finish(throwing: Errors.io(errorCode))
//                }
//            }
//            
//            func readChildProcess(done: Bool, data: DispatchData?, errno: Int32) {
//                
//                guard let data else { return }
//                
//                // TODO: validate exit code
//                guard data.count > 0 else {
//                    continuation.finish(throwing: Errors.eol(errno))
//                    return
//                }
//                
//                // copy incoming data
//                var resultData = Data(count: data.count)
//                resultData.withUnsafeMutableBytes { buffer in
//                    _ = data.copyBytes(to: buffer)
//                }
//                continuation.yield(resultData)
//                
//                //read more bytes?
//                guard done == false else {
//                    continuation.finish()
//                    return
//                }
//                
//                dio.read(offset: 0, length: readBuffer, queue: queue, ioHandler: readChildProcess)
//            }
//            
//            dio.setLimit(lowWater: 1)
//            dio.setLimit(highWater: readBuffer)
//            dio.read(offset: 0, length: readBuffer, queue: queue, ioHandler: readChildProcess)
//            dio.activate()
//            
//            continuation.onTermination = { @Sendable _ in
//                dio.close()
//            }
//        }
//    }
}
