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
@_spi(FlutterSwiftPrivate)
import FlutterSwift
import Foundation
import Logging
@_spi(SwiftOCAPrivate)
import SwiftOCA

public let OcaChannelPrefix = "oca/"

private extension OcaONo {
  var hexString: String {
    String(self, radix: 16)
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

public final class OcaChannelManager: @unchecked
Sendable {
  private let connection: Ocp1Connection
  private let binaryMessenger: FlutterBinaryMessenger
  private let logger: Logger
  private let flags: Flags

  // method channels
  private let methodChannel: FlutterMethodChannel
  private let getPropertyChannel: FlutterMethodChannel
  private let setPropertyChannel: FlutterMethodChannel

  // event channels
  private let propertyEventChannel: FlutterEventChannel
  private let connectionStateChannel: FlutterEventChannel

  private struct State {
    var subscriptionRefs = [OcaONo: Int]()
  }

  private let state: ManagedCriticalState<State>

  public struct Flags: OptionSet, Sendable {
    public typealias RawValue = UInt

    public let rawValue: RawValue

    public init(rawValue: RawValue) {
      self.rawValue = rawValue
    }

    public static let persistSubscriptions = Flags(rawValue: 1 << 0)
  }

  public init(
    connection: Ocp1Connection,
    binaryMessenger: FlutterBinaryMessenger,
    logger: Logger,
    flags: Flags = []
  ) async throws {
    self.connection = connection
    self.binaryMessenger = binaryMessenger
    self.logger = logger
    self.flags = flags
    state = ManagedCriticalState(State())

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
    try await getPropertyChannel.setMethodCallHandler(onGetProperty)
    try await setPropertyChannel.setMethodCallHandler(onSetProperty)

    try await propertyEventChannel.allowChannelBufferOverflow(true)
    try await propertyEventChannel.setStreamHandler(
      onListen: onPropertyEventListen,
      onCancel: onPropertyEventCancel
    )

    try await connectionStateChannel.allowChannelBufferOverflow(true)
    try await connectionStateChannel.setStreamHandler(
      onListen: onConnectionStateListen,
      onCancel: onConnectionStateCancel
    )

    try await connection.connect()
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

  // we allow objects of both known and unknown class to be addressed over channels
  private enum ObjectIdentification {
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

  private struct PropertyTarget {
    let objectID: ObjectIdentification
    let propertyID: OcaPropertyID

    init(_ string: String) throws {
      let v = string.split(separator: "/", maxSplits: 2)
      guard v.count == 2 else { throw Ocp1Error.requestParameterOutOfRange }

      objectID = try ObjectIdentification(String(v[0]))
      propertyID = OcaPropertyID(String(v[1]))
    }
  }

  private func onGetProperty(
    call: FlutterMethodCall<FlutterNull>
  ) async throws -> AnyFlutterStandardCodable {
    try await throwingFlutterError {
      let target = try PropertyTarget(call.method)
      let object = try await target.objectID.resolve(with: connection)

      guard let property = object.propertySubject(with: target.propertyID) else {
        logger.error("could not locate property \(target.propertyID) on \(object)")
        throw Ocp1Error.status(.processingFailed)
      }

      let value = try await property._getValue(object, flags: [])
      return try AnyFlutterStandardCodable(value)
    }
  }

  private func onSetProperty(
    call: FlutterMethodCall<AnyFlutterStandardCodable>
  ) async throws -> AnyFlutterStandardCodable {
    try await throwingFlutterError {
      let target = try PropertyTarget(call.method)
      let value = call.arguments!
      let object = try await target.objectID.resolve(with: connection)

      guard let property = object.propertySubject(with: target.propertyID) else {
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
  private func addSubscriptionRef(_ oNo: OcaONo) -> Int { // returns old ref count
    state.withCriticalRegion { state in
      let refCount = state.subscriptionRefs[oNo] ?? 0
      state.subscriptionRefs[oNo] = refCount + 1
      return refCount
    }
  }

  @discardableResult
  private func removeSubscriptionRef(_ oNo: OcaONo) throws -> Int { // returns new ref count
    try state.withCriticalRegion { state in
      guard var refCount = state.subscriptionRefs[oNo] else {
        throw Ocp1Error.notSubscribedToEvent
      }

      precondition(refCount > 0)
      refCount = refCount - 1

      if refCount == 0 {
        state.subscriptionRefs.removeValue(forKey: oNo)
      } else {
        state.subscriptionRefs[oNo] = refCount
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

      guard let property = object.propertySubject(with: target.propertyID) else {
        logger.error("could not locate property \(target.propertyID) on \(object)")
        throw Ocp1Error.status(.processingFailed)
      }

      addSubscriptionRef(object.objectNumber)
      await property.subscribe(object)

      logger.trace(
        "subscribed object \(object) property \(target.propertyID) current value \(property)"
      )

      return property.eraseToFlutterEventStream(object: object, logger: logger)
    }
  }

  @Sendable
  private func onPropertyEventCancel(_ target: String?) async throws {
    try await throwingFlutterError {
      let target = try PropertyTarget(target!)
      guard let refCount = try? removeSubscriptionRef(target.objectID.oNo) else { return }

      if !flags.contains(.persistSubscriptions), refCount == 0 {
        guard let object = await connection.resolve(cachedObject: target.objectID.oNo) else {
          throw Ocp1Error.objectNotPresent(target.objectID.oNo)
        }

        try await object.unsubscribe()
        logger.trace("unsubscribed object \(object)")
      }
    }
  }

  @Sendable
  private func onConnectionStateListen(_: AnyFlutterStandardCodable?) async throws
    -> FlutterEventStream<Int32>
  {
    await connection.connectionState.map { @OcaConnection [self] connectionState in
      logger
        .info("connection state changed: \(connectionState), statistics: \(connection.statistics)")
      return Int32(connectionState.rawValue)
    }.eraseToAnyAsyncSequence()
  }

  @Sendable
  private func onConnectionStateCancel(_: AnyFlutterStandardCodable?) async throws {}
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
    stacktrace: String? = nil
  ) {
    self.init(
      code: "\(OcaChannelPrefix)" + String(describing: error),
      message: message,
      stacktrace: stacktrace
    )
  }
}

extension OcaBoundedPropertyValue: FlutterStandardCodable {
  public init(any: AnyFlutterStandardCodable) throws {
    // this should never happen
    throw FlutterSwiftError.notRepresentableAsStandardField
  }

  public func bridgeToAnyFlutterStandardCodable() throws -> AnyFlutterStandardCodable {
//     try AnyFlutterStandardCodable([value, minValue, maxValue])
    try AnyFlutterStandardCodable(value)
  }
}
