// -----------------------------------------------------------------------------
// FreeTube iOS 用 BotGuard スクリプトのビルド設定。
// Android 版 (`webpack.botGuardScript.android.config.js`) と対称。
// -----------------------------------------------------------------------------
const config = require('./webpack.botGuardScript.config.js')
const { join } = require('path')

// BotGuard スクリプトは iOS 側の隠し WKWebView (BotGuardWebView.swift) で
// 読み込まれる。出力先は `ios/App/App/www/` 配下 (メイン www と同じ場所)。
config.output.path = join(__dirname, '../ios/App/App/www/')

module.exports = config
