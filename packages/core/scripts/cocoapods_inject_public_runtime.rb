# Injects the public BridgeKit pod (ios/BridgeKit.podspec) into the current
# Podfile target when BridgeKitNitro is autolinked and the host is not
# supplying the public runtime itself.
#
# Why this file exists:
# - expo-modules-autolinking (SDK 57) lists only top-level *.podspec files and
#   ignores react-native.config.js `podspecPath`. Two podspecs in the package
#   root make it pick BridgeKit.podspec (basename matches the npm folder
#   "bridgekit") and never install Nitro.
# - CocoaPods does not resolve a second local podspec next to a `:path` pod
#   from `s.dependency` (it looks at spec repos). So Nitro cannot depend on
#   the public pod by name alone.
# - This hook runs after Nitro's podspec is fetched (so it is loaded) and
#   before the resolver runs, and `store_pod`s the public spec from ios/.
#   The app Podfile does not change.
#
# BRIDGEKIT_HOST_PROVIDES_RUNTIME=1: the host links public BridgeKit itself
# (Swift package / xcframework). Do not inject a second copy into the RN target.

return if defined?(BridgeKitCocoaPodsInject)

module BridgeKitCocoaPodsInject
  PUBLIC_POD_NAME = 'BridgeKit'
  NITRO_POD_NAME = 'BridgeKitNitro'
  PUBLIC_PATH = File.expand_path('../ios', __dir__).freeze
end

module Pod
  class Installer
    class Analyzer
      alias_method :__bridgekit_resolve_dependencies, :resolve_dependencies unless method_defined?(:__bridgekit_resolve_dependencies)

      def resolve_dependencies(locked_dependencies)
        unless ENV['BRIDGEKIT_HOST_PROVIDES_RUNTIME'] == '1'
          podfile.target_definition_list.each do |td|
            next if td.abstract?

            names = td.dependencies.map { |d| d.name.split('/').first }
            next unless names.include?(BridgeKitCocoaPodsInject::NITRO_POD_NAME)
            next if names.include?(BridgeKitCocoaPodsInject::PUBLIC_POD_NAME)

            td.store_pod(BridgeKitCocoaPodsInject::PUBLIC_POD_NAME, { :path => BridgeKitCocoaPodsInject::PUBLIC_PATH })
            UI.puts "[BridgeKitNitro] linking public #{BridgeKitCocoaPodsInject::PUBLIC_POD_NAME} from #{BridgeKitCocoaPodsInject::PUBLIC_PATH}"
            dep = td.dependencies.find { |d| d.name.split('/').first == BridgeKitCocoaPodsInject::PUBLIC_POD_NAME }
            fetch_external_source(dep, false) if dep
          end
        end
        __bridgekit_resolve_dependencies(locked_dependencies)
      end
    end
  end
end
