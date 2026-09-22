require "json"
require_relative "scripts/cocoapods_inject_public_runtime"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "BridgeKitNitro"
  s.version      = package["version"]
  s.summary      = "Nitro / JSI transport for BridgeKit. Not imported by host apps."
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => "15.1" }
  s.source       = { :git => "https://github.com/gamitolab/bridgekit.git", :tag => "core-v#{s.version}" }

  s.source_files = [
    "ios/nitro/**/*.{h,m,mm,swift}",
    "ios/seam/BKTransport.h"
  ]
  # Public so Swift in this target sees BKTransport* without a bridging header.
  # Bridging headers are unsupported on framework targets (use_frameworks!).
  s.public_header_files = "ios/seam/BKTransport.h"
  # Build the exclude list as an Array. Assigning with shovel on the spec
  # attribute does not append — CocoaPods does not expose a Ruby Array there.
  excluded = ["ios/__tests__/**/*"]
  if ENV["BRIDGEKIT_HOST_PROVIDES_RUNTIME"] == "1"
    # Host compiles the strong BKTransport.m. Weak stubs in the same image as
    # Nitro (Callstack fuses pods into the packaged framework) swallow provide().
    excluded << "ios/nitro/BKTransportWeakStubs.m"
    s.user_target_xcconfig = {
      "OTHER_LDFLAGS" => "$(inherited) -Wl,-undefined,dynamic_lookup"
    }
  end
  s.exclude_files = excluded
  s.requires_arc = true

  load "nitrogen/generated/ios/BridgeKitNitro+autolinking.rb"
  add_nitrogen_files(s)

  current_xcconfig = s.attributes_hash["pod_target_xcconfig"] || {}
  existing_swift_flags = current_xcconfig["OTHER_SWIFT_FLAGS"] || "$(inherited)"
  s.pod_target_xcconfig = current_xcconfig.merge(
    "CLANG_CXX_LANGUAGE_STANDARD" => "c++20",
    "CLANG_CXX_LIBRARY" => "libc++",
    "SWIFT_OBJC_INTEROP_MODE" => "objcxx",
    "DEFINES_MODULE" => "YES",
    "SWIFT_INSTALL_OBJC_HEADER" => "NO",
    # Xcode 27 + BUILD_LIBRARY_FOR_DISTRIBUTION still runs SwiftVerifyEmittedModuleInterface
    # even with SWIFT_VERIFY_EMITTED_MODULE_INTERFACE=NO. The C++ umbrella then fails
    # (`BorrowingReference.hpp`). Disable the frontend check; Nitro is not a stable ABI.
    "SWIFT_VERIFY_EMITTED_MODULE_INTERFACE" => "NO",
    "ENABLE_MODULE_VERIFIER" => "NO",
    "BUILD_LIBRARY_FOR_DISTRIBUTION" => "NO",
    "OTHER_SWIFT_FLAGS" => "#{existing_swift_flags} -no-verify-emitted-module-interface"
  )

  s.dependency "React-jsi"
  s.dependency "React-callinvoker"
  install_modules_dependencies(s)
end
