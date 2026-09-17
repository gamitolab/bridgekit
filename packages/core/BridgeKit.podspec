require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "BridgeKit"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => "15.1" }
  # Release tags are package-scoped (see RELEASING.md): the core package ships as
  # `core-vX.Y.Z`, not a bare version, so a git-sourced pod must ask for that.
  s.source       = { :git => "https://github.com/malopezr7/bridgekit.git", :tag => "core-v#{s.version}" }

  s.source_files = "ios/**/*.{h,m,mm,swift}"
  s.exclude_files = "ios/__tests__/**/*"
  s.requires_arc = true

  load 'nitrogen/generated/ios/BridgeKit+autolinking.rb'
  add_nitrogen_files(s)

  # Nitrogen already sets C++20, objcxx interop, DEFINES_MODULE, and
  # SWIFT_INSTALL_OBJC_HEADER=NO (required on Xcode 26.4+ / 27 static linkage).
  # Force libc++ and keep the module in C++/ObjC++ — compiling the Clang module
  # as C makes Nitro 0.37's <regex> include fail with:
  #   NitroTypeInfo.hpp: #include <regex> file not found
  #   could not build Objective-C module 'BridgeKit'
  current_xcconfig = s.attributes_hash['pod_target_xcconfig'] || {}
  s.pod_target_xcconfig = current_xcconfig.merge(
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'SWIFT_OBJC_INTEROP_MODE' => 'objcxx',
    'DEFINES_MODULE' => 'YES',
    'SWIFT_INSTALL_OBJC_HEADER' => 'NO'
  )

  s.dependency 'React-jsi'
  s.dependency 'React-callinvoker'
  install_modules_dependencies(s)
end
