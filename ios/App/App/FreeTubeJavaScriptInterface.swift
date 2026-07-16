//
//  FreeTubeJavaScriptInterface.swift
//  FreeTube iOS
//
//  bridge.js から POST された `{ kind, id, name, args }` メッセージを
//  受け取り、Swift 側の実処理を呼び分ける。Android 版
//  `FreeTubeJavaScriptInterface.kt` (488 行) の iOS 版。
//
//  実装方針:
//    - 「同期返却が必要」な API は既に bridge.js の JS 側キャッシュで対応済み
//      (getSyncMessage, getLogs, listFilesInDataDir 等)。
//    - 「promise (async)」な API は、ここで実行 → 結果を communicator.resolve/reject
//      で返す。
//    - 「fire-and-forget」な API は、そのまま実行する。
//

import UIKit
import WebKit
import UniformTypeIdentifiers

final class FreeTubeJavaScriptInterface: NSObject, WKScriptMessageHandler,
                                          UIDocumentPickerDelegate {

    // MARK: - 依存

    private weak var webView: WKWebView?
    private let communicator: AsyncJSCommunicator
    private let mediaSession: MediaSessionFacade
    private let appState: AppState
    private weak var presenter: UIViewController?

    /// 隠し WebView 参照 (循環参照回避のため getter クロージャで受ける)
    private let botGuardProvider: () -> BotGuardWebView?
    private let sigProvider: () -> SigWebView?

    /// ドキュメントピッカーの callback 待ち (uuid → promise id)
    private var pendingPickers: [String: (kind: PickerKind, promiseId: String)] = [:]

    private enum PickerKind {
        case save(fileName: String, mime: String)
        case open(mimes: [String])
        case directory
    }

    init(webView: WKWebView,
         communicator: AsyncJSCommunicator,
         mediaSession: MediaSessionFacade,
         appState: AppState,
         presenter: UIViewController,
         botGuardProvider: @escaping () -> BotGuardWebView?,
         sigProvider: @escaping () -> SigWebView?) {
        self.webView = webView
        self.communicator = communicator
        self.mediaSession = mediaSession
        self.appState = appState
        self.presenter = presenter
        self.botGuardProvider = botGuardProvider
        self.sigProvider = sigProvider
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let kind = body["kind"] as? String,
              let name = body["name"] as? String else {
            NSLog("[JSBridge] invalid message: \(message.body)")
            return
        }
        let args = (body["args"] as? [Any]) ?? []
        let promiseId = body["id"] as? String  // async の場合のみ存在

        switch kind {
        case "call":
            // async call: 結果を communicator.resolve/reject で返す
            handleAsyncCall(name: name, args: args, promiseId: promiseId ?? "")
        case "fire":
            // fire-and-forget: 呼ぶだけ
            handleFireAndForget(name: name, args: args)
        default:
            NSLog("[JSBridge] unknown kind: \(kind)")
        }
    }

    // MARK: - 非同期 API

    private func handleAsyncCall(name: String, args: [Any], promiseId: String) {
        switch name {

        // ---------------- File I/O ----------------

        case "readFile":
            guard let uri = args.first as? String else {
                communicator.reject(promiseId, error: "readFile: 引数不足"); return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                do {
                    let content = try FileHelper.read(uri: uri)
                    self.communicator.resolve(promiseId, value: content)
                } catch {
                    self.communicator.reject(promiseId, error: error.localizedDescription)
                }
            }

        case "writeFile", "appendFile":
            guard args.count >= 2,
                  let uri = args[0] as? String,
                  let content = args[1] as? String else {
                communicator.reject(promiseId, error: "\(name): 引数不足"); return
            }
            let mode: WriteMode = (name == "appendFile") ? .append : .overwrite
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                do {
                    try FileHelper.write(uri: uri, content: content, mode: mode)
                    self.communicator.resolve(promiseId, value: "OK")
                } catch {
                    self.communicator.reject(promiseId, error: error.localizedDescription)
                }
            }

        // ---------------- Directory Access ----------------

        case "getDirectory":
            // 現在の data directory 情報を返す。Android 版は URI 文字列を
            // そのまま返している。iOS も同じ挙動でよい。
            guard let uri = args.first as? String else {
                communicator.reject(promiseId, error: "getDirectory: 引数不足"); return
            }
            communicator.resolve(promiseId, value: uri)

        case "createFileInTree":
            guard args.count >= 2,
                  let treeUri = args[0] as? String,
                  let fileName = args[1] as? String else {
                communicator.reject(promiseId, error: "createFileInTree: 引数不足"); return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                // treeUri は bookmark:// スキーム前提
                // 子ファイルを touch し、その URI を返す
                let childUri = treeUri.hasSuffix("/") ? treeUri + fileName : treeUri + "/" + fileName
                do {
                    try FileHelper.write(uri: childUri, content: "", mode: .overwrite)
                    self.communicator.resolve(promiseId, value: childUri)
                } catch {
                    self.communicator.reject(promiseId, error: error.localizedDescription)
                }
            }

        // ---------------- Dialogs ----------------

        case "requestSaveDialog":
            guard args.count >= 2,
                  let fileName = args[0] as? String,
                  let mime = args[1] as? String else {
                communicator.reject(promiseId, error: "requestSaveDialog: 引数不足"); return
            }
            showSavePicker(fileName: fileName, mime: mime, promiseId: promiseId)

        case "requestOpenDialog":
            guard let mimes = args.first as? String else {
                communicator.reject(promiseId, error: "requestOpenDialog: 引数不足"); return
            }
            showOpenPicker(mimes: mimes.split(separator: ",").map(String.init),
                           promiseId: promiseId)

        case "requestDirectoryAccessDialog":
            showDirectoryPicker(promiseId: promiseId)

        // ---------------- PoToken / Sig ----------------

        case "generatePOToken":
            guard args.count >= 2,
                  let videoId = args[0] as? String,
                  let session = args[1] as? String else {
                communicator.reject(promiseId, error: "generatePOToken: 引数不足"); return
            }
            botGuardProvider()?.generatePOToken(videoId: videoId,
                                                sessionContext: session,
                                                promiseId: promiseId,
                                                communicator: communicator)

        case "runDecipherScript":
            guard args.count >= 3,
                  let id = args[0] as? String,
                  let code = args[1] as? String,
                  let timeout = args[2] as? Int else {
                communicator.reject(promiseId, error: "runDecipherScript: 引数不足"); return
            }
            sigProvider()?.runDecipherScript(id: id, code: code, timeout: timeout,
                                             promiseId: promiseId,
                                             communicator: communicator)

        default:
            NSLog("[JSBridge] unhandled async call: \(name)")
            communicator.reject(promiseId, error: "unsupported: \(name)")
        }
    }

    // MARK: - fire-and-forget API

    private func handleFireAndForget(name: String, args: [Any]) {
        switch name {

        // ---------------- Media Session ----------------

        case "createMediaSession":
            guard args.count >= 3,
                  let title = args[0] as? String,
                  let artist = args[1] as? String else { return }
            // duration は number (ms) を想定するが JS 側から Number/String 両方来る
            let duration = numberValue(args[2])
            let cover = args.count > 3 ? (args[3] as? String) : nil
            mediaSession.createMediaSession(title: title,
                                            artist: artist,
                                            durationMs: duration,
                                            thumbnailUrl: cover)

        case "updateMediaSessionState":
            let state: Int? = args.count > 0 ? Int(numberValue(args[0])) : nil
            let pos: Int64? = args.count > 1 ? numberValue(args[1]) : nil
            mediaSession.updateMediaSessionState(state: state, positionMs: pos)

        case "updateMediaSessionData":
            guard args.count >= 3,
                  let title = args[0] as? String,
                  let artist = args[1] as? String else { return }
            let duration = numberValue(args[2])
            let cover = args.count > 3 ? (args[3] as? String) : nil
            mediaSession.updateMediaSessionData(title: title,
                                                artist: artist,
                                                durationMs: duration,
                                                thumbnailUrl: cover)

        case "cancelMediaNotification":
            mediaSession.cancelMediaNotification()

        // ---------------- System UI ----------------

        case "themeSystemUi":
            // (bottomColor, topColor, isDark, isDarkTop)
            guard args.count >= 4,
                  let bottom = args[0] as? String,
                  let top = args[1] as? String,
                  let isDark = args[2] as? Bool,
                  let isDarkTop = args[3] as? Bool else { return }
            applyTheme(bottom: bottom, top: top, isDark: isDark, isDarkTop: isDarkTop)

        case "openExternalLink":
            guard let urlStr = args.first as? String,
                  let url = URL(string: urlStr) else { return }
            UIApplication.shared.open(url, options: [:], completionHandler: nil)

        case "enterPromptMode":
            appState.isInAPrompt = true

        case "exitPromptMode":
            appState.isInAPrompt = false

        case "restart":
            // iOS は自主的にプロセスを再起動できないので、内部 WebView を
            // 再読み込みすることで代替する。
            webView?.reload()

        case "revokePermissionForTree":
            // Android は SAF Uri を permanent grant から外す処理。
            // iOS は bookmark 削除で対応する。URI から key を切り出す。
            guard let uri = args.first as? String,
                  uri.hasPrefix(FileHelper.bookmarkScheme) else { return }
            let key = String(uri.dropFirst(FileHelper.bookmarkScheme.count))
                            .split(separator: "/").first.map(String.init) ?? ""
            if !key.isEmpty {
                BookmarkStore.shared.remove(key: key)
            }

        default:
            NSLog("[JSBridge] unhandled fire call: \(name)")
        }
    }

    // MARK: - ヘルパ

    /// JS からきた Number|String を Int64 ms に統一
    private func numberValue(_ v: Any) -> Int64 {
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String, let i = Int64(s) { return i }
        return 0
    }

    /// テーマカラーを status bar / safe area 背景色に反映する
    private func applyTheme(bottom: String, top: String, isDark: Bool, isDarkTop: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.presenter?.view.backgroundColor = UIColor(hexString: top) ?? .systemBackground
            // WKWebView の bounces=false なので、上下 safe area は
            // view.backgroundColor がそのまま見える。
            // status bar の文字色は overrideUserInterfaceStyle で決める。
            self.presenter?.overrideUserInterfaceStyle = isDarkTop ? .dark : .light
            self.presenter?.setNeedsStatusBarAppearanceUpdate()
        }
    }

    // MARK: - UIDocumentPicker 呼び出し

    private func showSavePicker(fileName: String, mime: String, promiseId: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let presenter = self.presenter else { return }
            // Documents に一時ファイルを作って、それをエクスポート先ピッカーに渡す
            let tmpDir = FileManager.default.temporaryDirectory
            let tmpFile = tmpDir.appendingPathComponent(fileName)
            if !FileManager.default.fileExists(atPath: tmpFile.path) {
                FileManager.default.createFile(atPath: tmpFile.path, contents: Data())
            }
            let picker = UIDocumentPickerViewController(forExporting: [tmpFile], asCopy: false)
            picker.delegate = self
            let key = UUID().uuidString
            picker.accessibilityIdentifier = key
            self.pendingPickers[key] = (.save(fileName: fileName, mime: mime), promiseId)
            presenter.present(picker, animated: true)
        }
    }

    private func showOpenPicker(mimes: [String], promiseId: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let presenter = self.presenter else { return }
            let types: [UTType] = mimes.compactMap { mime in
                UTType(mimeType: mime) ?? UTType(filenameExtension: mime)
            }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types.isEmpty ? [.data] : types,
                                                        asCopy: true)
            picker.delegate = self
            let key = UUID().uuidString
            picker.accessibilityIdentifier = key
            self.pendingPickers[key] = (.open(mimes: mimes), promiseId)
            presenter.present(picker, animated: true)
        }
    }

    private func showDirectoryPicker(promiseId: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let presenter = self.presenter else { return }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
            picker.delegate = self
            let key = UUID().uuidString
            picker.accessibilityIdentifier = key
            self.pendingPickers[key] = (.directory, promiseId)
            presenter.present(picker, animated: true)
        }
    }

    // MARK: - UIDocumentPickerDelegate

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        guard let key = controller.accessibilityIdentifier,
              let ctx = pendingPickers.removeValue(forKey: key) else { return }
        guard let url = urls.first else {
            communicator.reject(ctx.promiseId, error: "no file selected")
            return
        }
        switch ctx.kind {
        case .save(let fileName, let mime):
            let obj: [String: Any] = [
                "uri": url.absoluteString,
                "type": mime,
                "fileName": fileName
            ]
            communicator.resolve(ctx.promiseId, value: obj)

        case .open(let mimes):
            let mime = mimes.first ?? "application/octet-stream"
            // iOS はコピー版で渡されるので security-scoped は不要
            let obj: [String: Any] = [
                "uri": url.absoluteString,
                "type": mime,
                "fileName": url.lastPathComponent
            ]
            communicator.resolve(ctx.promiseId, value: obj)

        case .directory:
            if let bookmarkKey = BookmarkStore.shared.store(url) {
                let bookmarkUri = FileHelper.bookmarkScheme + bookmarkKey
                communicator.resolve(ctx.promiseId, value: bookmarkUri)
            } else {
                communicator.reject(ctx.promiseId, error: "bookmark 保存失敗")
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard let key = controller.accessibilityIdentifier,
              let ctx = pendingPickers.removeValue(forKey: key) else { return }
        communicator.resolve(ctx.promiseId, value: "USER_CANCELED")
    }
}

// MARK: - UIColor(hexString:)

private extension UIColor {
    /// "#RRGGBB" / "#RGB" / "rgb(r,g,b)" 形式を UIColor に変換する。
    convenience init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 {
            // "abc" → "aabbcc"
            s = s.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 6, let n = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((n >> 16) & 0xff) / 255.0
        let g = CGFloat((n >> 8) & 0xff) / 255.0
        let b = CGFloat(n & 0xff) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}
