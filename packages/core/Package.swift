// swift-tools-version: 5.9

// Public BridgeKit module (pure Swift + the C/ObjC transport seam).
//
// Brownfield hosts add this package and `import BridgeKit`. React Native apps
// get the same sources through BridgeKit.podspec, pulled in by BridgeKitNitro.
//
// ios/nitro/* stays out: that is BridgeKitNitro (NitroModules / C++ / JSI).
//
// Nothing here depends on UIKit, so `swift test` runs natively on the host with
// no simulator boot. That is the whole point: iOS test feedback in seconds.

import PackageDescription

let package = Package(
    name: "BridgeKit",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "BridgeKit", targets: ["BridgeKit"])
    ],
    targets: [
        .target(
            name: "BridgeKitSeam",
            path: "ios/seam",
            publicHeadersPath: "."
        ),
        .target(
            name: "BridgeKit",
            dependencies: ["BridgeKitSeam"],
            path: "ios",
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
            path: "ios/__tests__",
            exclude: [
                // Imports NitroModules; runs only in the pod/xcframework build.
                "AnyMapCodecTests.swift"
            ]
        )
    ]
)
