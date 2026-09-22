require "json"

package = JSON.parse(File.read(File.join(__dir__, "..", "package.json")))

Pod::Spec.new do |s|
  s.name         = "BridgeKit"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => "15.1" }
  s.source       = { :git => "https://github.com/gamitolab/bridgekit.git", :tag => "core-v#{s.version}" }

  # Public Swift API + the C/ObjC transport seam implementation.
  # No Nitro, no JSI, no C++. A brownfield host can import this module.
  # This file lives under ios/ so Expo/RN autolinking (package-root *.podspec)
  # never picks it instead of BridgeKitNitro.
  s.source_files = [
    "engine/**/*.{h,m,swift}",
    "runtime/**/*.{h,m,swift}",
    "objc/**/*.{h,m,swift}",
    "seam/**/*.{h,m,swift}"
  ]
  s.public_header_files = "seam/BKTransport.h"
  s.exclude_files = "__tests__/**/*", "objc/BridgeKitObjC.h"
  s.requires_arc = true

  s.pod_target_xcconfig = {
    "DEFINES_MODULE" => "YES",
    "SWIFT_INSTALL_OBJC_HEADER" => "NO"
  }
end
