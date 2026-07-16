//
//  BotGuardWebView.swift
//  FreeTube iOS
//
//  YouTube の BotGuard を実行して PoToken を得るための "隠し" WKWebView。
//  Android 版 `BotGuardWebView.kt` に対応。
//
//  仕組み:
//    - Bundle 内の `botGuardScript.js` (webpack が生成) を読み込む簡易 HTML を
//      作り、そこに評価環境として WKWebView を割り当てる。
//    - JS 側で `generatePoToken(videoId, sessionContext)` が定義されている
//      前提で、evaluateJavaScript でこれを呼ぶ。
//    - 結果を communicator.resolve/reject で JS 側 (メイン WebView) の
//      promise に届ける。
//
//  非表示 & レイアウト外配置:
//    ViewController 側で 1x1 のオフスクリーン領域に置き、isHidden=true にする。
//

import WebKit

final class BotGuardWebView: WKWebView {

    private var loaded = false
    private var pendingCalls: [() -> Void] = []

    init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        super.init(frame: .zero, configuration: config)
        navigationDelegate = self
        loadHostHTML()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// メイン WebView から `Android.generatePOToken(videoId, sessionContext)` が
    /// 呼ばれた時のエントリポイント。
    /// - Parameters:
    ///   - videoId: 動画 ID
    ///   - sessionContext: BotGuard 側に渡すセッション JSON (base64 等含む文字列)
    ///   - promiseId: JS 側の promise id
    ///   - communicator: メイン WebView 用の AsyncJSCommunicator
    func generatePOToken(videoId: String,
                         sessionContext: String,
                         promiseId: String,
                         communicator: AsyncJSCommunicator) {
        let call: () -> Void = { [weak self] in
            guard let self = self else { return }
            // ここでは JS 上に定義された global function を叩く。
            // botGuardScript.js が Promise を返すので await 相当を JS 側で書く。
            let js = """
                (async function() {
                  try {
                    const t = await generatePoToken(\(BotGuardWebView.jsString(videoId)),
                                                    \(BotGuardWebView.jsString(sessionContext)));
                    return JSON.stringify(t);
                  } catch (e) {
                    return { __error: String(e && e.message ? e.message : e) };
                  }
                })();
                """
            self.evaluateJavaScript(js) { result, err in
                if let err = err {
                    communicator.reject(promiseId, error: err.localizedDescription)
                    return
                }
                if let dict = result as? [String: Any], let e = dict["__error"] as? String {
                    communicator.reject(promiseId, error: e)
                    return
                }
                if let s = result as? String {
                    communicator.resolve(promiseId, value: s)
                } else {
                    communicator.resolve(promiseId, value: "\(result ?? "")")
                }
            }
        }

        if loaded {
            DispatchQueue.main.async(execute: call)
        } else {
            pendingCalls.append(call)
        }
    }

    // MARK: - 初期ページのロード

    private func loadHostHTML() {
        // botGuardScript.js は Bundle の www/ 配下にコピーされている。
        // ViewController と同じ理由で Bundle.main.url は使わず bundleURL
        // 直下を決め打ちする。
        let wwwDir = Bundle.main.bundleURL.appendingPathComponent("www")
        guard FileManager.default.fileExists(atPath: wwwDir.path) else {
            NSLog("[BotGuard] www/ が Bundle にない — PoToken 生成不可 (\(wwwDir.path))")
            return
        }
        // botGuardScript.js が入っているファイル名は webpack.botGuardScript.config.js
        // の output.filename に依存する。既定は `botGuardScript.js`。
        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>bg</title></head>
        <body>
          <script src="botGuardScript.js"></script>
        </body></html>
        """
        // 動的 HTML は file:// bundle と一緒に扱えないので、
        // ドキュメント読み込みは baseURL を wwwDir にして相対で解決させる。
        loadHTMLString(html, baseURL: wwwDir)
    }

    // MARK: - ヘルパ

    /// JS 文字列リテラルに安全に埋め込むためのエスケープ
    static func jsString(_ s: String) -> String {
        // JSONSerialization で1要素配列にして、両端の [] を剥がす
        if let data = try? JSONSerialization.data(withJSONObject: [s]),
           let str = String(data: data, encoding: .utf8) {
            return String(str.dropFirst().dropLast())
        }
        return "\"\""
    }
}

extension BotGuardWebView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        let pending = pendingCalls
        pendingCalls.removeAll()
        pending.forEach { $0() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("[BotGuard] navigation failed: \(error)")
    }
}
