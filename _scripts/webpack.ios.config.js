// -----------------------------------------------------------------------------
// FreeTube iOS webpack build
// -----------------------------------------------------------------------------
// Android 版 (`webpack.android.config.js`) と 対称な構成。
// 主な違い:
//   - output.path が `ios/App/App/www/`
//   - `process.env.IS_IOS = true`, `process.env.IS_ANDROID = true` の両方を立てる
//     * IS_ANDROID を true にする理由: 既存の Vue コード全体で
//       「WebView 内でホストされるモバイルアプリである」ことを表す分岐が
//       `process.env.IS_ANDROID` に集約されているため。iOS も
//       同じ挙動を望むので同じフラグを立てる。
//     * IS_IOS は「iOS 固有処理」を今後書き足したい時に使う。
//   - `NormalModuleReplacementPlugin` で `helpers/android/` への
//     import を `helpers/ios/` に自動書き換え → 既存 Vue ソースは無変更で通る。
//   - externals: `android: 'Android'` は android と共通 (iOS 側 Swift が
//     `window.Android` として Bridge オブジェクトを注入するため)。
// -----------------------------------------------------------------------------

const path = require('path')
const fs = require('fs')
const webpack = require('webpack')
const HtmlWebpackPlugin = require('html-webpack-plugin')
const { VueLoaderPlugin } = require('vue-loader')
const CopyWebpackPlugin = require('copy-webpack-plugin')
const MiniCssExtractPlugin = require('mini-css-extract-plugin')
const JsonMinimizerPlugin = require('json-minimizer-webpack-plugin')
const CssMinimizerPlugin = require('css-minimizer-webpack-plugin')
const ProcessLocalesPlugin = require('./ProcessLocalesPlugin')
const {
  SHAKA_LOCALE_MAPPINGS,
  SHAKA_LOCALES_PREBUNDLED,
  SHAKA_LOCALES_TO_BE_BUNDLED
} = require('./getShakaLocales')
const { sigViewTemplateParameters } = require('./sigViewConfig')

const isDevMode = process.env.NODE_ENV === 'development'

const { version: swiperVersion } = JSON.parse(fs.readFileSync(path.join(__dirname, '../node_modules/swiper/package.json')))

// iOS の Xcode プロジェクトが最終的にコピーする www ディレクトリ
const IOS_ASSETS_DIR = path.join(__dirname, '../ios/App/App/www')

const config = {
  name: 'web',
  mode: process.env.NODE_ENV,
  devtool: isDevMode ? 'eval-cheap-module-source-map' : false,
  entry: {
    web: path.join(__dirname, '../src/renderer/main.js'),
  },
  output: {
    path: IOS_ASSETS_DIR,
    filename: '[name].js',
  },
  externals: {
    // iOS 側の Swift (WKUserScript) が window.Android を注入する。
    // 既存の Android 用 JS interface と同名 API を提供することで、
    // 既存 Vue コードの `Android.xxx()` 呼び出しをそのまま動かす。
    android: 'Android'
  },
  module: {
    rules: [
      {
        test: /\.js$/,
        use: 'babel-loader',
        exclude: /node_modules/,
      },
      {
        test: /\.vue$/,
        loader: 'vue-loader',
        options: {
          compilerOptions: {
            isCustomElement: (tag) => tag === 'swiper-container' || tag === 'swiper-slide'
          }
        }
      },
      {
        test: /\.scss$/,
        use: [
          {
            loader: MiniCssExtractPlugin.loader,
          },
          {
            loader: 'css-loader',
            options: {
              esModule: false
            }
          },
          {
            loader: 'sass-loader',
            options: {
              implementation: require('sass')
            }
          },
        ],
      },
      {
        test: /\.css$/,
        use: [
          {
            loader: MiniCssExtractPlugin.loader
          },
          {
            loader: 'css-loader',
            options: {
              esModule: false
            }
          }
        ],
        rules: [
          {
            resource: path.resolve(__dirname, '../node_modules/shaka-player/dist/controls.css'),
            use: path.join(__dirname, 'patch-shaka-player-loader.js')
          }
        ]
      },
      {
        test: /\.html$/,
        use: 'vue-html-loader',
      },
      {
        test: /\.(png|jpe?g|gif|tif?f|bmp|webp|svg)(\?.*)?$/,
        type: 'asset/resource',
        generator: {
          filename: 'imgs/[name][ext]'
        }
      },
      {
        test: /\.(woff2?|eot|ttf|otf)(\?.*)?$/,
        type: 'asset/resource',
        generator: {
          filename: 'fonts/[name][ext]'
        }
      },
    ],
  },
  optimization: {
    minimizer: [
      '...',
      new JsonMinimizerPlugin({
        exclude: /\/locales\/.*\.json/
      }),
      new CssMinimizerPlugin()
    ]
  },
  node: {
    __dirname: true,
    __filename: isDevMode,
  },
  plugins: [
    new webpack.DefinePlugin({
      'process.env.IS_ELECTRON': false,
      'process.env.IS_ELECTRON_MAIN': false,
      // 既存 IS_ANDROID 分岐を iOS でも走らせる (WebView モバイルセマンティクス共通)
      'process.env.IS_ANDROID': true,
      // iOS 固有分岐用
      'process.env.IS_IOS': true,
      'process.env.IS_RELEASE': !isDevMode,
      'process.env.SUPPORTS_LOCAL_API': true,
      __VUE_OPTIONS_API__: 'true',
      __VUE_PROD_DEVTOOLS__: 'false',
      __VUE_PROD_HYDRATION_MISMATCH_DETAILS__: 'false',
      __VUE_I18N_LEGACY_API__: 'true',
      __VUE_I18N_FULL_INSTALL__: 'false',
      __INTLIFY_PROD_DEVTOOLS__: 'false',
      'process.env.SWIPER_VERSION': `'${swiperVersion}'`
    }),
    new webpack.ProvidePlugin({
      process: 'process/browser.js'
    }),
    // -----------------------------------------------------------------------
    // 既存 `helpers/android/` への import を `helpers/ios/` に自動書き換え。
    // これで既存 Vue コンポーネント側のソースを触らずに済む。
    // -----------------------------------------------------------------------
    new webpack.NormalModuleReplacementPlugin(
      /(^|[\/\\])helpers[\/\\]android([\/\\]|$)/,
      (resource) => {
        resource.request = resource.request.replace(
          /(^|[\/\\])helpers[\/\\]android([\/\\]|$)/,
          '$1helpers/ios$2'
        )
      }
    ),
    new HtmlWebpackPlugin({
      excludeChunks: ['processTaskWorker'],
      filename: 'index.html',
      template: path.resolve(__dirname, '../src/index.ejs'),
      nodeModules: false,
    }),
    new HtmlWebpackPlugin({
      filename: 'decipher.html',
      inject: false,
      templateContent: sigViewTemplateParameters.sigViewRaw,
      nodeModules: false
    }),
    new VueLoaderPlugin(),
    new MiniCssExtractPlugin({
      filename: isDevMode ? '[name].css' : '[name].[contenthash].css',
      chunkFilename: isDevMode ? '[id].css' : '[id].[contenthash].css',
    }),
    new CopyWebpackPlugin({
      patterns: [
        {
          from: path.join(__dirname, '../node_modules/swiper/modules/{a11y,navigation,pagination}-element.css').replaceAll('\\', '/'),
          to: `swiper-${swiperVersion}.css`,
          context: path.join(__dirname, '../node_modules/swiper/modules'),
          transformAll: (assets) => {
            return Buffer.concat(assets.map(asset => asset.data))
          }
        }
      ]
    })
  ],
  resolve: {
    alias: {
      // Android 版と同じ Web データストアハンドラを使う
      DB_HANDLERS_ELECTRON_RENDERER_OR_WEB$: path.resolve(__dirname, '../src/datastores/handlers/web.js'),
      'shaka-player$': 'shaka-player/dist/shaka-player.ui-es2021.js',
    },
    fallback: {
      'fs/promises': path.resolve(__dirname, '_empty.js')
    },
    extensions: ['.js', '.vue']
  },
  target: 'web',
}

const processLocalesPlugin = new ProcessLocalesPlugin({
  compress: false,
  inputDir: path.join(__dirname, '../static/locales'),
  outputDir: 'static/locales',
})
// Android 版と同じく `locales-android` をそのまま流用する
// (モバイル WebView 用の翻訳差分。名前は android のままだが内容は iOS でも適用可)
const processMobileLocales = new ProcessLocalesPlugin({
  compress: false,
  inputDir: path.join(__dirname, '../static/locales-android'),
  outputDir: 'static/locales-android',
})
config.plugins.push(
  processLocalesPlugin,
  processMobileLocales,
  new webpack.DefinePlugin({
    'process.env.LOCALE_NAMES': JSON.stringify(processLocalesPlugin.localeNames),
    'process.env.GEOLOCATION_NAMES': JSON.stringify(fs.readdirSync(path.join(__dirname, '..', 'static', 'geolocations')).map(filename => filename.replace('.json', ''))),
    'process.env.SHAKA_LOCALE_MAPPINGS': JSON.stringify(SHAKA_LOCALE_MAPPINGS),
    'process.env.SHAKA_LOCALES_PREBUNDLED': JSON.stringify(SHAKA_LOCALES_PREBUNDLED)
  }),
  new CopyWebpackPlugin({
    patterns: [
      {
        from: path.join(__dirname, '../static/pwabuilder-sw.js'),
        to: path.join(IOS_ASSETS_DIR, 'pwabuilder-sw.js'),
      },
      {
        from: path.join(__dirname, '../static'),
        to: path.join(IOS_ASSETS_DIR, 'static'),
        globOptions: {
          dot: true,
          ignore: ['**/.*', '**/locales/**', '**/locales-android/**', '**/pwabuilder-sw.js', '**/dashFiles/**', '**/storyboards/**'],
        },
      },
      {
        from: path.join(__dirname, '../node_modules/shaka-player/ui/locales', `{${SHAKA_LOCALES_TO_BE_BUNDLED.join(',')}}.json`).replaceAll('\\', '/'),
        to: path.join(IOS_ASSETS_DIR, 'static/shaka-player-locales'),
        context: path.join(__dirname, '../node_modules/shaka-player/ui/locales')
      }
    ]
  })
)


module.exports = config
