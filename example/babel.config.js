module.exports = function (api) {
  api.cache(true)
  return {
    presets: [['babel-preset-expo', { unstable_transformImportMeta: true }]],
    plugins: [
      [
        'module-resolver',
        {
          root: ['./'],
          alias: {
            '@native': './lib-origin/roze/native',
            '@lib': './lib-origin/roze/lib',
            '@roze': './lib-origin/roze/src',
            '@origin': './lib-origin/origin/src',
            '@illusive': './lib-origin/Illusive/src',
            '@common': './lib-origin/common',
          },
        },
      ],
    ],
  }
}
