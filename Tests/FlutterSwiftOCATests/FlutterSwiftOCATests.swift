#if canImport(Darwin) || canImport(dnssd) || os(Android)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif
@testable import FlutterSwiftOCA
import Foundation
import SocketAddress
import SwiftOCA
import XCTest

final class DeviceURLTests: XCTestCase {
  private func sockaddr(_ family: Int32, _ presentationAddress: String) throws -> Data {
    let address = try AnySocketAddress(
      family: sa_family_t(family),
      presentationAddress: presentationAddress
    )
    return address.withSockAddr { sa, size in Data(bytes: sa, count: Int(size)) }
  }

  private func url(
    _ serviceType: OcaNetworkAdvertisingServiceType,
    addresses: [Data] = [],
    hostname: String? = "device.local.",
    port: UInt16 = 65000,
    txtRecords: [String: String] = [:]
  ) -> String? {
    OcaBrokerChannelManager.deviceURL(
      serviceType: serviceType,
      addresses: addresses,
      hostname: hostname,
      port: port,
      txtRecords: txtRecords
    )
  }

  func testFirstAddressIsPreferred() throws {
    let addresses = try [sockaddr(AF_INET, "192.0.2.1"), sockaddr(AF_INET6, "2001:db8::1")]
    XCTAssertEqual(url(.tcp, addresses: addresses), "ocp1+tcp://192.0.2.1:65000")
  }

  func testIPv6IsBracketed() throws {
    let addresses = try [sockaddr(AF_INET6, "2001:db8::1")]
    XCTAssertEqual(url(.tcpJson, addresses: addresses, port: 1234), "ocp2+tcp://[2001:db8::1]:1234")
  }

  func testLinkLocalIPv6IsSkipped() throws {
    let linkLocal = try sockaddr(AF_INET6, "fe80::1")
    XCTAssertEqual(url(.tcp, addresses: [linkLocal]), "ocp1+tcp://device.local:65000")
    let global = try sockaddr(AF_INET6, "2001:db8::2")
    XCTAssertEqual(url(.tcp, addresses: [linkLocal, global]), "ocp1+tcp://[2001:db8::2]:65000")
    // not fe80::/10, despite rendering with an fe8 prefix
    let notLinkLocal = try sockaddr(AF_INET6, "fe8::1")
    XCTAssertEqual(url(.tcp, addresses: [notLinkLocal]), "ocp1+tcp://[fe8::1]:65000")
  }

  func testWebSocketPath() {
    XCTAssertEqual(url(.tcpWebSocket), "ocp1+ws://device.local:65000/")
    XCTAssertEqual(url(.tcpWebSocket, txtRecords: ["path": "oca"]), "ocp1+ws://device.local:65000/oca")
    XCTAssertEqual(
      url(.tcpWebSocketJson, txtRecords: ["path": "/ocp2"]),
      "ocp2+ws://device.local:65000/ocp2"
    )
  }

  func testUnsupportedServiceTypes() {
    XCTAssertNil(url(.udp))
    XCTAssertNil(url(.udpJson))
    XCTAssertNil(url(.tcpSecure))
  }

  func testNoHost() {
    XCTAssertNil(url(.tcp, hostname: nil))
    XCTAssertNil(url(.tcp, hostname: ""))
  }
}
#endif
