const { getDefaultConfig } = require('expo/metro-config')
const path = require('path')

const projectRoot = __dirname
const libraryRoot = path.resolve(projectRoot, '..')
const escape = (p) => p.replace(/[/\\^$*+?.()|[\]{}]/g, '\\$&')

const config = getDefaultConfig(projectRoot)

const singletons = ['react', 'react-native', 'react-native-nitro-modules']


module.exports = {
  ...config,
  watchFolders: [libraryRoot],
  resolver: {
    ...config.resolver,
    blockList: [
      config.resolver.blockList,
      /(\/lib-origin\/roze\/native\/.+?\/.+?\.node\.ts)$/,
      /\/nodejs-assets\/.*/,
      new RegExp(`^${escape(path.join(libraryRoot, 'node_modules'))}\\/(${singletons.join('|')})\\/.*`),
      new RegExp(`^${escape(path.join(libraryRoot, 'lib'))}\\/.*`),
    ].flat().filter(Boolean),
    nodeModulesPaths: [path.join(projectRoot, 'node_modules')],
    extraNodeModules: {
      ...Object.fromEntries(singletons.map((m) => [m, path.join(projectRoot, 'node_modules', m)])),
      path: require.resolve('path-browserify'),
    },
  },
}
