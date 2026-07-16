//
//  SigWebView.swift
//  FreeTube iOS
//
//  YouTube の signature 解読 (decipher) 用 JS を隔離実行するための
//  "隠し" WKWebView。Android 版 `SigWebView.kt` に対応。
//
//  仕組み:
//    - Bundle 内の `decipher.html` (webpack.ios.config.js が
//      HtmlWebpackPlugin で生成) を load する。
//    - JS 側で `runDecipherScript(code, timeout)` global 関数が定義されて
//      いる前提で、Swift から evaluateJavaScript でそれを呼ぶ。
//    - timeout はここでも Swift 側でセットしておく (念のため二重防御)。
//

import WebKit

final class SigWebView: WKWebView {

    private var loaded = false
    private var pendingCalls: [() -> Void] = []

    init() {
        let config = WKWebViewConfiguration()
        super.init(frame: .zero, configuration: config)
        navigationDelegate = self
        loadDecipherHTML()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// メイン WebView から `Android.runDecipherScript(id, code, timeout)` が
    /// 呼ばれた時のエントリポイント。
    func runDecipherScript(id: String,
                           code: String,
                           timeout: Int,
                           promiseId: String,
                           communicator: AsyncJSCommunicator) {
        let call: () -> Void = { [weak self] in
            guard let self = self else { return }
            let js = """
                (async function() {
                  try {
                    const t = await runDecipherScript(\(BotGuardWebView.jsString(id)),
                                                     \(BotGuardWebView.jsString(code)),
                                                     \(timeout));
                    return JSON.stringify(t);
                  } catch (e) {
                    return { __error: String(e && e.message ? e.message : e) };
                  }
                })();
                """

            var didFinish = false
            let deadline = DispatchTime.now() + .milliseconds(timeout + 500)
            DispatchQueue.main.asyncAfter(deadline: deadline) {
                if !didFinish {
                    didFinish = true
                    communicator.reject(promiseId, error: "decipher timeout (native side)")
                }
            }

            self.evaluateJavaScript(js) { result, err in
                if didFinish { return }
                didFinish = true
                if let err = err {
                    communicator.reject(promiseId, error: err.localizedDescription); return
                }
                if let dict = result as? [String: Any], let e = dict["__error"] as? String {
                    communicator.reject(promiseId, error: e); return
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

    // MARK: - decipher.html ロード

    private func loadDecipherHTML() {
        guard let wwwDir = Bundle.main.url(forResource: "www", withExtension: nil) else {
            NSLog("[Sig] www/ が Bundle にない")
            return
        }
        let decipher = wwwDir.appendingPathComponent("decipher.html")
        if FileManager.default.fileExists(atPath: decipher.path) {
            loadFileURL(decipher, allowingReadAccessTo: wwwDir)
        } else {
            NSLog("[Sig] decipher.html が見つからない")
        }
    }
}

extension SigWebView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        let pending = pendingCalls
        pendingCalls.removeAll()
        pending.forEach { $0() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("[Sig] navigation failed: \(error)")
    }
}
