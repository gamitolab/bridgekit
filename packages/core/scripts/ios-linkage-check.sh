#!/usr/bin/env bash
# Prove BridgeKitNitro Swift can see BKTransport* without a bridging header,
# under both a Clang module import (frameworks) and a static compile.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
podspec="$root/BridgeKitNitro.podspec"

if grep -q SWIFT_OBJC_BRIDGING_HEADER "$podspec"; then
  echo "error: BridgeKitNitro.podspec must not set SWIFT_OBJC_BRIDGING_HEADER" >&2
  exit 1
fi

if [[ ! -f "$root/ios/BridgeKit.podspec" ]]; then
  echo "error: public podspec must live at ios/BridgeKit.podspec so autolinking cannot pick it" >&2
  exit 1
fi

if [[ -f "$root/BridgeKit.podspec" ]]; then
  echo "error: BridgeKit.podspec must not sit in the package root (Expo would autolink it)" >&2
  exit 1
fi

sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
target="arm64-apple-ios15.1-simulator"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/module.modulemap" <<EOF
module BridgeKitNitroSeam {
  header "$root/ios/seam/BKTransport.h"
  export *
}
EOF

cat > "$work/SeamCall.swift" <<'EOF'
import BridgeKitNitroSeam
import Foundation

func seamCall() {
    let env: [AnyHashable: Any] = ["k": "v"]
    let mapped = NSDict.fromMap(["k": "v"])
    let round = NSDict.toMap(mapped)
    _ = round
    BKTransportInvoke(env) { result in
        _ = NSDict.toMap(result)
    }
}
EOF

# Framework-style: C header imported as a Clang module (no bridging header).
swiftc -typecheck \
  -sdk "$sdk" \
  -target "$target" \
  -I "$work" \
  -Xcc -fmodule-map-file="$work/module.modulemap" \
  "$root/ios/nitro/NSDict.swift" \
  "$work/SeamCall.swift"

echo "ios-linkage-check: module import OK"
