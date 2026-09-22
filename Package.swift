// swift-tools-version: 5.9

// Remote Swift Package Manager entry. SPM only reads Package.swift at the
// repository root, so a host can depend on a tag without a local checkout:
//
//   .package(url: "https://github.com/gamitolab/bridgekit.git", exact: "0.3.0-alpha.4")
//   .product(name: "BridgeKit", package: "bridgekit")
//
// packages/core/Package.swift stays for `swift test` in that directory.
// ios/nitro stays out: that is BridgeKitNitro, not this product.

import PackageDescription

let package = Package(
    name: "bridgekit",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "BridgeKit", targets: ["BridgeKit"])
    ],
    targets: [
        .target(
            name: "BridgeKitSeam",
            path: "packages/core/ios/seam",
            publicHeadersPath: "."
        ),
        .target(
            name: "BridgeKit",
            dependencies: ["BridgeKitSeam"],
            path: "packages/core/ios",
            exclude: [
                "__tests__",
                "nitro",
                "seam",
                "objc/BridgeKitObjC.h"
            ]
        ),
        .testTarget(
            name: "BridgeKitTests",
            dependencies: ["BridgeKit"],
            path: "packages/core/ios/__tests__",
            exclude: [
                "AnyMapCodecTests.swift"
            ]
        )
    ]
)
