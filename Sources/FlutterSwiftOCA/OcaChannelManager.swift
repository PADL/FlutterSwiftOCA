//
// Copyright (c) 2023 PADL Software Pty Ltd
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

import AnyCodable
import AsyncAlgorithms
import AsyncExtensions
import FlutterSwift
import Foundation
import SwiftOCA

public actor OcaChannelManager {
    public typealias Event = OcaPropertyChangedEventData<AnyCodable>

    public static let OcaControlChannelSuffix = "control"
    public static let OcaEventChannelSuffix = "event"
    public static let OcaMethodChannelSuffix = "method"

    public static let MissingObjectNumberError =
        "com.padl.OcaChannelManager.MissingObjectNumberError"
    public static let NoSuchObjectError = "com.padl.OcaChannelManager.NoSuchObjectError"
    public static let MissingPropertiesError = "com.padl.OcaChannelManager.MissingPropertiesError"
    public static let DeviceError = "com.padl.OcaChannelManaegr.DeviceError"
    public static let UnknownControlMethodError =
        "com.padl.OcaChannelManager.UnknownControlMethodError"

    private let connection: AES70OCP1Connection
    private let binaryMessenger: FlutterBinaryMessenger
    private let controlChannel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel
    private var methodChannels = [OcaONo: FlutterMethodChannel]()

    init(
        connection: AES70OCP1Connection,
        binaryMessenger: FlutterBinaryMessenger
    ) async throws {
        self.connection = connection
        self.binaryMessenger = binaryMessenger

        controlChannel = FlutterMethodChannel(
            name: "\(connection.connectionPrefix)/\(Self.OcaControlChannelSuffix)",
            binaryMessenger: binaryMessenger
        )
        eventChannel = FlutterEventChannel(
            name: "\(connection.connectionPrefix)/\(Self.OcaEventChannelSuffix)",
            binaryMessenger: binaryMessenger
        )

        try await controlChannel.setMethodCallHandler(onControl)
        try await eventChannel.setStreamHandler(onListen: onEventListen, onCancel: onEventCancel)

        try await connection.connect()
    }

    deinit {
        Task {
            try? await connection.disconnect()
        }
    }

    func onControl(
        call: FlutterMethodCall<OcaObjectIdentification>
    ) async throws -> Bool? {
        switch call.method {
        case "resolve":
            var objectIdentification = call.arguments

            if objectIdentification == nil {
                objectIdentification = await connection.rootBlock.objectIdentification
            }
            return await connection.resolve(object: objectIdentification!) != nil
        default:
            throw FlutterError(code: Self.UnknownControlMethodError, details: call.method)
        }
    }

    func onEventListen(_ oNo: OcaONo?) async throws -> FlutterEventStream<Event> {
        guard let oNo else {
            throw FlutterError(code: Self.MissingObjectNumberError)
        }

        guard let object = await connection.resolve(cachedObject: oNo) else {
            throw FlutterError(code: Self.NoSuchObjectError, details: oNo)
        }

        var mergedPropertyEventStream: FlutterEventStream<Event>?

        for (_, keyPath) in object.allPropertyKeyPaths {
            guard let property = object[keyPath: keyPath] as? any OcaPropertyRepresentable else {
                continue
            }
            let propertyEventStream = property.eraseToAnyAsyncSequenceOfPropertyChangedEventData()
            if mergedPropertyEventStream == nil {
                mergedPropertyEventStream = propertyEventStream
            } else {
                mergedPropertyEventStream = AsyncMerge2Sequence(
                    mergedPropertyEventStream!,
                    propertyEventStream
                )
                .eraseToAnyAsyncSequence()
            }
        }

        guard let mergedPropertyEventStream else {
            throw FlutterError(code: Self.MissingPropertiesError)
        }

        return mergedPropertyEventStream
    }

    func onEventCancel(_ oNo: OcaONo?) async throws {}

    func onMethodCall(
        oNo: OcaONo,
        call: FlutterMethodCall<Ocp1Parameters>
    ) async throws -> Ocp1Response {
        do {
            guard let object = await connection.resolve(cachedObject: oNo) else {
                throw FlutterError(code: Self.NoSuchObjectError, details: oNo)
            }
            return try await object.sendCommandRrq(
                methodID: OcaMethodID(call.method),
                parameterCount: call.arguments?
                    .parameterCount ?? 0,
                parameterData: call.arguments?
                    .parameterData ?? Data()
            )
        } catch let error as Ocp1Error {
            throw FlutterError(code: Self.DeviceError, details: String(describing: error))
        }
    }

    func registerMethodChannel(oNo: OcaONo) async throws {
        let methodChannel = FlutterMethodChannel(
            name: "\(connection.connectionPrefix)/\(oNo)/\(Self.OcaMethodChannelSuffix)",
            binaryMessenger: binaryMessenger
        )
        try await methodChannel.setMethodCallHandler { call in
            try await self.onMethodCall(oNo: oNo, call: call)
        }
        methodChannels[oNo] = methodChannel
    }
}

extension OcaPropertyRepresentable {
    func eraseToAnyAsyncSequenceOfPropertyChangedEventData()
        -> AnyAsyncSequence<OcaPropertyChangedEventData<AnyCodable>?>
    {
        subject.map {
            OcaPropertyChangedEventData<AnyCodable>(
                propertyID: propertyIDs.first!, // FIXME: doesn't work with multiple propertyIDs
                propertyValue: AnyCodable($0),
                changeType: .currentChanged
            )
        }.eraseToAnyAsyncSequence()
    }
}
