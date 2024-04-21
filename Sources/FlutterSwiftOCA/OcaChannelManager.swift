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

public let OcaChannelPrefix = "oca/"

private extension OcaONo {
  var hexString: String {
    String(format: "%08x", self)
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

@OcaConnection
public final class OcaChannelManager {
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

  public struct Flags: OptionSet {
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

      guard let object = try await connection.resolve(objectOfUnknownClass: target.oNo)
      else {
        throw Ocp1Error.objectNotPresent(target.oNo)
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
      precondition(v[1].contains("."))
      propertyID = OcaPropertyID(String(v[1]))
    }
  }

  private func onGetProperty(
    call: FlutterMethodCall<FlutterNull>
  ) async throws -> AnyFlutterStandardCodable {
    try await throwingFlutterError {
      let target = try PropertyTarget(call.method)

      guard let object = try await connection.resolve(objectOfUnknownClass: target.oNo)
      else {
        throw Ocp1Error.objectNotPresent(target.oNo)
      }

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

      guard let object = try await connection.resolve(objectOfUnknownClass: target.oNo)
      else {
        throw Ocp1Error.objectNotPresent(target.oNo)
      }

      guard let property = object.propertySubject(with: target.propertyID) else {
        logger.error("could not locate property \(target.propertyID) on \(object)")
        throw Ocp1Error.status(.processingFailed)
      }

      logger
        .trace(
          "setting property \(target.propertyID) on object \(object) to \(value)"
        )
      try await property._setValue(object, value.value(as: property.valueType))
      return AnyFlutterStandardCodable.nil
    }
  }

  private var subscriptionRefs = [OcaONo: Int]()

  private func addSubscriptionRef(_ oNo: OcaONo) -> Int { // returns old ref count
    let refCount = subscriptionRefs[oNo] ?? 0
    subscriptionRefs[oNo] = refCount + 1
    return refCount
  }

  private func removeSubscriptionRef(_ oNo: OcaONo) throws -> Int { // returns new ref count
    guard var refCount = subscriptionRefs[oNo] else {
      throw Ocp1Error.notSubscribedToEvent
    }

    precondition(refCount > 0)
    refCount = refCount - 1

    if refCount == 0 {
      subscriptionRefs.removeValue(forKey: oNo)
    } else {
      subscriptionRefs[oNo] = refCount
    }

    return refCount
  }

  @Sendable
  private func onPropertyEventListen(_ target: String?) async throws
    -> FlutterEventStream<AnyFlutterStandardCodable>
  {
    try await throwingFlutterError {
      let target = try PropertyTarget(target!)

      guard let object = try await connection.resolve(objectOfUnknownClass: target.oNo)
      else {
        throw Ocp1Error.objectNotPresent(target.oNo)
      }

      guard let property = object.propertySubject(with: target.propertyID) else {
        logger.error("could not locate property \(target.propertyID) on \(object)")
        throw Ocp1Error.status(.processingFailed)
      }

      if addSubscriptionRef(object.objectNumber) == 0 {
        await property.subscribe(object)
        logger.trace("subscribed object \(object) property \(target.propertyID)")
      }

      return property.eraseToFlutterEventStream(object: object, logger: logger)
    }
  }

  @Sendable
  private func onPropertyEventCancel(_ target: String?) async throws {
    let target = try PropertyTarget(target!)

    guard let object = connection.resolve(cachedObject: target.oNo) else {
      throw Ocp1Error.objectNotPresent(target.oNo)
    }

    let refCount = try removeSubscriptionRef(target.oNo)

    if !flags.contains(.persistSubscriptions), refCount == 0 {
      try await object.unsubscribe()
      logger.trace("unsubscribed object \(object)")
    }
  }

  @Sendable
  private func onConnectionStateListen(_: AnyFlutterStandardCodable?) async throws
    -> FlutterEventStream<Int32>
  {
    connection.connectionState.map { Int32($0.rawValue) }.eraseToAnyAsyncSequence()
  }

  @Sendable
  private func onConnectionStateCancel(_: AnyFlutterStandardCodable?) async throws {}
}

extension OcaPropertyRepresentable {
  func eraseToFlutterEventStream(object: OcaRoot, logger: Logger)
    -> FlutterEventStream<AnyFlutterStandardCodable>
  {
    async.compactMap {
      guard let value = try? $0.get() else {
        return .nil
      }
      let any = try AnyFlutterStandardCodable(value)
      if !(object is OcaSensor) {
        logger
          .trace(
            "property event object \(object) ID \(self.propertyIDs[0]) value \(String(describing: value)) => \(any)"
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
