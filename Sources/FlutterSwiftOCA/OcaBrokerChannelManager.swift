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

// NB: must match the availability of OcaConnectionBroker in SwiftOCA, which
// now includes Android via NsdManager.
#if canImport(Darwin) || canImport(dnssd) || os(Android)

import AsyncAlgorithms
import AsyncExtensions
@_spi(FlutterSwiftPrivate)
import FlutterSwift
import Foundation
import Logging
import Synchronization
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
    Mutex<[OcaConnectionBroker.DeviceIdentifier: OcaChannelManager]>([:])
  /// Devices disconnected by `suspend`, to be reconnected by `resume`.
  ///
  /// Their `OcaChannelManager`s are deliberately left in place: Dart keeps its
  /// bindings across the cycle, and disposing them would tear down the channels
  /// the UI is still holding.
  private let suspendedDevices = Mutex<[OcaConnectionBroker.DeviceIdentifier]>([])

  public typealias OnConnectionCallback = @Sendable (
    OcaConnectionBroker.DeviceIdentifier,
    Ocp1Connection
  ) async throws -> ()

  private let onConnectionCallback: OnConnectionCallback?
  private let propertyEventChannelBufferSize: Int
  private let identificationSensorONo: OcaONo

  /// - Parameters:
  ///   - serviceTypes: the advertised service types to browse, or `nil` to browse all of them.
  ///   - deviceModels: restricts discovery to devices advertising one of these model GUIDs, or
  ///     `nil` to surface every device on the network. Applications that only know how to talk to
  ///     their own hardware should pass their model GUID here, so that foreign devices are never
  ///     forwarded to Dart.
  ///   - identificationSensorONo: forwarded to the per-device ``OcaChannelManager`` created on
  ///     connection, so that a device reached through the browser supports identification just as
  ///     one connected directly does.
  @FlutterPlatformThreadActor
  public init(
    connectionOptions: Ocp1ConnectionOptions,
    binaryMessenger: FlutterBinaryMessenger,
    logger: Logger,
    flags: OcaChannelManager.Flags = [],
    propertyEventChannelBufferSize: Int = 10,
    identificationSensorONo: OcaONo = OcaInvalidONo,
    serviceTypes: Set<OcaNetworkAdvertisingServiceType>? = nil,
    deviceModels: [OcaModelGUID]? = nil,
    onConnectionCallback: OnConnectionCallback? = nil
  ) async throws {
    self.propertyEventChannelBufferSize = propertyEventChannelBufferSize
    self.identificationSensorONo = identificationSensorONo
    broker = await OcaConnectionBroker(
      connectionOptions: connectionOptions,
      serviceTypes: serviceTypes,
      deviceModels: deviceModels
    )
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

  /// Disconnects every connected device, remembering them for ``resume()``.
  ///
  /// For app suspension: mobile platforms expect network resources to be
  /// released while the app is not in use. Channel managers are left registered
  /// so that Dart's bindings survive the cycle.
  public func suspend() async {
    let devices = channelManagers.withLock { Array($0.keys) }
    guard !devices.isEmpty else { return }

    for device in devices {
      try? await broker.disconnect(device: device)
    }
    suspendedDevices.withLock { $0 = devices }
    logger.debug("suspended \(devices.count) device(s)")
  }

  /// Reconnects whatever ``suspend()`` disconnected.
  ///
  /// The connection's own `refreshSubscriptionsOnReconnection` is what restores
  /// event subscriptions -- including metering -- so nothing is re-subscribed
  /// by hand here.
  public func resume() async {
    let devices = suspendedDevices.withLock { devices -> [OcaConnectionBroker.DeviceIdentifier] in
      defer { devices = [] }
      return devices
    }

    for device in devices {
      do {
        try await broker.connect(device: device)
        try await broker.withDeviceConnection(device) { connection in
          try await onConnectionCallback?(device, connection)
        }
      } catch {
        // A device that went away while suspended is not an error: the browser
        // will report it again if it comes back.
        logger.info("failed to resume \(device): \(error)")
      }
    }
  }

  @Sendable @FlutterPlatformThreadActor
  private func onControl(
    call: FlutterMethodCall<String>
  ) async throws -> [String] {
    try await throwingFlutterError {
      switch call.method {
        
      case "connect":
        guard let deviceIdentifierString = call.arguments,
              let deviceIdentifier = OcaConnectionBroker.DeviceIdentifier(deviceIdentifierString)
        else {
          throw Ocp1Error.status(.badFormat)
        }
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
            propertyEventChannelBufferSize: propertyEventChannelBufferSize,
            channelSuffix: String(describing: deviceIdentifier),
            identificationSensorONo: identificationSensorONo
          )
        }
        channelManagers.withLock { $0[deviceIdentifier] = channelManager }
        
      case "disconnect":
        guard let deviceIdentifierString = call.arguments,
              let deviceIdentifier = OcaConnectionBroker.DeviceIdentifier(deviceIdentifierString)
        else {
          throw Ocp1Error.status(.badFormat)
        }
        let channelManager = channelManagers.withLock { channelManagers in
          let manager = channelManagers[deviceIdentifier]
          channelManagers[deviceIdentifier] = nil
          return manager
        }
        try await FlutterPlatformThreadActor.run {
          try channelManager?.dispose()
        }
        try await broker.disconnect(device: deviceIdentifier)
        
      case "list":
        await broker.reenumerateRegisteredDevices()
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
        case .deviceUpdated:
          eventTypeString = "updated"
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

#endif
