// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import FlutterSwift
import Foundation

// TODO: remove these when integrated to FlutterSwift

private protocol FlutterListRepresentable: Collection, Codable where Element: Codable {}
extension Array: FlutterListRepresentable where Element: Codable {}

private protocol FlutterMapRepresentable<Key, Value>: Collection, Sendable {
    associatedtype Key: Codable & Hashable & Sendable
    associatedtype Value: Codable & Sendable
}

extension Dictionary: FlutterMapRepresentable where Key: Codable & Hashable, Value: Codable {}

/// protocol to allow third-party classes to opt into being represented as `FlutterStandardVariant`
public protocol FlutterStandardVariantRepresentable {
    init(variant: FlutterStandardVariant) throws
    func bridgeToFlutterStandardVariant() throws -> FlutterStandardVariant
}

/// extension for initializing a type from a type-erased value
public extension FlutterStandardVariant {
    init(_ any: Any) throws {
        if isNil(any) {
            self = .nil
        } else if let bool = any as? Bool {
            self = bool ? .true : .false
        } else if let int32 = any as? Int32 {
            self = .int32(int32)
        } else if let int64 = any as? Int64 {
            self = .int64(int64)
        } else if let float64 = any as? Double {
            self = .float64(float64)
        } else if let string = any as? String {
            self = .string(string)
        } else if let uint8Data = any as? [UInt8] {
            self = .uint8Data(uint8Data)
        } else if let int32Data = any as? [Int32] {
            self = .int32Data(int32Data)
        } else if let int64Data = any as? [Int64] {
            self = .int64Data(int64Data)
        } else if let float32Data = any as? [Float] {
            self = .float32Data(float32Data)
        } else if let float64Data = any as? [Double] {
            self = .float64Data(float64Data)
        } else if let list = any as? [Any] {
            self = .list(try list.map { try FlutterStandardVariant($0) })
        } else if let map = any as? [AnyHashable: Any] {
            self = .map(try map.reduce([:]) {
                var result = $0
                try result[FlutterStandardVariant($1.key)] = FlutterStandardVariant(
                    $1
                        .value
                )
                return result
            })
        } else if let any = any as? FlutterStandardVariantRepresentable {
            self = try any.bridgeToFlutterStandardVariant()
        } else if let raw = any as? (any RawRepresentable) {
            self = try raw.bridgeToFlutterStandardVariant()
        } else if let encodable = any as? Encodable {
            self = try encodable.bridgeToFlutterStandardVariant()
        } else {
            throw FlutterSwiftError.notRepresentableAsVariant
        }
    }
}

/// extensions to allow smaller and unsigned integral types to be represented as variants
extension Int8: FlutterStandardVariantRepresentable {
    public init(variant: FlutterStandardVariant) throws {
        guard case let .int32(int32) = variant else {
            throw FlutterSwiftError.variantNotDecodable
        }
        guard let int8 = Int8(exactly: int32) else {
            throw FlutterSwiftError.notRepresentableAsVariant
        }
        self = int8
    }

    public func bridgeToFlutterStandardVariant() throws -> FlutterStandardVariant {
        .int32(Int32(self))
    }
}

extension Int16: FlutterStandardVariantRepresentable {
    public init(variant: FlutterStandardVariant) throws {
        guard case let .int32(int32) = variant else {
            throw FlutterSwiftError.variantNotDecodable
        }
        guard let int16 = Int16(exactly: int32) else {
            throw FlutterSwiftError.notRepresentableAsVariant
        }
        self = int16
    }

    public func bridgeToFlutterStandardVariant() throws -> FlutterStandardVariant {
        .int32(Int32(self))
    }
}

extension UInt8: FlutterStandardVariantRepresentable {
    public init(variant: FlutterStandardVariant) throws {
        guard case let .int32(int32) = variant else {
            throw FlutterSwiftError.variantNotDecodable
        }
        guard let uint8 = UInt8(exactly: int32) else {
            throw FlutterSwiftError.notRepresentableAsVariant
        }
        self = uint8
    }

    public func bridgeToFlutterStandardVariant() throws -> FlutterStandardVariant {
        .int32(Int32(self))
    }
}

extension UInt16: FlutterStandardVariantRepresentable {
    public init(variant: FlutterStandardVariant) throws {
        guard case let .int32(int32) = variant else {
            throw FlutterSwiftError.variantNotDecodable
        }
        guard let uint16 = UInt16(exactly: int32) else {
            throw FlutterSwiftError.notRepresentableAsVariant
        }
        self = uint16
    }

    public func bridgeToFlutterStandardVariant() throws -> FlutterStandardVariant {
        .int32(Int32(self))
    }
}

extension UInt32: FlutterStandardVariantRepresentable {
    public init(variant: FlutterStandardVariant) throws {
        guard case let .int64(int64) = variant else {
            throw FlutterSwiftError.variantNotDecodable
        }
        guard let uint32 = UInt32(exactly: int64) else {
            throw FlutterSwiftError.notRepresentableAsVariant
        }
        self = uint32
    }

    public func bridgeToFlutterStandardVariant() throws -> FlutterStandardVariant {
        .int64(Int64(self))
    }
}

extension Float: FlutterStandardVariantRepresentable {
    public init(variant: FlutterStandardVariant) throws {
        guard case let .float64(float64) = variant else {
            throw FlutterSwiftError.variantNotDecodable
        }
        self = Float(float64)
    }

    public func bridgeToFlutterStandardVariant() throws -> FlutterStandardVariant {
        .float64(Double(self))
    }
}

extension Data: FlutterStandardVariantRepresentable {
    public init(variant: FlutterStandardVariant) throws {
        guard case let .uint8Data(uint8Data) = variant else {
            throw FlutterSwiftError.variantNotDecodable
        }
        self.init(uint8Data)
    }

    public func bridgeToFlutterStandardVariant() throws -> FlutterStandardVariant {
        .uint8Data([UInt8](self))
    }
}

private extension FixedWidthInteger {
    var _int32Value: Int32? {
        Int32(exactly: self)
    }
}

extension RawRepresentable {
    func bridgeToFlutterStandardVariant() throws -> FlutterStandardVariant {
        guard let rawValue = rawValue as? (any FixedWidthInteger),
              let rawValue = rawValue._int32Value
        else {
            throw FlutterSwiftError.notRepresentableAsVariant
        }
        return .int32(rawValue)
    }
}

private extension CaseIterable {
    static func value(for aRawValue: Int32) -> Any? {
        guard self is any RawRepresentable.Type else {
            return nil
        }

        for aCase in Self.allCases {
            let rawValue = (aCase as! any RawRepresentable).rawValue
            guard let rawValue = rawValue as? any FixedWidthInteger else {
                return nil
            }
            guard let rawValue = Int32(exactly: rawValue) else {
                continue
            }
            if rawValue == aRawValue {
                return aCase
            }
        }
        return nil
    }
}

private func isNil(_ value: Any) -> Bool {
    if let value = value as? ExpressibleByNilLiteral {
        let value = value as Any?
        if case .none = value {
            return true
        }
    }
    return false
}

public extension FlutterStandardVariant {
    func value(as type: Any.Type? = nil) throws -> Any {
        if let type = type as? FlutterStandardVariantRepresentable.Type {
            do {
                return try type.init(variant: self)
            } catch {}
        }

        switch self {
        case .nil:
            if type is ExpressibleByNilLiteral.Type {
                let vnil: Any! = nil
                return vnil as Any
            }
        case .true:
            fallthrough
        case .false:
            guard type is Bool.Type else { throw FlutterSwiftError.variantNotDecodable }
            return self == .true
        case let .int32(int32):
            if let type = type as? any CaseIterable.Type {
                return try type.bridgeFromFlutterStandardVariant(self) as Any
            } else if type is Int32.Type {
                return int32
            }
        case let .int64(int64):
            if type is Int64.Type { return int64 }
        case let .float64(float64):
            if type is Double.Type { return float64 }
        case let .string(string):
            if type is String.Type { return string }
        case let .uint8Data(uint8Data):
            if type is [UInt8].Type { return uint8Data }
        case let .int32Data(int32Data):
            if type is [Int32].Type { return int32Data }
        case let .int64Data(int64Data):
            if type is [Int64].Type { return int64Data }
        case let .float32Data(float32Data):
            if type is [Float].Type { return float32Data }
        case let .float64Data(float64Data):
            if type is [Double].Type { return float64Data }
        case let .list(list):
            if type is any FlutterListRepresentable.Type {
                return try list.map { try $0.value() }
            } else if let type = type as? Decodable.Type {
                return try bridgeFromFlutterStandardVariant(to: type)
            }
        case let .map(map):
            if type is any FlutterMapRepresentable.Type {
                return try map.reduce([:]) {
                    var result = $0
                    if let key = try $1.key.value() as? any Hashable {
                        result[AnyHashable(key)] = try? $1.value.value()
                    }
                    return result
                }
            } else if let type = type as? Decodable.Type {
                return try bridgeFromFlutterStandardVariant(to: type)
            }
        }

        throw FlutterSwiftError.variantNotDecodable
    }
}

private extension CaseIterable {
    static func bridgeFromFlutterStandardVariant(_ variant: FlutterStandardVariant) throws -> Self {
        guard case let .int32(int32) = variant else {
            throw FlutterSwiftError.notRepresentableAsVariant
        }
        return Self.value(for: int32) as! Self
    }
}

extension FlutterStandardVariant {
    func bridgeFromFlutterStandardVariant<T: Decodable>(to type: T.Type) throws -> T {
        let jsonEncodedValue = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: jsonEncodedValue)
    }
}

extension Encodable {
    func bridgeToFlutterStandardVariant() throws -> FlutterStandardVariant {
        let jsonEncodedValue = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(FlutterStandardVariant.self, from: jsonEncodedValue)
    }
}
