require "json"

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
    "SWIFT_INSTALL_OBJC_HEADER" => "NO",
    "SWIFT_OBJC_BRIDGING_HEADER" => "${PODS_TARGET_SRCROOT}/ios/seam/BKTransport.h"
  )

  # A normal RN app autolinks this pod and needs the public runtime in-process.
  # A Callstack brownfield packager sets BRIDGEKIT_HOST_PROVIDES_RUNTIME=1 so the
  # host links public BridgeKit itself (SPM / xcframework) and this pod does not
  # fuse a second copy into BrownfieldLib.
  unless ENV["BRIDGEKIT_HOST_PROVIDES_RUNTIME"] == "1"
    s.dependency "BridgeKit"
  end

  s.dependency "React-jsi"
  s.dependency "React-callinvoker"
  install_modules_dependencies(s)
end
