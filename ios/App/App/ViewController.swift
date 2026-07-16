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
        setupDiagnosticOverlay()
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

        // -----------------------------------------------------------------
        // JS Bridge 注入 (document-start)
        //
        // 注意: bridge.js は project.yml で `path: App/App/JavaScript/bridge.js`
        // として resources に個別追加されているが、Xcode の Copy Bundle
        // Resources は**サブディレクトリ構造を保持せず**バンドルルートに
        // flatten する。したがって実行時のパスは
        //   `FreeTube.app/bridge.js`
        // であって `FreeTube.app/JavaScript/bridge.js` ではない。
        //
        // 過去の実装では `Bundle.main.url(forResource:withExtension:subdirectory:)`
        // で "JavaScript" を指定していたが、それだと flatten の結果と食い違い
        // 常に nil が返り、bridge.js が注入されず window.Android が未定義に
        // なって Vue app 起動時にエラーで真っ黒画面になっていた。
        //
        // ここではフォールバックを 2 段用意し、まず期待通りサブディレクトリで
        // 見つかるならそれを使い、無ければバンドルルート直下を試す。
        // -----------------------------------------------------------------
        let bridgeCandidateURLs: [URL] = [
            Bundle.main.bundleURL.appendingPathComponent("bridge.js"),
            Bundle.main.bundleURL.appendingPathComponent("JavaScript/bridge.js")
        ]
        var bridgeJS: String? = nil
        var bridgeFoundAt: URL? = nil
        for candidate in bridgeCandidateURLs {
            if let s = try? String(contentsOf: candidate, encoding: .utf8) {
                bridgeJS = s
                bridgeFoundAt = candidate
                break
            }
        }
        if let bridgeJS = bridgeJS {
            NSLog("[FreeTube] bridge.js loaded from \(bridgeFoundAt?.path ?? "?")")
            let userScript = WKUserScript(source: bridgeJS,
                                          injectionTime: .atDocumentStart,
                                          forMainFrameOnly: true)
            userController.addUserScript(userScript)
        } else {
            NSLog("[FreeTube] bridge.js が見つからない — JS 側ブリッジは動作しない")
            self.loadErrors.append("bridge.js not found in bundle")
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
        // WKWebView.isInspectable は iOS 16.4+ でのみ利用可能。
        // deployment target は iOS 15.0 なので #available で囲む。
        // Safari Web Inspector 越しの debug 用なので、無くても production は動く。
        if #available(iOS 16.4, *) {
            mainWebView.isInspectable = true
        }

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
        // -----------------------------------------------------------------
        // Bundle 内の www/index.html を読み込む。
        //
        // 注意: 過去実装では `Bundle.main.url(forResource: "www", withExtension: nil)`
        // を使っていたが、この API はファイル資源を探すためのもので、blue
        // folder reference (project.yml で `type: folder`) に対しては nil を
        // 返すことがある。ここでは Bundle.bundleURL 直下に `www/` があると
        // 決め打ちし、直接パス構築する (project.yml で folder reference を
        // 使っているので `FreeTube.app/www/` は必ずこの位置になる)。
        //
        // 診断のため、失敗時は画面上に赤い UILabel でエラーを表示する。
        // (サイドロード環境ではコンソールログを取れないため。)
        // -----------------------------------------------------------------
        let wwwDir = Bundle.main.bundleURL.appendingPathComponent("www")
        guard FileManager.default.fileExists(atPath: wwwDir.path) else {
            let msg = "www/ ディレクトリが Bundle にない: \(wwwDir.path)"
            NSLog("[FreeTube] \(msg)")
            loadErrors.append(msg)
            showLoadErrorsOnScreen()
            return
        }
        let index = wwwDir.appendingPathComponent("index.html")
        guard FileManager.default.fileExists(atPath: index.path) else {
            let msg = "index.html が Bundle にない: \(index.path)"
            NSLog("[FreeTube] \(msg)")
            loadErrors.append(msg)
            // 参考のため、www/ に何が入っているかをログとエラー表示に含める
            if let items = try? FileManager.default.contentsOfDirectory(atPath: wwwDir.path) {
                let listed = items.prefix(20).joined(separator: ", ")
                NSLog("[FreeTube] www/ 実際の内容: \(listed)")
                loadErrors.append("www/ 実際の内容 (先頭20件): \(listed)")
            }
            showLoadErrorsOnScreen()
            return
        }
        NSLog("[FreeTube] loading \(index.path)")
        mainWebView.loadFileURL(index, allowingReadAccessTo: wwwDir)
    }

    // MARK: - 診断表示

    // MARK: - 常時ステータスオーバーレイ

    /// 画面上部に常時表示する半透明の診断バー。
    /// 起動後 30 秒間は 500ms 間隔で内容を更新し、それ以降は
    /// 3本指タップで再表示できる。真っ黒画面の原因追跡用。
    private var diagOverlay: UILabel?
    private var diagTimer: Timer?
    private var diagStartAt: Date?

    private func setupDiagnosticOverlay() {
        // ---------------------------------------------------------------
        // 診断オーバーレイ (バグ再発防止のためのメモ):
        //
        // 前実装は
        //   - 初期テキスト未設定
        //   - 高さ制約なし
        //   - numberOfLines = 0
        // だったため、Auto Layout で **高さ 0 = 完全に透明** な状態が
        // JS 評価完了までずっと続き、画面に見えなかった。
        //
        // 本実装では:
        //   1. 生成直後に必ずテキストを設定して intrinsic height を確保
        //   2. 派手な赤背景で存在を明確化 (見落とし防止)
        //   3. Swift 側だけで分かる情報 (Bundle 位置、bridge.js 発見、
        //      www 発見) を即座に反映
        //   4. WKWebView の後にaddSubview + bringSubviewToFront で
        //      z-order を確実にトップに
        //   5. JS 側 _health の取得は補足情報として重ねる (取れないなら
        //      取れないなりに、Swift のみの情報でも表示は保つ)
        // ---------------------------------------------------------------
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.textColor = .white
        label.backgroundColor = UIColor.systemRed.withAlphaComponent(0.85)  // 見落とせない色
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textAlignment = .left
        label.lineBreakMode = .byWordWrapping
        // 初期テキスト: Swift 側だけで判っている状態を即座に表示
        label.text = buildInitialDiagnosticText()

        view.addSubview(label)
        view.bringSubviewToFront(label)  // WKWebView より必ず上に
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            // 最低 80pt の高さを保証 — テキストが空でも見える
            label.heightAnchor.constraint(greaterThanOrEqualToConstant: 80)
        ])
        diagOverlay = label
        diagStartAt = Date()

        // 3本指タップで再表示 (UI が上がった後に消えたのを見返す用)
        let tap = UITapGestureRecognizer(target: self, action: #selector(reshowDiagnostics))
        tap.numberOfTouchesRequired = 3
        view.addGestureRecognizer(tap)

        // 500ms ごとに情報を書き換える。60 秒経ったら停止&自動フェード。
        diagTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateDiagnostics()
        }
    }

    /// setupWebView / loadIndex の直後に呼ばれる時点で Swift 側だけで
    /// 分かっている情報 (bridge.js 検出、www 存在) を最初に表示する。
    private func buildInitialDiagnosticText() -> String {
        var lines: [String] = ["FreeTube iOS 診断 (3本指タップ: 再表示)"]

        let bundleURL = Bundle.main.bundleURL
        lines.append("bundle: \(bundleURL.lastPathComponent)")

        let bridgeRoot = bundleURL.appendingPathComponent("bridge.js")
        let bridgeSub = bundleURL.appendingPathComponent("JavaScript/bridge.js")
        let bridgeFound = FileManager.default.fileExists(atPath: bridgeRoot.path)
            ? "root/bridge.js"
            : FileManager.default.fileExists(atPath: bridgeSub.path)
                ? "sub/JavaScript/bridge.js"
                : "NOT FOUND"
        lines.append("bridge.js: \(bridgeFound)")

        let wwwDir = bundleURL.appendingPathComponent("www")
        let wwwExists = FileManager.default.fileExists(atPath: wwwDir.path)
        lines.append("www/: \(wwwExists ? "OK" : "NOT FOUND")")

        if wwwExists {
            let index = wwwDir.appendingPathComponent("index.html")
            lines.append("index.html: \(FileManager.default.fileExists(atPath: index.path) ? "OK" : "MISSING")")
            if let items = try? FileManager.default.contentsOfDirectory(atPath: wwwDir.path) {
                lines.append("www 中身(\(items.count)件): \(items.prefix(5).joined(separator: ", "))\(items.count > 5 ? "..." : "")")
            }
        }
        lines.append("初期化直後 - WebView ロード開始待ち...")
        return lines.joined(separator: "\n")
    }

    @objc private func reshowDiagnostics() {
        diagStartAt = Date()
        diagOverlay?.alpha = 1
        diagTimer?.invalidate()
        diagTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateDiagnostics()
        }
        updateDiagnostics()
    }

    private func updateDiagnostics() {
        guard let overlay = diagOverlay else { return }
        let elapsed = Date().timeIntervalSince(diagStartAt ?? Date())
        if elapsed > 60 {
            diagTimer?.invalidate(); diagTimer = nil
            UIView.animate(withDuration: 1.0) { overlay.alpha = 0 }
            return
        }

        // Swift 側だけで判る情報を「必ず」表示する土台テキストを作る
        // (JS 評価が失敗しても、これは常に見える)
        var lines: [String] = [
            "FreeTube iOS 診断 (elapsed=\(Int(elapsed))s, 3本指タップで再表示)",
            "webView.url: \(mainWebView?.url?.absoluteString.suffix(70) ?? "(nil)")",
            "isLoading: \(mainWebView?.isLoading ?? false), estProgress: \(String(format: "%.2f", mainWebView?.estimatedProgress ?? 0))"
        ]
        if !loadErrors.isEmpty {
            lines.append("Swift errors: \(loadErrors.prefix(3).joined(separator: " | "))")
        }

        // 一旦土台テキストで即時表示 (JS 評価前でも状態は見える)
        overlay.text = lines.joined(separator: "\n")

        // JS 評価は補足情報として重ねる (失敗しても土台テキストは残る)
        let js = """
            (function(){
              var out = {
                docState: (document && document.readyState) || '?',
                bodyBg: '',
                bodyHTMLLen: 0,
                title: (document && document.title) || ''
              };
              try { out.bodyBg = document.body && getComputedStyle(document.body).backgroundColor; } catch(e) {}
              try { out.bodyHTMLLen = (document.body && document.body.innerHTML.length) || 0; } catch(e) {}
              if (window.Android && window.Android._health) {
                var h = window.Android._health;
                out.bridge = {
                  post: h.postCount || 0,
                  resolve: h.resolveCount || 0,
                  handler: h.webkitHandlerAvailable || false,
                  lastPost: h.lastPostName || '',
                  firstError: h.firstError || ''
                };
              } else {
                out.bridge = null;
              }
              if (window.Android && window.Android._logs) {
                var logs = window.Android._logs.slice(-4);
                out.logs = logs.map(function(l){
                  return '['+ l.level + '] ' + String(l.message || '').slice(0, 120);
                });
              } else {
                out.logs = [];
              }
              return JSON.stringify(out);
            })();
            """
        mainWebView?.evaluateJavaScript(js) { [weak overlay] result, err in
            guard let overlay = overlay else { return }
            var extra: [String] = []
            if let err = err {
                extra.append("evalJS err: \(err.localizedDescription.prefix(120))")
            } else if let s = result as? String, let data = s.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let docState = (obj["docState"] as? String) ?? "?"
                let bodyBg = (obj["bodyBg"] as? String) ?? "?"
                let bodyLen = (obj["bodyHTMLLen"] as? Int) ?? 0
                let title = (obj["title"] as? String) ?? ""
                extra.append("doc=\(docState) bg=\(bodyBg) htmlLen=\(bodyLen) title=\(title.prefix(30))")
                if let b = obj["bridge"] as? [String: Any] {
                    let post = (b["post"] as? Int) ?? 0
                    let resolve = (b["resolve"] as? Int) ?? 0
                    let handler = (b["handler"] as? Bool) ?? false
                    let lastPost = (b["lastPost"] as? String) ?? ""
                    let firstErr = (b["firstError"] as? String) ?? ""
                    extra.append("bridge: post=\(post) resolve=\(resolve) handler=\(handler) lastPost=\(lastPost)")
                    if !firstErr.isEmpty {
                        extra.append("bridge.firstError: \(firstErr.prefix(200))")
                    }
                } else {
                    extra.append("bridge: window.Android 未定義")
                }
                if let logs = obj["logs"] as? [String], !logs.isEmpty {
                    extra.append("logs:")
                    extra.append(contentsOf: logs.map { "  " + $0 })
                }
            } else {
                extra.append("evalJS: 結果なし")
            }
            // 土台テキスト + JS 追加情報
            var combined = lines
            combined.append(contentsOf: extra)
            overlay.text = combined.joined(separator: "\n")
        }
    }

    /// setupWebView / loadIndex で見つけた不整合を溜めておくバッファ。
    /// showLoadErrorsOnScreen で UILabel に流し込む。
    private var loadErrors: [String] = []
    private var errorLabel: UILabel?

    /// サイドロード環境向けのオンスクリーン診断表示。
    /// WebView が真っ黒になった時、何が起きているかをユーザに見せる。
    private func showLoadErrorsOnScreen() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.errorLabel == nil {
                let label = UILabel()
                label.translatesAutoresizingMaskIntoConstraints = false
                label.numberOfLines = 0
                label.textColor = .white
                label.backgroundColor = UIColor.red.withAlphaComponent(0.85)
                label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                label.textAlignment = .left
                label.lineBreakMode = .byWordWrapping
                self.view.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
                    label.trailingAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
                    // 診断オーバーレイの下に配置する
                    label.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor, constant: 180)
                ])
                self.errorLabel = label
            }
            let body = self.loadErrors.enumerated()
                .map { "[\($0.offset + 1)] \($0.element)" }
                .joined(separator: "\n")
            self.errorLabel?.text = "FreeTube iOS 起動時エラー\n\n\(body)"
        }
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

    // MARK: - WKNavigationDelegate: 読み込み結果の可視化

    /// index.html までは辿り着いたが、その先の遷移(内部ナビゲーション)で失敗
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let msg = "WKWebView didFail: \(error.localizedDescription)"
        NSLog("[FreeTube] \(msg)")
        loadErrors.append(msg)
        showLoadErrorsOnScreen()
    }

    /// index.html を開くリクエスト自体が失敗したケース
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let msg = "WKWebView didFailProvisionalNavigation: \(error.localizedDescription)"
        NSLog("[FreeTube] \(msg)")
        loadErrors.append(msg)
        showLoadErrorsOnScreen()
    }

    /// 通常時の成功ログ (診断用)
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSLog("[FreeTube] WKWebView didFinish: \(webView.url?.absoluteString ?? "(nil url)")")
        // ここまで来て真っ黒なら JS 側で例外が起きている可能性が高い。
        // WebView 内 console.error を吸い上げるため、bridge.js が
        // console 系を _logs に貯めているのを起動 5 秒後に画面表示に流す。
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.dumpJSLogsIfBlank()
        }
    }

    /// 起動5秒後にまだ何も見えない (視覚的に黒) 場合、JS 側のログを
    /// 引き出して画面に表示する。真っ黒の原因が JS 例外なら、ここで
    /// エラースタックが見える。
    private func dumpJSLogsIfBlank() {
        mainWebView.evaluateJavaScript("(window.Android && window.Android._logs) ? JSON.stringify(window.Android._logs.slice(-30)) : 'no logs'") { [weak self] result, err in
            guard let self = self else { return }
            if let err = err {
                self.loadErrors.append("evalJS logs failed: \(err.localizedDescription)")
                self.showLoadErrorsOnScreen()
                return
            }
            if let s = result as? String, s != "no logs" && s != "[]" {
                self.loadErrors.append("JS console (last 30): \(s.prefix(1200))")
                self.showLoadErrorsOnScreen()
            }
        }
    }
}
