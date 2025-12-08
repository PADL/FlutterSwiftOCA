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

public protocol OcaBrokerChannelManagerDelegate: AnyObject, Sendable {}

public final class OcaBrokerChannelManager: Sendable {
  private let broker: OcaConnectionBroker
  private let binaryMessenger: FlutterBinaryMessenger
  private let logger: Logger
  private let flags: OcaChannelManager.Flags

  private let eventChannel: FlutterEventChannel
  private let controlChannel: FlutterMethodChannel
  private let channelManagers =
    ManagedCriticalState<[OcaConnectionBroker.DeviceIdentifier: OcaChannelManager]>([:])

  public typealias OnConnectionCallback = @Sendable (
    OcaConnectionBroker.DeviceIdentifier,
    Ocp1Connection
  ) async throws -> ()

  private let onConnectionCallback: OnConnectionCallback?

  @FlutterPlatformThreadActor
  public init(
    connectionOptions: Ocp1ConnectionOptions,
    binaryMessenger: FlutterBinaryMessenger,
    logger: Logger,
    flags: OcaChannelManager.Flags = [],
    propertyEventChannelBufferSize: Int = 10,
    onConnectionCallback: OnConnectionCallback? = nil
  ) async throws {
    broker = await OcaConnectionBroker(connectionOptions: connectionOptions)
    self.binaryMessenger = binaryMessenger
    self.logger = logger
    self.flags = flags
    self.onConnectionCallback = onConnectionCallback

    eventChannel = FlutterEventChannel(
      name: "\(OcaBrokerChannelPrefix)events",
      binaryMessenger: binaryMessenger
    )
    controlChannel = FlutterMethodChannel(
      name: "\(OcaBrokerChannelPrefix)control",
      binaryMessenger: binaryMessenger
    )

    try eventChannel.setStreamHandler(
      onListen: onEventListen,
      onCancel: onEventCancel
    )

    try eventChannel.allowChannelBufferOverflow(true)
    try controlChannel.setMethodCallHandler(onControl)
  }

  @Sendable @FlutterPlatformThreadActor
  private func onControl(
    call: FlutterMethodCall<String>
  ) async throws -> [String] {
    try await throwingFlutterError {
      guard let deviceIdentifierString = call.arguments,
            let deviceIdentifier = OcaConnectionBroker.DeviceIdentifier(deviceIdentifierString)
      else {
        throw Ocp1Error.status(.badFormat)
      }
      switch call.method {
      case "connect":
        try await broker.connect(device: deviceIdentifier)
        let connection = try await broker.withDeviceConnection(deviceIdentifier) { connection in
          try await onConnectionCallback?(deviceIdentifier, connection)
          return connection
        }

        let channelManager = try await FlutterPlatformThreadActor.run {
          try OcaChannelManager(
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
      case "list":
        return await broker.registeredDevices.map { String(describing: $0) }
      default:
        break
      }
      return []
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

        return try AnyFlutterStandardCodable([
          eventTypeString,
          event.deviceIdentifier.id,
          event.deviceIdentifier.name,
        ])
      }.eraseToAnyAsyncSequence()
    }
  }

  @Sendable
  private func onEventCancel(_ target: String?) async throws {
    try await throwingFlutterError {}
  }

  private func throwingFlutterError<T>(_ block: @Sendable () async throws -> T) async throws -> T {
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
