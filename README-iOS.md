# FreeTube for iOS (個人フォーク)

これは [FreeTube](https://github.com/FreeTubeApp/FreeTube) を iOS デバイス
上で動かすための **個人フォーク** です。
[FreeTubeApp/FreeTubeAndroid](https://github.com/FreeTubeApp/FreeTubeAndroid)
と対称な構成で、Vue.js 製のフロントエンドを iOS ネイティブアプリの
`WKWebView` 内でホストし、JavaScript ↔ Swift ブリッジ経由で
バックグラウンド再生 / メディアセッション / ファイル I/O / PoToken 生成
などを実現しています。

## ⚠️ 前提

- **Apple の App Store で配布する予定はありません。**
  未署名の `.ipa` を artifact として GitHub Actions で吐き出すだけです。
  実機にインストールするには
  [AltStore](https://altstore.io/) / [Sideloadly](https://sideloadly.io/)
  等のサイドロードツールが別途必要です。
- 未署名のため、7 日毎の再インストールが必要 (無料 Apple ID 制限)。
- **FreeTubeAndroid が "FreeTubeCordova" というリポジトリ名で
  Cordova と誤解されがちだった反省を受け、本フォークは
  純粋なネイティブ WKWebView 実装であることを明記しています。**
  Cordova / Capacitor / React Native は使っていません。

## アーキテクチャ概要

```
┌───────────────────────────────────────────────────────────┐
│  FreeTube (Vue 3 SPA)  --- 上流と同じ                      │
│                                                            │
│  ┌─ helpers/ios/*.js  <-- NormalModuleReplacementPlugin ─┐ │
│  │  (Android版と対称、window.Android 経由で Swift 呼び出し) │ │
│  └────────────────────────────┬─────────────────────────┘ │
└─────────────────────────────────┼──────────────────────────┘
                                  ▼
        window.Android = { readFile, writeFile, ... }
                   ▲ WKUserScript 注入 (bridge.js)
                   │
                   │ webkit.messageHandlers.freetube.postMessage
                   ▼
┌──────────────────────────────────────────────────────────┐
│  FreeTubeJavaScriptInterface.swift (WKScriptMessageHandler)│
│                                                           │
│    ├── MediaSessionFacade   (MPNowPlayingInfoCenter)      │
│    ├── FileHelper           (data://, bookmark:// URI)    │
│    ├── BotGuardWebView      (隠しWKWebView, PoToken)      │
│    └── SigWebView           (隠しWKWebView, decipher)     │
└──────────────────────────────────────────────────────────┘
```

## ビルド方法

### GitHub Actions (推奨)

`main` / `development` ブランチに push、または `Actions` タブから
"Build iOS IPA" を workflow_dispatch すると、`freetube-ios-ipa` という
artifact に `freetube.ipa` が生成されます。

### ローカル (macOS のみ)

```sh
# 依存インストール
yarn install --frozen-lockfile

# Vue アプリを ios/App/App/www/ に webpack ビルド
yarn run pack:ios          # 本番
yarn run pack:ios:dev      # 開発用 (source map 付き)

# Xcode プロジェクトを生成
brew install xcodegen
cd ios && xcodegen generate

# 非署名ビルド
xcodebuild \
  -project FreeTube.xcodeproj -scheme FreeTube \
  -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM=""

# IPA 化
mkdir -p Payload
cp -R build/Build/Products/Release-iphoneos/FreeTube.app Payload/
zip -r freetube.ipa Payload
```

## 追加/変更したファイル一覧

**新規:**
- `_scripts/webpack.ios.config.js` — Vue アプリを `ios/App/App/www/` に
  ビルドする webpack config。`IS_ANDROID=true, IS_IOS=true`。
- `_scripts/webpack.botGuardScript.ios.config.js` — BotGuard スクリプト用
- `_scripts/_empty.js` — webpack fallback (Node 専用 API 用)
- `src/renderer/helpers/ios/*.js` (8 ファイル) — Android 版と対称
- `ios/` ディレクトリ全体 (XcodeGen 定義 + Swift ソース + bridge.js)
- `.github/workflows/buildIOS.yml` — GHA workflow
- `README-iOS.md` — 本ファイル

**変更:**
- `package.json` — `pack:ios`, `pack:ios:core`, `pack:ios:dev`, 
  `pack:ios:dev:core`, `pack:botGuardScript:ios` の 5 スクリプトを追加

**変更なし:**
- Vue コンポーネント (`src/renderer/**/*.vue`, `*.js`) — 一切触っていない
  - `helpers/android/*` への import は webpack の
    `NormalModuleReplacementPlugin` が `helpers/ios/*` に自動書き換え
  - 既存の `if (process.env.IS_ANDROID)` は iOS でも true になるので
    「WebView ホストのモバイル」用コードパスがそのまま動く
  - iOS 固有処理は `if (process.env.IS_IOS)` で追加可能

## リポジトリ ID の設定

`src/renderer/helpers/ios/system.js` の
```js
const REPO_ID = 'YourGitHubUser/FreeTube-iOS'
```
は、実際にフォークした GitHub のオーナー/リポジトリ名に置き換えて
ください。アプリ内のアップデート確認が正しく機能します。

## Deep link

`freetube://open?url=<youtube-url>` 形式の URL でアプリを開くと、
`SceneDelegate` → `ViewController.dispatchYouTubeLink` 経由で
JS 側にカスタムイベント `youtube-link` (detail.link) が飛びます。
`youtube.com` / `youtu.be` の URL を FreeTube で開くには、
"デフォルトのブラウザ" 設定などを別途調整する必要があります
(iOS では Universal Links の Apple 側検証が非常に厳しいため未対応)。

## 制限事項

- **`Android` を「同期戻り値」で使う API はキャッシュ経由の妥協実装**
  - `listFilesInDataDir()` / `listFilesInTree(uri)` は Swift 側が
    先にキャッシュを push しておく方式 (`bridge._dataDirListing`)。
    現状は起動直後は空配列を返すため、初回のディレクトリ列挙が
    非同期で完了するまで空リストが見える可能性あり。
- **アイコン未設定**: `Assets.xcassets/AppIcon.appiconset/Contents.json` は
  空のプレースホルダ。実配布時は 1024x1024 の PNG を追加してください。
- **アップデート通知の nightly 判定**: `helpers/ios/system.js` は
  `workflow_runs.name === 'Build iOS IPA'` で判別します。GHA の name を
  変えた場合はこちらも合わせて変更してください。

## ライセンス

上流と同じ AGPL-3.0-or-later。
