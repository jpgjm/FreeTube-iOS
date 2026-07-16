//
//  AppState.swift
//  FreeTube iOS
//
//  Android 版 `ApplicationState.kt` 相当。
//  複数コンポーネント (WebView, MediaSession, ViewController) で共有される
//  ランタイム状態を1箇所にまとめる。
//

import UIKit

final class AppState {

    /// 現在ダークモードか (UI traits に合わせて ViewController が更新)
    var darkMode: Bool = false

    /// アプリが一時停止中か (ロック画面 / background に入った時 true)
    var paused: Bool = false

    /// FtPrompt (ネイティブ back で処理を横取りするダイアログ) を開いているか
    var isInAPrompt: Bool = false

    /// splash screen 表示を続けるか
    /// Android 版と違い iOS はプラットフォーム標準の launch screen で
    /// 賄うので、常に false でよい。
    var showSplashScreen: Bool = false
}
