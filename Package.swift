// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "FlutterSwiftOCA",
  platforms: [
    .macOS(.v15),
    .iOS(.v17),
  ],
  products: [
    .library(
      name: "FlutterSwiftOCA",
      targets: ["FlutterSwiftOCA"]
    ),
  ],
  dependencies: [
    // Dependencies declare other packages that this package depends on.
    .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-log", from: "1.6.2"),
    .package(url: "https://github.com/lhoward/AsyncExtensions", from: "0.9.0"),
    .package(url: "https://github.com/PADL/SwiftOCA", branch: "main"),
    .package(url: "https://github.com/PADL/FlutterSwift", branch: "main"),
  ],
  targets: [
    // Targets are the basic building blocks of a package. A target can define a module or a
    // test suite.
    // Targets can depend on other targets in this package, and on products in packages this
    // package depends on.
    .target(
      name: "FlutterSwiftOCA",
      dependencies: [
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
        .product(name: "Logging", package: "swift-log"),
        "AsyncExtensions",
        "SwiftOCA",
        "FlutterSwift",
      ],
      swiftSettings: [
        .swiftLanguageMode(.v5, .when(platforms: [.macOS, .iOS])),
        .interoperabilityMode(.Cxx, .when(platforms: [.macOS, .iOS, .linux])),
      ]
    ),
    .testTarget(
      name: "FlutterSwiftOCATests",
      dependencies: ["FlutterSwiftOCA"],
      swiftSettings: [
        .swiftLanguageMode(.v5, .when(platforms: [.macOS, .iOS])),
        .interoperabilityMode(.Cxx, .when(platforms: [.macOS, .iOS, .linux])),
      ]
    ),
  ]
)
