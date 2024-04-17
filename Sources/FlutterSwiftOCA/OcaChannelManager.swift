//
// Copyright (c) 2023-2024 PADL Software Pty Ltd
//
// Licensed under the Apache License, Version 2.0 (the License);
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an 'AS IS' BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import AsyncAlgorithms
import AsyncExtensions
import FlutterSwift
import Foundation
import Logging
@_spi(SwiftOCAPrivate)
import SwiftOCA

public let OcaChannelPrefix = "com.padl.SwiftOCA/"

private extension OcaONo {
    var hexString: String {
        String(format: "%08x", self)
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

private extension FixedWidthInteger {
    var int32Value: Int32? {
        Int32(exactly: self)
    }
}

private extension OcaRoot {
    func propertySubject(with propertyID: OcaPropertyID) -> (any OcaPropertySubjectRepresentable)? {
        for (_, keyPath) in allPropertyKeyPaths {
            if let property =
                self[keyPath: keyPath] as? any OcaPropertySubjectRepresentable,
                property.propertyIDs.contains(propertyID)
            {
                return property
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

private extension FlutterStandardVariant {
    init(ocaValue value: Any) throws {
        if isNil(value) {
            self = .nil
        } else if let value = value as? (any RawRepresentable),
                  let rawValue = value.rawValue as? (any FixedWidthInteger),
                  let int32RawValue = rawValue.int32Value
        {
            self = .int32(int32RawValue)
        } else if let value = value as? Float {
            // no support for 32-bit scalar floats in Flutter
            // TODO: remove this, it's handled by FlutterSwift now
            self = .float64(Double(value))
        } else {
            try self.init(value)
        }
    }

    func ocaValue(_ type: Any.Type) throws -> Any {
        if let type = type as? any CaseIterable.Type,
           case let .int32(int32RawValue) = self,
           let enumValue = type.value(for: int32RawValue)
        {
            return enumValue
        } else if type is Float.Type, case let .float64(float64Value) = self {
            return Float(float64Value)
        } else if self == .nil {
            guard type is ExpressibleByNilLiteral else {
                throw Ocp1Error.status(.parameterError)
            }
            let vnil: Any! = nil
            return vnil as Any
        } else {
            return self
        }
    }
}

@OcaConnection
public final class OcaChannelManager {
    private let connection: Ocp1Connection
    private let binaryMessenger: FlutterBinaryMessenger
    private let logger: Logger

    // method channels
    private let methodChannel: FlutterMethodChannel
    private let getPropertyChannel: FlutterMethodChannel
    private let setPropertyChannel: FlutterMethodChannel

    // event channels
    private let propertyEventChannel: FlutterEventChannel
    private let connectionStateChannel: FlutterEventChannel

    public init(
        connection: Ocp1Connection,
        binaryMessenger: FlutterBinaryMessenger,
        logger: Logger
    ) async throws {
        self.connection = connection
        self.binaryMessenger = binaryMessenger
        self.logger = logger

        methodChannel = FlutterMethodChannel(
            name: "\(OcaChannelPrefix)method",
            binaryMessenger: binaryMessenger
        )
        getPropertyChannel = FlutterMethodChannel(
            name: "\(OcaChannelPrefix)get_property",
            binaryMessenger: binaryMessenger
        )
        setPropertyChannel = FlutterMethodChannel(
            name: "\(OcaChannelPrefix)set_property",
            binaryMessenger: binaryMessenger
        )
        propertyEventChannel = FlutterEventChannel(
            name: "\(OcaChannelPrefix)property_event",
            binaryMessenger: binaryMessenger
        )
        connectionStateChannel = FlutterEventChannel(
            name: "\(OcaChannelPrefix)connection_state",
            binaryMessenger: binaryMessenger
        )

        try await methodChannel.setMethodCallHandler(onMethod)
        try await setPropertyChannel.setMethodCallHandler(onGetProperty)
        try await setPropertyChannel.setMethodCallHandler(onSetProperty)
        try await propertyEventChannel.setStreamHandler(
            onListen: onPropertyEventListen,
            onCancel: onPropertyEventCancel
        )
        try await connectionStateChannel.setStreamHandler(
            onListen: onConnectionStateListen,
            onCancel: onConnectionStateCancel
        )
    }

    private func throwingFlutterError<T>(_ block: () async throws -> T) async throws -> T {
        do {
            return try await block()
        } catch let error as Ocp1Error {
            let flutterError = FlutterError(error: error)
            logger.trace("throwing \(flutterError)")
            throw flutterError
        }
    }

    struct MethodTarget {
        let oNo: OcaONo
        let methodID: OcaMethodID

        init(_ string: String) throws {
            let v = string.split(separator: "/", maxSplits: 2)
            guard v.count == 2 else { throw Ocp1Error.requestParameterOutOfRange }

            guard let oNo = OcaONo(v[0], radix: 16) else {
                throw Ocp1Error.status(.badONo)
            }

            self.oNo = oNo
            methodID = OcaMethodID(String(v[1]))
        }
    }

    private func onMethod(
        call: FlutterMethodCall<[Data]>
    ) async throws -> [UInt8] {
        try await throwingFlutterError {
            let target = try MethodTarget(call.method)

            guard let object = try await connection.resolve(objectOfUnknownClass: target.oNo) else {
                throw Ocp1Error.objectNotPresent
            }

            logger.trace("invoking method \(target)")

            let response = try await object.sendCommandRrq(
                methodID: target.methodID,
                parameterCount: OcaUint8(call.arguments?.count ?? 0),
                parameterData: Data(call.arguments?.flatMap { $0 } ?? [])
            )
            guard response.statusCode == .ok else {
                throw Ocp1Error.status(response.statusCode)
            }
            return [UInt8](response.parameters.parameterData)
        }
    }

    struct PropertyTarget {
        let oNo: OcaONo
        let propertyID: OcaPropertyID

        init(_ string: String) throws {
            let v = string.split(separator: "/", maxSplits: 2)
            guard v.count == 2 else { throw Ocp1Error.requestParameterOutOfRange }

            guard let oNo = OcaONo(v[0], radix: 16) else {
                throw Ocp1Error.status(.badONo)
            }

            self.oNo = oNo
            propertyID = OcaPropertyID(String(v[1]))
        }
    }

    private func onGetProperty(
        call: FlutterMethodCall<FlutterNull>
    ) async throws -> FlutterStandardVariant {
        try await throwingFlutterError {
            let target = try PropertyTarget(call.method)

            guard let object = try await connection.resolve(objectOfUnknownClass: target.oNo) else {
                throw Ocp1Error.objectNotPresent
            }

            guard let property = object.propertySubject(with: target.propertyID) else {
                logger.error("could not locate property \(target.propertyID) on \(object)")
                throw Ocp1Error.status(.processingFailed)
            }

            let value = try await property._getValue(object, flags: [])
            return try FlutterStandardVariant(ocaValue: value)
        }
    }

    private func onSetProperty(
        call: FlutterMethodCall<FlutterStandardVariant>
    ) async throws -> FlutterStandardVariant {
        try await throwingFlutterError {
            let target = try PropertyTarget(call.method)
            let value = call.arguments!

            guard let object = try await connection.resolve(objectOfUnknownClass: target.oNo) else {
                throw Ocp1Error.objectNotPresent
            }

            guard let property = object.propertySubject(with: target.propertyID) else {
                logger.error("could not locate property \(target.propertyID) on \(object)")
                throw Ocp1Error.status(.processingFailed)
            }

            logger
                .trace(
                    "setting property \(target.propertyID) on object \(object) to \(value)"
                )
            try await property._setValue(object, value.ocaValue(property.valueType))
            return FlutterStandardVariant.nil
        }
    }

    @Sendable
    private func onPropertyEventListen(_ target: String?) async throws
        -> FlutterEventStream<FlutterStandardVariant>
    {
        try await throwingFlutterError {
            let target = try PropertyTarget(target!)

            guard let object = try await connection.resolve(objectOfUnknownClass: target.oNo) else {
                throw Ocp1Error.objectNotPresent
            }

            guard let property = object.propertySubject(with: target.propertyID) else {
                logger.error("could not locate property \(target.propertyID) on \(object)")
                throw Ocp1Error.status(.processingFailed)
            }

            await property.subscribe(object)
            logger.trace("subscribed object \(object) property \(target.propertyID)")
            return property.eraseToFlutterEventStream()
        }
    }

    @Sendable
    private func onPropertyEventCancel(_ target: String?) async throws {
        try await throwingFlutterError {
            let target = try PropertyTarget(target!)

            guard let object = try await connection.resolve(objectOfUnknownClass: target.oNo) else {
                throw Ocp1Error.objectNotPresent
            }

            try await object.unsubscribe()
        }
    }

    @Sendable
    private func onConnectionStateListen(_: FlutterStandardVariant?) async throws
        -> FlutterEventStream<String>
    {
        // FIXME: surely there's a better way to express this?
        connection.connectionState.map { String(describing: $0) }.eraseToAnyAsyncSequence()
    }

    @Sendable
    private func onConnectionStateCancel(_: FlutterStandardVariant?) async throws {}
}

extension OcaPropertyRepresentable {
    func eraseToFlutterEventStream()
        -> FlutterEventStream<FlutterStandardVariant>
    {
        async.compactMap {
            guard let value = try? $0.get() else { return .nil }
            return try FlutterStandardVariant(ocaValue: value)
        }.eraseToAnyAsyncSequence()
    }
}

public extension FlutterError {
    init(
        error: Ocp1Error,
        message: String? = nil,
        details: (any Codable)? = nil,
        stacktrace: String? = nil
    ) {
        self.init(
            code: "\(OcaChannelPrefix)" + String(describing: error),
            message: message,
            details: details
        )
    }
}
