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
@preconcurrency import AsyncExtensions
@_spi(FlutterSwiftPrivate)
import FlutterSwift
import Foundation
import Logging
@_spi(SwiftOCAPrivate)
import SwiftOCA

public let OcaChannelPrefix = "oca/"
public let OcaPlatformStateReadyMethodName = "platform_ready"

private let OcaMeteringSubscriptionLabel = "com.padl.FlutterSwiftOCA.metering"

private extension OcaONo {
  var oNoString: String {
    "<\(String(self, radix: 16))>"
  }
}

private extension OcaRoot {
  func propertySubject(for propertyID: OcaPropertyID) async
    -> (any OcaPropertySubjectRepresentable)?
  {
    guard let keyPath = await propertyKeyPath(for: propertyID) else { return nil }
    return self[keyPath: keyPath] as! any OcaPropertySubjectRepresentable
  }
}

public final class OcaChannelManager: @unchecked
Sendable {
  private let connection: Ocp1Connection
  private let binaryMessenger: FlutterBinaryMessenger
  private let logger: Logger
  private let flags: Flags
  private let channelSuffix: String?

  // method channels
  private let methodChannel: FlutterMethodChannel
  private let getPropertyChannel: FlutterMethodChannel
  private let setPropertyChannel: FlutterMethodChannel
  private let sampleRateChannel: FlutterMethodChannel
  private let datasetChannel: FlutterMethodChannel // storing param datasets in a remote slot
  private let datasetBlobChannel: FlutterMethodChannel // fetching param datasets as a blob
  private let platformStateChannel: FlutterMethodChannel // report platform channel status

  // event channels
  private let propertyEventChannel: FlutterEventChannel
  private let meteringEventChannel: FlutterEventChannel
  private let connectionStateChannel: FlutterEventChannel

  private let identificationSensorONo: OcaONo // optional object ID of identification sensor
  private let identifyEventChannel: FlutterEventChannel // report identify events

  private final class MeteringEventSubscription: Hashable, Sendable {
    static func == (
      lhs: OcaChannelManager.MeteringEventSubscription,
      rhs: OcaChannelManager.MeteringEventSubscription
    ) -> Bool {
      lhs.cancellable == rhs.cancellable
    }

    typealias Continuation = AsyncStream<AnyFlutterStandardCodable?>.Continuation

    let cancellable: Ocp1Connection.SubscriptionCancellable
    let continuation: Continuation

    func hash(into hasher: inout Hasher) {
      cancellable.hash(into: &hasher)
    }

    init(
      cancellable: Ocp1Connection.SubscriptionCancellable,
      continuation: Continuation
    ) {
      self.cancellable = cancellable
      self.continuation = continuation
    }
  }

  private struct EventSubscriptions {
    var eventSubscriptionRefs = [OcaONo: Int]()
    var meteringSubscriptions = [PropertyTarget: MeteringEventSubscription]()
  }

  private let subscriptions: ManagedCriticalState<EventSubscriptions>

  private static func _makeChannelPrefix(with channelSuffix: String?) -> String {
    if let channelSuffix {
      return OcaChannelPrefix + channelSuffix + "/"
    } else {
      return OcaChannelPrefix
    }
  }

  public struct Flags: OptionSet, Sendable {
    public typealias RawValue = UInt

    public let rawValue: RawValue

    public init(rawValue: RawValue) {
      self.rawValue = rawValue
    }

    public static let persistSubscriptions = Flags(rawValue: 1 << 0)
  }

  @FlutterPlatformThreadActor
  public init(
    connection: Ocp1Connection,
    binaryMessenger: FlutterBinaryMessenger,
    logger: Logger,
    flags: Flags = [],
    propertyEventChannelBufferSize: Int = 10,
    channelSuffix: String? = nil,
    identificationSensorONo: OcaONo = OcaInvalidONo
  ) throws {
    self.connection = connection
    self.binaryMessenger = binaryMessenger
    self.logger = logger
    self.flags = flags
    self.channelSuffix = channelSuffix
    subscriptions = ManagedCriticalState(EventSubscriptions())
    let channelPrefix = Self._makeChannelPrefix(with: channelSuffix)

    methodChannel = FlutterMethodChannel(
      name: "\(channelPrefix)method",
      binaryMessenger: binaryMessenger
    )
    getPropertyChannel = FlutterMethodChannel(
      name: "\(channelPrefix)get_property",
      binaryMessenger: binaryMessenger
    )
    setPropertyChannel = FlutterMethodChannel(
      name: "\(channelPrefix)set_property",
      binaryMessenger: binaryMessenger
    )
    sampleRateChannel = FlutterMethodChannel(
      name: "\(channelPrefix)sample_rate",
      binaryMessenger: binaryMessenger
    )
    datasetBlobChannel = FlutterMethodChannel(
      name: "\(OcaChannelPrefix)dataset_blob",
      binaryMessenger: binaryMessenger
    )
    datasetChannel = FlutterMethodChannel(
      name: "\(OcaChannelPrefix)dataset",
      binaryMessenger: binaryMessenger
    )
    platformStateChannel = FlutterMethodChannel(
      name: "\(channelPrefix)platform_state",
      binaryMessenger: binaryMessenger
    )
    propertyEventChannel = FlutterEventChannel(
      name: "\(channelPrefix)property_event",
      binaryMessenger: binaryMessenger
    )
    meteringEventChannel = FlutterEventChannel(
      name: "\(channelPrefix)metering_event",
      binaryMessenger: binaryMessenger
    )
    connectionStateChannel = FlutterEventChannel(
      name: "\(channelPrefix)connection_state",
      binaryMessenger: binaryMessenger
    )

    self.identificationSensorONo = identificationSensorONo
    identifyEventChannel = FlutterEventChannel(
      name: "\(OcaChannelPrefix)identify",
      binaryMessenger: binaryMessenger
    )

    try methodChannel.setMethodCallHandler(onMethod)
    try getPropertyChannel.setMethodCallHandler(onGetProperty)
    try setPropertyChannel.setMethodCallHandler(onSetProperty)
    try sampleRateChannel.setMethodCallHandler(onSampleRate)
    try datasetChannel.setMethodCallHandler(onDataset)
    try datasetBlobChannel.setMethodCallHandler(onDatasetBlob)

    try propertyEventChannel.setStreamHandler(
      onListen: onPropertyEventListen,
      onCancel: onPropertyEventCancel
    )
    try meteringEventChannel.setStreamHandler(
      onListen: onMeteringEventListen,
      onCancel: onMeteringEventCancel
    )
    try connectionStateChannel.setStreamHandler(
      onListen: onConnectionStateListen,
      onCancel: onConnectionStateCancel
    )
    try identifyEventChannel.setStreamHandler(
      onListen: onIdentifyEventListen,
      onCancel: onIdentifyEventCancel
    )

    try propertyEventChannel.allowChannelBufferOverflow(true)
    try propertyEventChannel.resizeChannelBuffer(propertyEventChannelBufferSize)
    try meteringEventChannel.allowChannelBufferOverflow(true)
    try connectionStateChannel.allowChannelBufferOverflow(true)

    logger.trace("OCA platform channels ready (\(channelSuffix ?? "no suffix"))")

    Task {
      // let Flutter code know it is safe to subsribe to the channels above
      try await platformStateChannel.invoke(
        method: OcaPlatformStateReadyMethodName,
        arguments: true
      )
    }
  }

  public func connect() async throws {
    try await connection.connect()
  }

  private func throwingFlutterError<T>(_ block: () async throws -> T) async throws -> T {
    do {
      return try await block()
    } catch let error as Ocp1Error {
      let flutterError = FlutterError(
        error: error,
        channelPrefix: Self._makeChannelPrefix(with: channelSuffix)
      )
      logger.trace("throwing \(flutterError)")
      throw flutterError
    }
  }

  // we allow objects of both known and unknown class to be addressed over channels
  private enum ObjectIdentification: CustomStringConvertible {
    /// object number in hex with no leading 0x
    case oNo(OcaONo)
    /// class ID, version, oNo, e.g. ` 1.2.3@3:01234567`
    case objectIdentification(OcaObjectIdentification)

    private static func _parseObjectIDString(_ string: String)
      -> (Substring, Substring?, Substring?)
    {
      let v = string.split(separator: ":", maxSplits: 2)
      guard v.count > 1 else { return (v[0], nil, nil) } // objectNumber
      let w = v[0].split(separator: "@", maxSplits: 2)
      if w.count > 1 {
        return (v[1], w[0], w[1]) // objectNumber, objectClass, classVersion
      } else {
        return (v[1], w[0], nil) // objectNumber, objectClass
      }
    }

    init(_ string: String) throws {
      let parsedString = Self._parseObjectIDString(string)

      guard let oNo = OcaONo(parsedString.0, radix: 16), oNo != OcaInvalidONo else {
        throw Ocp1Error.status(.badONo)
      }

      if let classIdentificationString = parsedString.1 {
        var classVersionNumber: OcaClassVersionNumber

        if let classVersionString = parsedString.2 {
          guard let _classVersionNumber = OcaUint16(classVersionString),
                _classVersionNumber <= OcaProtocolVersion.aes70_2023.rawValue
          else {
            throw Ocp1Error.status(.parameterOutOfRange)
          }
          classVersionNumber = _classVersionNumber
        } else {
          classVersionNumber = OcaProtocolVersion.aes70_2023.rawValue
        }

        let classID = try OcaClassIdentification(
          classID: OcaClassID(unsafeString: String(classIdentificationString)),
          classVersion: classVersionNumber
        )
        self =
          .objectIdentification(OcaObjectIdentification(oNo: oNo, classIdentification: classID))
      } else {
        self = .oNo(oNo)
      }
    }

    func resolve(with connection: Ocp1Connection) async throws -> OcaRoot {
      let object: OcaRoot

      switch self {
      case let .oNo(oNo):
        object = try await connection.resolve(objectOfUnknownClass: oNo)
      case let .objectIdentification(objectIdentification):
        object = try await connection.resolve(object: objectIdentification)
      }

      return object
    }

    var oNo: OcaONo {
      switch self {
      case let .oNo(oNo):
        return oNo
      case let .objectIdentification(objectIdentification):
        return objectIdentification.oNo
      }
    }

    var description: String {
      oNo.oNoString
    }
  }

  private struct MethodTarget {
    let objectID: ObjectIdentification
    let methodID: OcaMethodID

    init(_ string: String) throws {
      let v = string.split(separator: "/", maxSplits: 2)
      guard v.count == 2 else { throw Ocp1Error.requestParameterOutOfRange }

      objectID = try ObjectIdentification(String(v[0]))
      methodID = OcaMethodID(String(v[1]))
    }
  }

  @Sendable
  private func onMethod(
    call: FlutterMethodCall<[Data]>
  ) async throws -> [UInt8] {
    try await throwingFlutterError {
      let target = try MethodTarget(call.method)
      let object = try await target.objectID.resolve(with: connection)

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

  @Sendable
  private func onSampleRate(
    call: FlutterMethodCall<Double>
  ) async throws -> Double {
    try await throwingFlutterError {
      let objectID = try ObjectIdentification(call.method)
      guard let object = try await objectID.resolve(with: connection) as? OcaMediaClock3 else {
        throw Ocp1Error.status(.badONo)
      }

      if let nominalRate = call.arguments {
        logger.trace("setting sample rate on \(objectID) to \(nominalRate)")
        try await object.set(currentRate: OcaMediaClockRate(nominalRate: OcaFrequency(nominalRate)))
        return nominalRate
      } else {
        let (mediaClockRate, _) = try await object.getCurrentRate()
        logger.trace("current sample rate on \(objectID) is \(mediaClockRate.nominalRate)")
        return Double(mediaClockRate.nominalRate)
      }
    }
  }

  private struct DatasetTarget {
    enum Method: String { case apply; case store; case fetch }

    let objectID: ObjectIdentification
    let method: Method

    init(_ string: String) throws {
      let v = string.split(separator: "/", maxSplits: 2)
      guard v.count == 2 else { throw Ocp1Error.requestParameterOutOfRange }

      objectID = try ObjectIdentification(String(v[0]))
      guard let method = Method(rawValue: String(v[1])) else {
        throw Ocp1Error.status(.badMethod)
      }
      self.method = method
    }

    func resolve(with connection: Ocp1Connection) async throws -> OcaBlock {
      guard let block = try await objectID.resolve(with: connection) as? OcaBlock else {
        throw Ocp1Error.objectClassMismatch
      }
      return block
    }
  }

  @Sendable
  private func onDataset(
    call: FlutterMethodCall<OcaUint32>
  ) async throws -> FlutterNull {
    try await throwingFlutterError {
      let target = try DatasetTarget(call.method)
      let object = try await target.resolve(with: connection)

      guard let paramDataset = call.arguments else { throw Ocp1Error.status(.parameterError) }
      switch target.method {
      case .apply:
        try await object.apply(paramDataset: paramDataset)
      case .store:
        try await object.store(currentParameterData: paramDataset)
      default:
        throw Ocp1Error.status(.badMethod)
      }
    }
    return FlutterNull()
  }

  @Sendable
  private func onDatasetBlob(
    call: FlutterMethodCall<[UInt8]>
  ) async throws -> [UInt8] {
    try await throwingFlutterError {
      let target = try DatasetTarget(call.method)
      let object = try await target.resolve(with: connection)

      switch target.method {
      case .fetch:
        return try await Array(object.fetchCurrentParameterData())
      case .store:
        guard let arguments = call.arguments else { throw Ocp1Error.status(.parameterError) }
        try await object.apply(parameterData: OcaLongBlob(arguments))
        return []
      default:
        throw Ocp1Error.status(.badMethod)
      }
    }
  }

  private struct PropertyTarget: Hashable {
    let objectID: ObjectIdentification
    let propertyID: OcaPropertyID

    static func == (_ lhs: Self, _ rhs: Self) -> Bool {
      lhs.objectID.oNo == rhs.objectID.oNo && lhs.propertyID == rhs.propertyID
    }

    init(_ string: String) throws {
      let v = string.split(separator: "/", maxSplits: 2)
      guard v.count == 2 else { throw Ocp1Error.requestParameterOutOfRange }

      objectID = try ObjectIdentification(String(v[0]))
      propertyID = OcaPropertyID(String(v[1]))
    }

    var propertyChangedEvent: OcaEvent {
      OcaEvent(emitterONo: objectID.oNo, eventID: OcaPropertyChangedEventID)
    }

    func hash(into hasher: inout Hasher) {
      objectID.oNo.hash(into: &hasher)
      propertyID.hash(into: &hasher)
    }
  }

  @Sendable
  private func onGetProperty(
    call: FlutterMethodCall<FlutterNull>
  ) async throws -> AnyFlutterStandardCodable {
    try await throwingFlutterError {
      let target = try PropertyTarget(call.method)
      let object = try await target.objectID.resolve(with: connection)

      guard let property = await object.propertySubject(for: target.propertyID) else {
        logger.error("could not locate property \(target.propertyID) on \(object)")
        throw Ocp1Error.status(.processingFailed)
      }

      let value = try await property._getValue(object, flags: [])
      return try AnyFlutterStandardCodable(value)
    }
  }

  @Sendable
  private func onSetProperty(
    call: FlutterMethodCall<AnyFlutterStandardCodable>
  ) async throws -> AnyFlutterStandardCodable {
    try await throwingFlutterError {
      let target = try PropertyTarget(call.method)
      let value = call.arguments!
      let object = try await target.objectID.resolve(with: connection)

      guard let property = await object.propertySubject(for: target.propertyID) else {
        logger.error("could not locate property \(target.propertyID) on \(object)")
        throw Ocp1Error.status(.processingFailed)
      }
      do {
        let propertyValue = try value.value(as: property.valueType)
        logger
          .trace(
            "setting property \(target.propertyID) on object \(object) to \(value) => \(propertyValue)"
          )
        try await property._setValue(object, propertyValue)
        return AnyFlutterStandardCodable.nil
      } catch {
        logger
          .trace(
            "failed to set property \(target.propertyID) on object \(object) to \(value): \(error)"
          )
        throw error
      }
    }
  }

  @discardableResult
  private func addEventSubscriptionRef(_ oNo: OcaONo) -> Int { // returns old ref count
    subscriptions.withCriticalRegion { subscriptions in
      let refCount = subscriptions.eventSubscriptionRefs[oNo] ?? 0
      subscriptions.eventSubscriptionRefs[oNo] = refCount + 1
      return refCount
    }
  }

  @discardableResult
  private func removeEventSubscriptionRef(_ oNo: OcaONo) throws -> Int { // returns new ref count
    try subscriptions.withCriticalRegion { subscriptions in
      guard var refCount = subscriptions.eventSubscriptionRefs[oNo] else {
        throw Ocp1Error.notSubscribedToEvent
      }

      refCount -= 1
      precondition(refCount >= 0)

      if refCount == 0 {
        subscriptions.eventSubscriptionRefs.removeValue(forKey: oNo)
      } else {
        subscriptions.eventSubscriptionRefs[oNo] = refCount
      }

      return refCount
    }
  }

  @Sendable
  private func onPropertyEventListen(_ target: String?) async throws
    -> FlutterEventStream<AnyFlutterStandardCodable>
  {
    try await throwingFlutterError {
      let target = try PropertyTarget(target!)
      let object = try await target.objectID.resolve(with: connection)

      guard let property = await object.propertySubject(for: target.propertyID) else {
        logger.error("could not locate property \(target.propertyID) on \(object)")
        throw Ocp1Error.status(.processingFailed)
      }

      let refCount = addEventSubscriptionRef(object.objectNumber)
      await property.subscribe(object)

      logger.trace(
        "subscribed events for object \(object) property \(target.propertyID) current value \(property), \(refCount + 1) reference(s) remaining, \(propertyEventChannel.tasksCount) outstanding tasks"
      )

      return property.eraseToFlutterEventStream(object: object, logger: logger)
    }
  }

  @Sendable
  private func onPropertyEventCancel(_ target: String?) async throws {
    try await throwingFlutterError {
      let target = try PropertyTarget(target!)
      guard let refCount = try? removeEventSubscriptionRef(target.objectID.oNo) else { return }

      if !flags.contains(.persistSubscriptions), refCount == 0 {
        guard let object = await connection.resolve(cachedObject: target.objectID.oNo) else {
          throw Ocp1Error.objectNotPresent(target.objectID.oNo)
        }

        try await object.unsubscribe()
        logger
          .trace(
            "unsubscribed events from object \(object), no references remaining, \(propertyEventChannel.tasksCount) outstanding tasks"
          )
      } else {
        logger
          .trace(
            "unsubscribed events from object ID \(target), \(refCount) reference(s) remaining, \(propertyEventChannel.tasksCount) outstanding tasks"
          )
      }
    }
  }

  @Sendable
  private func onMeteringEvent(
    target: PropertyTarget,
    event: OcaEvent,
    eventData data: Data
  ) throws {
    // FIXME: assumes all metering information is OcaDB
    let eventData = try OcaPropertyChangedEventData<OcaDB>(bytes: Array(data))

    guard eventData.propertyID == target.propertyID,
          eventData.changeType == .currentChanged,
          let subscription = subscriptions.withCriticalRegion({ subscriptions in
            subscriptions.meteringSubscriptions[target]
          })
    else {
      return
    }

    try subscription.continuation.yield(eventData.propertyValue.bridgeToAnyFlutterStandardCodable())
  }

  @Sendable
  private func onMeteringEventListen(_ target: String?) async throws
    -> FlutterEventStream<AnyFlutterStandardCodable>
  {
    try await throwingFlutterError {
      let target = try PropertyTarget(target!)
      let cancellable = try await connection.addSubscription(
        label: OcaMeteringSubscriptionLabel,
        event: target.propertyChangedEvent,
        callback: { [self] event, eventData in
          try onMeteringEvent(
            target: target,
            event: event,
            eventData: eventData
          )
        }
      )

      let stream = AsyncStream<AnyFlutterStandardCodable?>(
        AnyFlutterStandardCodable?.self,
        bufferingPolicy: .bufferingNewest(1)
      ) { continuation in
        let subscription = MeteringEventSubscription(
          cancellable: cancellable,
          continuation: continuation
        )

        continuation.onTermination = { @Sendable [self] _ in
          subscriptions.withCriticalRegion { subscriptions in
            subscriptions.meteringSubscriptions[target] = nil
          }
          Task {
            // subscriptions are ref-counted by SwiftOCA so removing this
            // subscription should not race with another re-subscription
            try await connection.removeSubscription(subscription.cancellable)
          }
          logger.trace("unsubscribed metering events from \(target)")
        }
        subscriptions.withCriticalRegion { subscriptions in
          subscriptions.meteringSubscriptions[target] = subscription
        }

        logger.trace(
          "subscribed metering events for \(target)"
        )
      }

      return stream.eraseToAnyAsyncSequence()
    }
  }

  @Sendable
  private func onMeteringEventCancel(_ target: String?) async throws {
    try await throwingFlutterError {
      let target = try PropertyTarget(target!)
      let subscription = subscriptions.withCriticalRegion { subscriptions in
        subscriptions.meteringSubscriptions[target]
      }

      guard let subscription else {
        return
      }

      subscription.continuation.finish()
      logger.trace("ended metering events subscription for \(target)")
    }
  }

  @Sendable
  private func onConnectionStateListen(_: AnyFlutterStandardCodable?) async throws
    -> FlutterEventStream<Int32>
  {
    await connection.connectionState.map { @OcaConnection [weak self] connectionState in
      if let self {
        self.logger
          .info(
            "connection state changed: \(connectionState), statistics: \(self.connection.statistics)"
          )
      }
      return Int32(connectionState.rawValue)
    }.eraseToAnyAsyncSequence()
  }

  @Sendable
  private func onConnectionStateCancel(_: AnyFlutterStandardCodable?) async throws {}

  @Sendable
  private func onIdentifyEventListen(_: AnyFlutterStandardCodable?) async throws
    -> FlutterEventStream<Bool>
  {
    guard let identificationSensor = try await connection.resolve(object: .init(
      oNo: identificationSensorONo,
      classIdentification: OcaIdentificationSensor.classIdentification
    )) as? OcaIdentificationSensor else {
      throw Ocp1Error.noMatchingTypeForClass
    }

    return await identificationSensor.identifyEvents.map { true }.eraseToAnyAsyncSequence()
  }

  @Sendable
  private func onIdentifyEventCancel(_: AnyFlutterStandardCodable?) async throws {}
}

extension OcaPropertySubjectRepresentable {
  func eraseToFlutterEventStream(object: OcaRoot, logger: Logger)
    -> FlutterEventStream<AnyFlutterStandardCodable>
  {
    subject.compactMap { value in
      guard case let .success(value) = value else {
        logger
          .trace(
            "received property event object \(object) ID \(self.propertyIDs[0]) no value"
          )
        return nil // this will be ignored by compactMap
      }
      let any = try? AnyFlutterStandardCodable(value)
      if let any, !(object is OcaSensor) {
        logger
          .trace(
            "received property event object \(object) ID \(self.propertyIDs[0]) value \(String(describing: value)) => \(any)"
          )
      }
      return any
    }.eraseToAnyAsyncSequence()
  }
}

extension FlutterError {
  init(
    error: Ocp1Error,
    message: String? = nil,
    stacktrace: String? = nil,
    channelPrefix: String
  ) {
    self.init(
      code: "\(channelPrefix)" + String(describing: error),
      message: message,
      stacktrace: stacktrace
    )
  }
}

extension OcaBoundedPropertyValue: @retroactive FlutterStandardCodable {
  public init(any: AnyFlutterStandardCodable) throws {
    // this should never happen
    throw FlutterSwiftError.notRepresentableAsStandardField
  }

  public func bridgeToAnyFlutterStandardCodable() throws -> AnyFlutterStandardCodable {
//     try AnyFlutterStandardCodable([value, minValue, maxValue])
    try AnyFlutterStandardCodable(value)
  }
}
