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

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif
import AsyncAlgorithms
import AsyncExtensions
@_spi(FlutterSwiftPrivate)
import FlutterSwift
import Foundation
import Logging
import SocketAddress
import Synchronization
@_spi(SwiftOCAPrivate)
import SwiftOCA

public let OcaBrokerChannelPrefix = "oca-broker/"

public protocol OcaBrokerChannelManagerDelegate: AnyObject, Sendable {}

/// Bridges SwiftOCA's DNS-SD device discovery to Dart.
///
/// Each discovered device is reported with a URL, so that Dart can connect to
/// it itself. Connecting through the broker, with the `connect` control method,
/// remains available.
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
  private let lifecycleGeneration = Atomic<UInt64>(0)

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

  /// Creates a broker for browsing only, for callers that connect to devices
  /// themselves using the URL reported with each device.
  ///
  /// Connecting through the broker remains available, with default connection
  /// options, no flags and no connection callback, but such callers need not
  /// use it.
  ///
  /// - Parameters:
  ///   - serviceTypes: the advertised service types to browse, or `nil` to browse all of them.
  ///   - deviceModels: restricts discovery to devices advertising one of these model GUIDs, or
  ///     `nil` to surface every device on the network.
  @FlutterPlatformThreadActor
  public convenience init(
    binaryMessenger: FlutterBinaryMessenger,
    logger: Logger,
    serviceTypes: Set<OcaNetworkAdvertisingServiceType>? = nil,
    deviceModels: [OcaModelGUID]? = nil
  ) async throws {
    try await self.init(
      connectionOptions: Ocp1ConnectionOptions(),
      binaryMessenger: binaryMessenger,
      logger: logger,
      flags: [],
      serviceTypes: serviceTypes,
      deviceModels: deviceModels,
      onConnectionCallback: nil
    )
  }

  /// Distinguishes successive suspend/resume transitions: both walk their
  /// devices an await at a time, so a quick bounce can interleave them.
  private func _beginLifecycleTransition() -> UInt64 {
    lifecycleGeneration.wrappingAdd(1, ordering: .relaxed).newValue
  }

  private func _isCurrentLifecycleTransition(_ generation: UInt64) -> Bool {
    lifecycleGeneration.load(ordering: .relaxed) == generation
  }

  /// Disconnects every connected device, remembering them for ``resume()``.
  ///
  /// For app suspension: mobile platforms expect network resources to be
  /// released while the app is not in use. Channel managers are left registered
  /// so that Dart's bindings survive the cycle.
  public func suspend() async {
    let generation = _beginLifecycleTransition()
    let devices = channelManagers.withLock { Array($0.keys) }
    guard !devices.isEmpty else { return }

    // Recorded before disconnecting: a resume() arriving mid-loop would
    // otherwise find nothing to restore and leave the devices down.
    suspendedDevices.withLock { $0 = devices }

    for device in devices {
      guard _isCurrentLifecycleTransition(generation) else { return }
      try? await broker.disconnect(device: device)
    }
    logger.debug("suspended \(devices.count) device(s)")
  }

  /// Reconnects whatever ``suspend()`` disconnected.
  ///
  /// The connection's own `refreshSubscriptionsOnReconnection` is what restores
  /// event subscriptions -- including metering -- so nothing is re-subscribed
  /// by hand here.
  public func resume() async {
    let generation = _beginLifecycleTransition()
    let devices = suspendedDevices.withLock { devices -> [OcaConnectionBroker.DeviceIdentifier] in
      defer { devices = [] }
      return devices
    }

    for device in devices {
      guard _isCurrentLifecycleTransition(generation) else { return }
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
        // open() registers the connection without connecting it, so that the
        // channels below — and Flutter's subscription to them — are in place
        // first. The connection state stream carries transitions only, so a
        // connection that completes before Flutter has subscribed is never
        // reported to it.
        try await broker.open(device: deviceIdentifier)
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
        try await broker.connect(device: deviceIdentifier)

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
        throw FlutterSwiftError.methodNotImplemented
      }
      return []
    }
  }

  @Sendable
  private func onEventListen(_ target: String?) async throws
    -> FlutterEventStream<AnyFlutterStandardCodable>
  {
    try await throwingFlutterError {
      let broker = broker
      return await broker.events.compactMap { event in
        let device = event.deviceIdentifier
        let eventTypeString: String
        let url: String?

        switch event.eventType {
        case .deviceAdded:
          eventTypeString = "added"
          url = await Self.deviceURL(for: device, broker: broker)
        case .deviceUpdated:
          eventTypeString = "updated"
          url = await Self.deviceURL(for: device, broker: broker)
        case .deviceRemoved:
          eventTypeString = "removed"
          url = nil
        case .connectionStateChanged:
          return nil
        }

        var fields = [eventTypeString, device.id, device.name]
        if let url { fields.append(url) }
        return try AnyFlutterStandardCodable(fields)
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

// MARK: - Device URLs

extension OcaBrokerChannelManager {
  /// The URL Dart connects to `device` with, or `nil` if the broker no longer
  /// has its service info (it may have gone away since the event was emitted)
  /// or cannot describe its transport as a URL.
  private static func deviceURL(
    for device: OcaConnectionBroker.DeviceIdentifier,
    broker: OcaConnectionBroker
  ) async -> String? {
    guard let serviceInfo = try? await broker.serviceInfo(for: device),
          let port = try? serviceInfo.port
    else {
      return nil
    }

    return deviceURL(
      serviceType: serviceInfo.serviceType,
      addresses: (try? await broker.deviceAddresses(for: device)) ?? [],
      hostname: try? serviceInfo.hostname,
      port: port,
      txtRecords: (try? serviceInfo.txtRecords) ?? [:]
    )
  }

  /// Builds a device URL from resolved DNS-SD service info.
  ///
  /// The host is the first usable address, in the broker's order (IPv4 before
  /// IPv6), so that Dart need not resolve a `.local` name itself. Link-local
  /// IPv6 addresses are skipped, as a URL carries no zone to scope them with.
  /// Failing an address, the advertised hostname is used.
  ///
  /// Only OCP.1 and OCP.2 over TCP and WebSocket have a URL scheme; any other
  /// service type returns `nil`.
  static func deviceURL(
    serviceType: OcaNetworkAdvertisingServiceType,
    addresses: [Data],
    hostname: String?,
    port: UInt16,
    txtRecords: [String: String]
  ) -> String? {
    let scheme: String
    var path = ""

    switch serviceType {
    case .tcp:
      scheme = "ocp1+tcp"
    case .tcpJson:
      scheme = "ocp2+tcp"
    case .tcpWebSocket:
      scheme = "ocp1+ws"
      path = webSocketPath(txtRecords: txtRecords)
    case .tcpWebSocketJson:
      scheme = "ocp2+ws"
      path = webSocketPath(txtRecords: txtRecords)
    default:
      return nil
    }

    let hostname = hostname.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
    guard let host = addresses.lazy.compactMap(urlHost(sockaddr:)).first ?? hostname,
          !host.isEmpty
    else {
      return nil
    }

    return "\(scheme)://\(host):\(port)\(path)"
  }

  /// The `path` TXT record, which defaults to `/` and always starts with one.
  private static func webSocketPath(txtRecords: [String: String]) -> String {
    guard let path = txtRecords["path"], !path.isEmpty else { return "/" }
    return path.hasPrefix("/") ? path : "/\(path)"
  }

  /// A numeric URL host for a `sockaddr`, with IPv6 in brackets; `nil` for a
  /// link-local IPv6 address or anything that is not IPv4 or IPv6.
  private static func urlHost(sockaddr bytes: Data) -> String? {
    guard let address = try? AnySocketAddress(bytes: Array(bytes)),
          let host = try? address.presentationAddressNoPort
    else {
      return nil
    }

    switch Int32(address.family) {
    case AF_INET:
      return host
    case AF_INET6:
      let isLinkLocal = address.withSockAddr { sa, size in
        guard Int(size) >= MemoryLayout<sockaddr_in6>.size else { return true }
        let sin6 = UnsafeRawPointer(sa).loadUnaligned(as: sockaddr_in6.self)
        return withUnsafeBytes(of: sin6.sin6_addr) { $0[0] == 0xFE && ($0[1] & 0xC0) == 0x80 }
      }
      return isLinkLocal ? nil : "[\(host)]"
    default:
      return nil
    }
  }
}

#endif
