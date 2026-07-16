//
//  ViewController.swift
//  FreeTube iOS
//
//  Android 版 `MainActivity` + `FreeTubeWebView` の合体版。
//
//  役割:
//    - メインの WKWebView を全画面で保持
//    - www/index.html をローカル file:// で読み込み
//    - JS Bridge (`window.Android`) を WKUserScript で document-start に注入
//    - 双方向メッセージ (JS → Swift は `WKScriptMessageHandler`,
//      Swift → JS は `AsyncJSCommunicator`) の橋渡し
//    - 隠し WebView (`BotGuardWebView`, `SigWebView`) の作成と管理
//    - deep link (SceneDelegate 経由) を JS 側にカスタムイベントで通知
//    - ライフサイクル (background/foreground → JS 側にイベント通知)
//

import UIKit
import WebKit

final class ViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {

    // MARK: - コンポーネント

    private var mainWebView: WKWebView!
    private var jsInterface: FreeTubeJavaScriptInterface!
    private var communicator: AsyncJSCommunicator!
    private var mediaSession: MediaSessionFacade!
    private var botGuardView: BotGuardWebView!
    private var sigView: SigWebView!

    let appState = AppState()

    // MARK: - ライフサイクル

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        setupWebView()
        setupHiddenWebViews()
        loadIndex()
        setupLifecycleObservers()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        // 画面回転時のレイアウト再調整は WKWebView がフレーム追従するので不要
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // システムのダーク/ライト切り替えを JS 側に通知
        // Android 版 `MainActivity.onConfigurationChanged` 相当
        let newIsDark = traitCollection.userInterfaceStyle == .dark
        if newIsDark != appState.darkMode {
            appState.darkMode = newIsDark
            communicator?.dispatchEvent(newIsDark ? "enabled-dark-mode" : "enabled-light-mode")
        }
    }

    // MARK: - 初期セットアップ

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // WebView 内 fetch で YouTube 等にアクセスできるようにする
        // (デフォルトで OK。CORS は YouTube 側次第)

        let userController = WKUserContentController()

        // JS Bridge 注入 (document-start)
        if let bridgeURL = Bundle.main.url(forResource: "bridge",
                                           withExtension: "js",
                                           subdirectory: "JavaScript"),
           let bridgeJS = try? String(contentsOf: bridgeURL, encoding: .utf8) {
            let userScript = WKUserScript(source: bridgeJS,
                                          injectionTime: .atDocumentStart,
                                          forMainFrameOnly: true)
            userController.addUserScript(userScript)
        } else {
            NSLog("[FreeTube] bridge.js が見つからない — JS 側ブリッジは動作しない")
        }

        // JS → Swift の messageHandler。名前は bridge.js の
        // `webkit.messageHandlers.freetube.postMessage(...)` と一致させる。
        config.userContentController = userController

        mainWebView = WKWebView(frame: .zero, configuration: config)
        mainWebView.translatesAutoresizingMaskIntoConstraints = false
        mainWebView.navigationDelegate = self
        mainWebView.uiDelegate = self
        mainWebView.allowsBackForwardNavigationGestures = false
        mainWebView.scrollView.bounces = false
        mainWebView.scrollView.contentInsetAdjustmentBehavior = .never
        mainWebView.isInspectable = true  // iOS 16.4+ でのみ有効。debug 用

        view.addSubview(mainWebView)
        NSLayoutConstraint.activate([
            mainWebView.topAnchor.constraint(equalTo: view.topAnchor),
            mainWebView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mainWebView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mainWebView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // MediaSession は先に AsyncJSCommunicator を用意しないと callback で参照できないので、
        // 順序に注意する。
        communicator = AsyncJSCommunicator(webView: mainWebView)

        mediaSession = MediaSessionFacade(
            dispatchEvent: { [weak self] name in
                // MPRemoteCommandCenter からのイベントを JS 側にそのまま通知
                self?.communicator?.dispatchEvent(name)
            },
            onSeek: { [weak self] positionMs in
                // シークバー操作は 'seek-to' イベント (Android 版と互換の名前) で送る
                self?.communicator?.dispatchEvent("seek-to", key: "position", value: positionMs)
            }
        )

        jsInterface = FreeTubeJavaScriptInterface(
            webView: mainWebView,
            communicator: communicator,
            mediaSession: mediaSession,
            appState: appState,
            presenter: self,
            botGuardProvider: { [weak self] in self?.botGuardView },
            sigProvider: { [weak self] in self?.sigView }
        )

        userController.add(jsInterface, name: "freetube")

        // iOS の userInterfaceStyle を初期状態として反映しておく
        appState.darkMode = traitCollection.userInterfaceStyle == .dark
    }

    private func setupHiddenWebViews() {
        // BotGuard: PoToken 生成用の隠し WebView
        botGuardView = BotGuardWebView()
        botGuardView.frame = CGRect(x: -1, y: -1, width: 1, height: 1)
        botGuardView.isHidden = true
        view.addSubview(botGuardView)

        // Signature decipher: JS decipher コード実行用の隠し WebView
        sigView = SigWebView()
        sigView.frame = CGRect(x: -1, y: -1, width: 1, height: 1)
        sigView.isHidden = true
        view.addSubview(sigView)
    }

    private func loadIndex() {
        // Bundle 内の www/index.html を読み込む。file:// で読み込むためには
        // allowingReadAccessTo に上位ディレクトリを渡して WebView にファイル
        // 参照権限を与える必要がある。
        guard let wwwDir = Bundle.main.url(forResource: "www", withExtension: nil) else {
            NSLog("[FreeTube] www/ ディレクトリが Bundle に見つからない")
            return
        }
        let index = wwwDir.appendingPathComponent("index.html")
        mainWebView.loadFileURL(index, allowingReadAccessTo: wwwDir)
    }

    private func setupLifecycleObservers() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appWillEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification,
                                               object: nil)
    }

    @objc private func appDidEnterBackground() {
        appState.paused = true
        // Android 版 `paused` イベントに準拠
        communicator?.dispatchEvent("app-paused")
    }

    @objc private func appWillEnterForeground() {
        appState.paused = false
        communicator?.dispatchEvent("app-resumed")
    }

    // MARK: - 外部 API (SceneDelegate から呼ばれる)

    /// deep link で受け取った URL を JS 側に流す。
    /// Android 版と同じイベント名 `youtube-link` (key: link) を使う。
    func dispatchYouTubeLink(_ url: String) {
        communicator?.dispatchEvent("youtube-link", key: "link", value: url)
    }

    // MARK: - WKNavigationDelegate / WKUIDelegate

    /// 外部リンクは Safari で開く。file:// (自身) だけは中で開く。
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow); return
        }
        if url.isFileURL {
            decisionHandler(.allow); return
        }
        // 明示的なクリック (target=_blank / _self 問わず) は外部で開く
        if navigationAction.navigationType == .linkActivated {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
            return
        }
        // iframe や XHR 相当 (WebView 内で完結すべきもの) は許可
        decisionHandler(.allow)
    }

    /// target=_blank 対応。上のポリシーで拾いきれない場合の保険。
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
        return nil
    }
}
