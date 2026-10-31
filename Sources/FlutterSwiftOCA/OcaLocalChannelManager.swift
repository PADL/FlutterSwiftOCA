//
// Copyright (c) 2026 PADL Software Pty Ltd
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
import FlutterSwift
import Foundation
import SwiftOCADevice

/// The channel carrying PDUs between Dart and an in-memory device.
public let OcaLocalChannelName = "oca-local/pdu"

/// Carries the raw PDUs of a controller in Dart to a device in this process, with no
/// socket between them. Channels belong to a Flutter engine, and a local endpoint has a
/// single controller, so make one of these per engine that talks to the device.
public final class OcaLocalChannelManager: @unchecked Sendable {
  private let channel: FlutterBasicMessageChannel
  private let endpoint: OcaLocalDeviceEndpoint
  private let requests: AsyncStream<Data>.Continuation
  private var tasks = [Task<(), Never>]()

  @FlutterPlatformThreadActor
  public init(device: OcaDevice = OcaDevice.shared, binaryMessenger: FlutterBinaryMessenger) async throws {
    let endpoint = try await OcaLocalDeviceEndpoint(device: device)
    let channel = FlutterBasicMessageChannel(
      name: OcaLocalChannelName,
      binaryMessenger: binaryMessenger,
      codec: FlutterBinaryCodec.shared
    )
    let (stream, requests) = AsyncStream<Data>.makeStream()
    self.endpoint = endpoint
    self.channel = channel
    self.requests = requests

    tasks = [
      Task { try? await endpoint.run() },
      // one at a time, as a PDU overtaking another would reorder commands
      Task {
        for await request in stream {
          await endpoint.deliver(request: request)
        }
      },
      Task {
        for await response in endpoint.responses {
          try? await channel.send(message: response)
        }
      },
    ]

    try channel.setMessageHandler { (message: Data?) -> Data? in
      if let message { requests.yield(message) }
      return Data()
    }
  }

  deinit {
    requests.finish()
    for task in tasks {
      task.cancel()
    }
  }
}
