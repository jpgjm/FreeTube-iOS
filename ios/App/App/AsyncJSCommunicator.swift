//
//  AsyncJSCommunicator.swift
//  FreeTube iOS
//
//  Android 版 `AsyncJSCommunicator.kt` 相当。
//
//  役割:
//    Swift 側で非同期に取得した結果を、JS 側の
//    `awaitAsyncResult(promiseId)` (`helpers/ios/jsinterface.js`) に
//    渡す。JS 側は以下の 2 ステップで結果を得るため、Swift は同じ流れで
//    メッセージを届ける必要がある:
//
//      1. `window.Android._results[promiseId] = <値>` を JS heap にセット
//      2. `window.dispatchEvent(new Event(promiseId + '-resolve'))`
//         (エラーの場合は `-reject`)
//
//  なお `getSyncMessage(id)` は Android 版と同じく "1度きりの取り出し" の
//  セマンティクスにしてあるため (bridge.js で pop 実装)、Swift 側は
//  取り出し済みかどうかを気にしなくてよい。
//

import WebKit
import Foundation

final class AsyncJSCommunicator {
    /// WebView 参照は循環参照を避けるため weak。実際の呼び出し時に unowned
    /// でも良いが、初期化直後 nil のケースがあり得るので weak にする。
    weak var webView: WKWebView?

    init(webView: WKWebView) {
        self.webView = webView
    }

    // MARK: - Promise 解決 API

    /// 成功結果を JS 側に届ける。
    /// - Parameters:
    ///   - promiseId: JS 側が返した ID (`awaitAsyncResult` が待っている)
    ///   - value: 任意の値。String / Int / Bool / [String: Any] / null など。
    func resolve(_ promiseId: String, value: Any?) {
        dispatch(promiseId: promiseId, kind: "resolve", value: value)
    }

    /// 失敗を JS 側に届ける。
    /// - Parameters:
    ///   - promiseId: JS 側が返した ID
    ///   - error: エラー文字列 (Android 版と同じく string 前提)
    func reject(_ promiseId: String, error: String) {
        dispatch(promiseId: promiseId, kind: "reject", value: error)
    }

    // MARK: - CustomEvent 一般ディスパッチ
    // Android 版 `webView.dispatchEvent(name, key, value)` 相当。
    // FreeTube 側の window.addEventListener('youtube-link', ...) 等に対応する。

    /// key-value 付きの CustomEvent を発火する。
    func dispatchEvent(_ eventName: String, key: String? = nil, value: Any? = nil) {
        var detailJson = "null"
        if let key = key {
            let obj: [String: Any] = [key: value ?? NSNull()]
            detailJson = encodeJson(obj)
        }
        let js = """
            (function(){
              try {
                var ev = new CustomEvent(\(quote(eventName)), { detail: \(detailJson) });
                window.dispatchEvent(ev);
              } catch(e) { console.error('dispatchEvent failed', e); }
            })();
            """
        evaluate(js)
    }

    // MARK: - 内部処理

    private func dispatch(promiseId: String, kind: String, value: Any?) {
        // JS 側: `window.Android._results[promiseId] = <val>` を仕込んでから
        // `window.dispatchEvent(new Event(promiseId + '-resolve'|'-reject'))`
        //
        // JSON エンコード可能な値なら String/Number/Bool/Object/Array いずれも
        // そのまま JS 値として渡せる。null もそのまま。
        let jsonValue = encodeJson(value)
        let js = """
            (function(){
              try {
                if (!window.Android) { console.error('Android bridge missing'); return; }
                window.Android._results.set(\(quote(promiseId)), \(jsonValue));
                if (window.Android._health) {
                  window.Android._health.resolveCount = (window.Android._health.resolveCount || 0) + 1;
                  window.Android._health.lastResolveAt = Date.now();
                }
                window.dispatchEvent(new Event(\(quote(promiseId + "-" + kind))));
              } catch(e) { console.error('dispatch bridge failed', e); }
            })();
            """
        evaluate(js)
    }

    /// JS 上の文字列リテラルとして安全に埋め込む
    private func quote(_ s: String) -> String {
        // JSONSerialization に配列 [s] を通すことで安全にエスケープさせ、
        // 前後の [] を剥がす
        guard let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
              let str = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        // "[\"...\"]" → "\"...\""
        return String(str.dropFirst().dropLast())
    }

    /// 任意の値を JSON 表現の String にする。JSON 化不能なら "null"。
    private func encodeJson(_ value: Any?) -> String {
        guard let v = value else { return "null" }
        // JSONSerialization は Array / Dictionary をトップにしか受け付けない
        // ので、配列でラップしてから剥がす方式にする。
        do {
            let data = try JSONSerialization.data(withJSONObject: [v], options: [])
            guard let str = String(data: data, encoding: .utf8) else { return "null" }
            return String(str.dropFirst().dropLast())
        } catch {
            // 文字列にフォールバック
            if let s = v as? String {
                return quote(s)
            }
            return "null"
        }
    }

    private func evaluate(_ js: String) {
        // メインスレッドで実行する必要がある。バックグラウンドから呼ばれる
        // ケースが多いので、常に main dispatch する。
        DispatchQueue.main.async { [weak webView] in
            webView?.evaluateJavaScript(js, completionHandler: { _, err in
                if let err = err {
                    NSLog("evaluateJavaScript error: \(err)")
                }
            })
        }
    }
}
