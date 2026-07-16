//
//  SceneDelegate.swift
//  FreeTube iOS
//
//  UIWindow の生成、および YouTube 系 URL の deep link 受け取り担当。
//  Android 版 MainActivity の onNewIntent / onCreate の役割に相当する。
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    /// SceneDelegate → ViewController に link を伝えるための参照
    weak var rootViewController: ViewController?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let vc = ViewController()
        rootViewController = vc

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = vc
        window.makeKeyAndVisible()
        self.window = window

        // 起動時に URL が渡されていれば拾う (deep link 起動)
        if let urlCtx = connectionOptions.urlContexts.first {
            forwardOpenURL(urlCtx.url, to: vc)
        }
    }

    // MARK: - Deep link 受信

    /// アプリ起動中に URL を渡された時 (別アプリからの `freetube://` や
    /// カスタム URL ハンドラで受け取った youtube.com URL)。
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let vc = rootViewController else { return }
        for ctx in URLContexts {
            forwardOpenURL(ctx.url, to: vc)
        }
    }

    /// URL を YouTube 動画/チャネル/プレイリストの URL に正規化して、
    /// WebView 側にカスタムイベントで通知する。
    /// Android 版 `MainActivity.onNewIntent` → `webView.dispatchEvent("youtube-link", "link", url)`
    /// と同等。
    private func forwardOpenURL(_ url: URL, to vc: ViewController) {
        // youtube.com / youtu.be / freetube:// のいずれかを想定
        let normalized: String
        if url.scheme == "freetube" {
            // freetube://open?url=... 形式で受け取る想定
            normalized = url.queryValueForFirstMatch(name: "url") ?? url.absoluteString
        } else {
            normalized = url.absoluteString
        }
        vc.dispatchYouTubeLink(normalized)
    }
}

private extension URL {
    func queryValueForFirstMatch(name: String) -> String? {
        guard let comps = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return nil }
        return comps.queryItems?.first(where: { $0.name == name })?.value
    }
}
