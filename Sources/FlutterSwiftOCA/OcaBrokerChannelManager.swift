//
// Copyright (c) 2025 PADL Software Pty Ltd
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
@_spi(FlutterSwiftPrivate)
import FlutterSwift
import Foundation
import Logging
@_spi(SwiftOCAPrivate)
import SwiftOCA

public let OcaBrokerChannelPrefix = "oca-broker/"

public final class OcaBrokerChannelManager: @unchecked Sendable {
  private let broker: OcaConnectionBroker
  private let binaryMessenger: FlutterBinaryMessenger
  private let logger: Logger
  private let flags: OcaChannelManager.Flags

  private let eventChannel: FlutterEventChannel
  private let controlChannel: FlutterMethodChannel
  private let channelManagers =
    ManagedCriticalState<[OcaConnectionBroker.DeviceIdentifier: OcaChannelManager]>([:])

  public init(
    connectionOptions: Ocp1ConnectionOptions,
    binaryMessenger: FlutterBinaryMessenger,
    logger: Logger,
    flags: OcaChannelManager.Flags = [],
    propertyEventChannelBufferSize: Int = 10
  ) async throws {
    broker = OcaConnectionBroker(connectionOptions: connectionOptions)
    self.binaryMessenger = binaryMessenger
    self.logger = logger
    self.flags = flags

    eventChannel = FlutterEventChannel(
      name: "\(OcaBrokerChannelPrefix)events",
      binaryMessenger: binaryMessenger
    )
    controlChannel = FlutterMethodChannel(
      name: "\(OcaBrokerChannelPrefix)control",
      binaryMessenger: binaryMessenger
    )

    try await eventChannel.allowChannelBufferOverflow(true)
    try await eventChannel.resizeChannelBuffer(propertyEventChannelBufferSize)
    try await eventChannel.setStreamHandler(
      onListen: onEventListen,
      onCancel: onEventCancel
    )

    try await controlChannel.setMethodCallHandler(onControl)
  }

  private func onControl(
    call: FlutterMethodCall<String>
  ) async throws -> FlutterNull {
    try await throwingFlutterError {
      guard let deviceIdentifierString = call.arguments,
            let deviceIdentifier = OcaConnectionBroker.DeviceIdentifier(deviceIdentifierString)
      else {
        throw Ocp1Error.status(.badFormat)
      }
      switch call.method {
      case "connect":
        var channelManager: OcaChannelManager?

        try await broker.connect(device: deviceIdentifier)
        try await broker.withDeviceConnection(deviceIdentifier) { connection in
          channelManager = try await OcaChannelManager(
            connection: connection,
            binaryMessenger: binaryMessenger,
            logger: logger,
            flags: flags,
            channelSuffix: String(describing: deviceIdentifier)
          )
        }

        channelManagers.withCriticalRegion { $0[deviceIdentifier] = channelManager }
      case "disconnect":
        channelManagers.withCriticalRegion { $0[deviceIdentifier] = nil }
        try await broker.disconnect(device: deviceIdentifier)
      default:
        break
      }
      return FlutterNull()
    }
  }

  @Sendable
  private func onEventListen(_ target: String?) async throws
    -> FlutterEventStream<AnyFlutterStandardCodable>
  {
    try await throwingFlutterError {
      await broker.events.compactMap { event in
        let eventTypeString: String

        switch event.eventType {
        case .deviceAdded:
          eventTypeString = "added"
        case .deviceRemoved:
          eventTypeString = "removed"
        case .connectionStateChanged:
          return nil
        }

        return try AnyFlutterStandardCodable([eventTypeString, event.deviceIdentifier.id])
      }.eraseToAnyAsyncSequence()
    }
  }

  @Sendable
  private func onEventCancel(_ target: String?) async throws {
    try await throwingFlutterError {}
  }

  private func throwingFlutterError<T>(_ block: () async throws -> T) async throws -> T {
    do {
      return try await block()
    } catch let error as Ocp1Error {
      let flutterError = FlutterError(
        error: error,
        channelPrefix: OcaBrokerChannelPrefix
      )
      logger.trace("throwing \(flutterError)")
      throw flutterError
    }
  }
}
