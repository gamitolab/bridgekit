// https://github.com/react-native-community/cli/blob/main/docs/dependencies.md
//
// Autolink the Nitro transport. The public Swift module is a separate pod
// (ios/BridgeKit.podspec), injected by scripts/cocoapods_inject_public_runtime.rb
// unless BRIDGEKIT_HOST_PROVIDES_RUNTIME=1.
//
// Expo SDK 57 ignores `podspecPath` and scans only the package-root *.podspec
// files. Keep exactly one podspec in this directory: BridgeKitNitro.podspec.

module.exports = {
  dependency: {
    platforms: {
      ios: {
        podspecPath: 'BridgeKitNitro.podspec',
      },
      android: {},
    },
  },
};
