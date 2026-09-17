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
  s.source       = { :git => "https://github.com/malopezr7/bridgekit.git", :tag => "core-v#{s.version}" }

  s.source_files = [
    "ios/nitro/**/*.{h,m,mm,swift}",
    "ios/seam/BKTransport.h"
  ]
  # Public so Swift in this target sees BKTransport* without a bridging header.
  # Bridging headers are unsupported on framework targets (use_frameworks!).
  s.public_header_files = "ios/seam/BKTransport.h"
  s.exclude_files = "ios/__tests__/**/*"
  s.requires_arc = true

  load "nitrogen/generated/ios/BridgeKitNitro+autolinking.rb"
  add_nitrogen_files(s)

  current_xcconfig = s.attributes_hash["pod_target_xcconfig"] || {}
  s.pod_target_xcconfig = current_xcconfig.merge(
    "CLANG_CXX_LANGUAGE_STANDARD" => "c++20",
    "CLANG_CXX_LIBRARY" => "libc++",
    "SWIFT_OBJC_INTEROP_MODE" => "objcxx",
    "DEFINES_MODULE" => "YES",
    "SWIFT_INSTALL_OBJC_HEADER" => "NO"
  )

  s.dependency "React-jsi"
  s.dependency "React-callinvoker"
  install_modules_dependencies(s)
end
