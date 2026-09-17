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

if grep -Eq '^[[:space:]]*s\.exclude_files[[:space:]]*<<' "$podspec"; then
  echo "error: CocoaPods Spec#exclude_files is not an Array; assign a built array" >&2
  exit 1
fi

if ! grep -q 'BKTransportWeakStubs.m' "$podspec"; then
  echo "error: HOST_PROVIDES must exclude ios/nitro/BKTransportWeakStubs.m" >&2
  exit 1
fi

header="$root/ios/seam/BKTransport.h"
if ! grep -q 'extern "C"' "$header"; then
  echo "error: BKTransport.h C functions must be extern \"C\" under objcxx" >&2
  exit 1
fi

awk '
  /@interface BKTransportHooks/ { iface = NR }
  /extern "C"/ { if (ext == 0) ext = NR }
  END {
    if (iface == 0 || ext == 0 || iface > ext) {
      print "error: BKTransportHooks @interface must stay outside extern \"C\"" > "/dev/stderr"
      exit 1
    }
  }
' "$header"

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

# Tic 1: a C++ translation unit and a C .m must agree on the unmangled
# _BKTransportInvoke name. Without extern "C", Swift/objcxx mangles it.
cat > "$work/def.m" <<'EOF'
#import "BKTransport.h"
void BKTransportInvoke(NSDictionary *env, BKDictCallback complete) {
  (void)env;
  complete(@{});
}
EOF
cat > "$work/caller.mm" <<'EOF'
#import "BKTransport.h"
void call_invoke(void) {
  BKTransportInvoke(@{}, ^(NSDictionary *result) { (void)result; });
}
EOF

clang -c -fobjc-arc \
  -isysroot "$sdk" -target "$target" \
  -I "$root/ios/seam" \
  "$work/def.m" -o "$work/def.o"
clang++ -c -std=c++20 -fobjc-arc \
  -isysroot "$sdk" -target "$target" \
  -I "$root/ios/seam" \
  "$work/caller.mm" -o "$work/caller.o"

def_sym="$(nm "$work/def.o" | awk '/BKTransportInvoke/ { print $NF; exit }')"
caller_sym="$(nm "$work/caller.o" | awk '/BKTransportInvoke/ { print $NF; exit }')"
if [[ "$def_sym" != "_BKTransportInvoke" || "$caller_sym" != "_BKTransportInvoke" ]]; then
  echo "error: BKTransportInvoke must be C-unmangled; def=$def_sym caller=$caller_sym" >&2
  exit 1
fi

echo "ios-linkage-check: extern C seam OK"
