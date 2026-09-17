# iOS — Callstack Brownfield Example

Self-contained native host app (Swift/UIKit) that imports React Native + BridgeKit
as a pre-built XCFramework. The host app has **no Node.js dependency**.

## Architecture

```
apps/example-callstack-brownfield/
├── ios/
│   ├── project.yml              ← xcodegen: RN workspace (ReactNativeFramework + RNAppHost)
│   ├── Podfile                  ← CocoaPods for the RN workspace
│   ├── .xcode.env               ← NODE_BINARY for script phases
│   ├── ReactNativeFramework/    ← Framework target (packaged into XCFramework)
│   │   └── ReactNativeFramework.swift    ← public interface + @_exported import ReactBrownfield
│   ├── RNAppHost/               ← Thin shell target (CocoaPods anchor only, not shipped)
│   ├── HostApp/                 ← Standalone native host (NO CocoaPods)
│   │   ├── project.yml          ← xcodegen: HostApp.xcodeproj + local BridgeKit SPM
│   │   ├── AppDelegate.swift    ← provide() then brownfield start
│   │   ├── bridgekit/           ← BridgekitDemoInitializer (host provide)
│   │   ├── Generated/           ← codegen Swift contracts
│   │   ├── HomeViewController.swift
│   │   ├── Info.plist
│   │   ├── PrivacyInfo.xcprivacy
│   │   └── LaunchScreen.storyboard
```

## Build Sequence

### Step 1 — Generate RN workspace project

From the package root (`apps/example-callstack-brownfield/`):

```sh
# Hoist workspace dependencies
pnpm install

# Generate the Xcode workspace project (ReactNativeFramework + RNAppHost targets)
cd ios && xcodegen generate --spec project.yml

# Install CocoaPods (Nitro transport + RN). Public BridgeKit stays out of
# the packaged framework via BRIDGEKIT_HOST_PROVIDES_RUNTIME=1.
pod install
```

### Step 2 — Package the XCFramework

From the package root:

```sh
pnpm package:ios
# Equivalent: npx brownfield package:ios --scheme ReactNativeFramework --configuration Release
```

Output (default path): `ios/.brownfield/package/build/`

| File | Contents |
|------|----------|
| `ReactNativeFramework.xcframework` | Your RN app + BridgeKitNitro + bundle |
| `ReactBrownfield.xcframework` | @callstack/react-native-brownfield runtime |
| `hermesvm.xcframework` | Hermes JS engine (RN ≥ 0.82) |

### Step 3 — Generate and open HostApp

```sh
cd ios/HostApp && xcodegen generate --spec project.yml
open HostApp.xcodeproj
```

In Xcode:
- Select the `HostApp` target → General → Frameworks, Libraries, and Embedded Content
- Verify the three xcframeworks from step 2 are listed as **Embed & Sign**
- Verify the local Swift package `packages/core` product `BridgeKit` is linked
- Build & Run on a simulator or device

## BridgeKit Initialization Order

```
AppDelegate.application(_:didFinishLaunchingWithOptions:)
  │
  ├─ 1. BridgekitDemoInitializer.configure()
  │       ↳ registers native providers in BridgeKitRuntime.default
  │         BEFORE the JS bundle executes
  │         (same call as apps/example/ios/BridgeKitExample/AppDelegate.swift line 16)
  │
  ├─ 2. ReactNativeBrownfield.shared.bundle = ReactNativeBundle
  │       ↳ points brownfield runtime at the XCFramework bundle (not host bundle)
  │
  ├─ 3. ReactNativeBrownfield.shared.startReactNative(onBundleLoaded:launchOptions:)
  │       ↳ starts Hermes + loads the JS bundle asynchronously
  │
  └─ 4. HomeViewController (native UIKit screen)
           ↳ button tap → present ReactNativeViewController(moduleName: "BridgeKitCallstackBrownfield")
```

## Why BridgekitDemoInitializer Lives in HostApp

Host native provides; JS consumes. Putting `provide()` inside the packaged RN
framework was the bug: Callstack fuses pods into `BrownfieldLib`, and a C++/Nitro
`import BridgeKit` then fails on the host (`NitroTypeInfo.hpp`, `SharedAnyMap`).

Public `BridgeKit` is C++-free. HostApp links it as a local Swift package
(`packages/core`) and calls `BridgekitDemoInitializer.configure()` before
`startReactNative`. The RN Podfile sets `BRIDGEKIT_HOST_PROVIDES_RUNTIME=1` so
`BridgeKitNitro` does not fuse a second runtime into the XCFramework. The two
sides meet through the process-wide `BKTransport` C seam.

HostApp stays Node-free and pod-free. Callstack's CLI does not yet copy an
arbitrary BridgeKit xcframework into `spm-artifacts/` (`KNOWN_ISSUES.md`
BF-IOS-01); the local package path is the host recipe until that exists.

## API Verification Notes

| API | Source | Status |
|-----|--------|--------|
| `ReactNativeBrownfield.shared.bundle = ReactNativeBundle` | Context7 /callstack/react-native-brownfield, docs/getting-started/ios.mdx | VERIFIED |
| `ReactNativeBrownfield.shared.startReactNative(onBundleLoaded:launchOptions:)` | Context7 docs/api-reference/react-native-brownfield/swift.mdx | VERIFIED |
| `ReactNativeViewController(moduleName:)` | Context7 docs/api-reference/react-native-brownfield/swift.mdx | VERIFIED |
| `@_exported import ReactBrownfield` + `Bundle(for: InternalClassForBundle.self)` | Context7 docs/getting-started/ios.mdx | VERIFIED |
| `inherit! :complete` in Podfile framework target | Context7 docs/getting-started/ios.mdx | VERIFIED |
| `use_frameworks! :linkage => :static` | Context7 docs/getting-started/ios.mdx | VERIFIED |
| `npx brownfield package:ios --scheme ReactNativeFramework --configuration Release` | Context7 docs/api-reference/brownie/xcframework-packaging.mdx | VERIFIED |
| `hermesvm.xcframework` as third output (RN ≥ 0.82) | Context7 (inferred from RN 0.82+ Hermes split) | ASSUMED — verify filename against actual package:ios output |
| `BUILD_LIBRARY_FOR_DISTRIBUTION=YES` on framework target | Callstack docs architecture overview + standard XCFramework requirement | INFERRED from standard iOS practice |
| `ENABLE_MODULE_VERIFIER=NO` on framework target | Callstack community / standard RN XCFramework setup | INFERRED — needed to avoid C++ header false errors |
| `RNAppHost` as outer CocoaPods anchor target | Callstack docs show `target '<project_name>'` wrapping framework | INFERRED from Podfile pattern — the outer target name must match a real Xcode target |
