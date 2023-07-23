// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FlutterSwiftOCA",
    platforms: [
        .macOS(.v10_15),
    ],
    products: [
        .library(
            name: "FlutterSwiftOCA",
            targets: ["FlutterSwiftOCA"]
        ),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "0.1.0"),
        .package(url: "https://github.com/lhoward/AsyncExtensions", branch: "linux"),
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
                "AsyncExtensions",
                "SwiftOCA",
                "FlutterSwift",
            ]
        ),
        .testTarget(
            name: "FlutterSwiftOCATests",
            dependencies: ["FlutterSwiftOCA"]
        ),
    ]
)
