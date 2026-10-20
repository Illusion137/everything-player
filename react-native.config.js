/**
 * @type {import('@react-native-community/cli-types').UserDependencyConfig}
 */
module.exports = {
  dependency: {
    platforms: {
      android: {
        packageImportPath:
          'import com.margelo.nitro.everythingplayer.EverythingPlayerPackage;',
        packageInstance: 'new EverythingPlayerPackage()',
      },
      ios: {},
    },
  },
}
