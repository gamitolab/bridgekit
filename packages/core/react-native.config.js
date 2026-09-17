// https://github.com/react-native-community/cli/blob/main/docs/dependencies.md
//
// Autolink the Nitro transport. The public Swift/Kotlin API is a dependency of
// that pod for normal RN apps. Brownfield hosts link the public module themselves.

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
