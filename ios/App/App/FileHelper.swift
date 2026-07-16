//
//  FileHelper.swift
//  FreeTube iOS
//
//  data://xxx.db 形式の仮想 URI を FileManager のパスにマップし、
//  読み書きを行う。Android 版の `ContextExtensions.getDataDirectory`
//  + `ContentResolverExtensions.readBytes/writeBytes` 相当。
//
//  スキーム一覧:
//    - `data://filename`  → Documents/<filename>
//    - `bookmark://<uuid>`  → UIDocumentPicker で選ばれた security-scoped URL
//      をブックマークとして保存し、後で復元する仕組み。
//    - `file://...`         → 生 URL (アプリ内で完結する場合のみ)
//

import Foundation

enum WriteMode { case overwrite, append }

/// data:// / bookmark:// / file:// URI を FileManager 上のパスに解決する
struct FileHelper {

    static let dataScheme = "data://"
    static let bookmarkScheme = "bookmark://"

    // MARK: - Documents ディレクトリ

    static var documentsURL: URL {
        // .documentDirectory は Files.app にも露出する (Info.plist の
        // UIFileSharingEnabled=true & LSSupportsOpeningDocumentsInPlace=true 前提)。
        // ユーザが Files 経由でバックアップを取り出せる利点がある。
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    // MARK: - URI → URL 解決

    /// `data://foo.db` や `bookmark://uuid/foo.db` などを実 URL に変換する。
    /// bookmark 復元の失敗時は nil。
    /// - Returns: (URL, security-scoped かどうか)。true の場合、呼び出し側で
    ///   startAccessingSecurityScopedResource() を呼び、後で stop する必要がある。
    static func resolve(uri: String) -> (URL, Bool)? {
        if uri.hasPrefix(dataScheme) {
            let name = String(uri.dropFirst(dataScheme.count))
            let url = documentsURL.appendingPathComponent(name)
            return (url, false)
        }
        if uri.hasPrefix(bookmarkScheme) {
            let rest = String(uri.dropFirst(bookmarkScheme.count))
            // "uuid" もしくは "uuid/filename" 形式を許容
            let parts = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let bookmarkKey = String(parts[0])
            let subPath: String? = parts.count > 1 ? String(parts[1]) : nil
            if let base = BookmarkStore.shared.resolve(key: bookmarkKey) {
                if let sub = subPath {
                    return (base.appendingPathComponent(sub), true)
                }
                return (base, true)
            }
            return nil
        }
        if uri.hasPrefix("file://") {
            if let url = URL(string: uri) {
                return (url, false)
            }
            return nil
        }
        // フォールバック: そのまま URL 変換を試す (unlikely path)
        if let url = URL(string: uri) {
            return (url, false)
        }
        return nil
    }

    // MARK: - I/O

    static func read(uri: String) throws -> String {
        guard let (url, scoped) = resolve(uri: uri) else {
            throw NSError(domain: "FileHelper", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "URI 解決失敗: \(uri)"])
        }
        var accessGranted = false
        if scoped {
            accessGranted = url.startAccessingSecurityScopedResource()
        }
        defer { if scoped && accessGranted { url.stopAccessingSecurityScopedResource() } }

        // ファイルが無い場合は空文字を返す (Android 版の readFile と同じ挙動)
        if !FileManager.default.fileExists(atPath: url.path) {
            return ""
        }
        let data = try Data(contentsOf: url)
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func write(uri: String, content: String, mode: WriteMode) throws {
        guard let (url, scoped) = resolve(uri: uri) else {
            throw NSError(domain: "FileHelper", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "URI 解決失敗: \(uri)"])
        }
        var accessGranted = false
        if scoped {
            accessGranted = url.startAccessingSecurityScopedResource()
        }
        defer { if scoped && accessGranted { url.stopAccessingSecurityScopedResource() } }

        // 親ディレクトリ作成
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        // 中身のデコード:
        //   Android 版は `data:...;base64,...` を base64 デコードするので、
        //   iOS でも同じ挙動にする。Blob (画像等) を writeFile 経由で流し
        //   込む helpers/*/utils.blobToBase64 に対応。
        let data: Data
        if content.hasPrefix("data:"), let range = content.range(of: "base64,") {
            let base64Str = String(content[range.upperBound...])
            guard let decoded = Data(base64Encoded: base64Str) else {
                throw NSError(domain: "FileHelper", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "base64 デコード失敗"])
            }
            data = decoded
        } else {
            data = Data(content.utf8)
        }

        switch mode {
        case .overwrite:
            try data.write(to: url, options: [.atomic])
        case .append:
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: [.atomic])
            }
        }
    }

    // MARK: - リスト系

    /// Documents 直下のファイル一覧を Android の
    /// `[{uri, fileName, isFile, isDirectory}, ...]` 形式で返す。
    static func listDataDir() -> String {
        return listDirectory(url: documentsURL, uriPrefix: dataScheme)
    }

    static func listTree(bookmarkUri: String) -> String {
        guard let (url, _) = resolve(uri: bookmarkUri) else { return "[]" }
        return listDirectory(url: url, uriPrefix: bookmarkUri.hasSuffix("/") ? bookmarkUri : bookmarkUri + "/")
    }

    private static func listDirectory(url: URL, uriPrefix: String) -> String {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: url,
                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) else {
            return "[]"
        }
        let objs: [String] = items.map { child in
            let name = child.lastPathComponent
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let uri = uriPrefix + name
            return "{ \"uri\": \"\(escapeJSON(uri))\", \"fileName\": \"\(escapeJSON(name))\", \"isFile\": \(!isDir), \"isDirectory\": \(isDir) }"
        }
        return "[" + objs.joined(separator: ",") + "]"
    }

    static func createFileInDataDir(name: String) throws -> String {
        let url = documentsURL.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return dataScheme + name
    }

    // MARK: -

    private static func escapeJSON(_ s: String) -> String {
        // シンプルなエスケープ (バックスラッシュとダブルクオートのみ)
        return s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// -----------------------------------------------------------------------------
// UIDocumentPicker で選ばれた URL をブックマークとして永続保存し、
// アプリ再起動後も同じディレクトリにアクセスできるようにする。
// -----------------------------------------------------------------------------

final class BookmarkStore {
    static let shared = BookmarkStore()
    private init() { load() }

    /// key (UUID 文字列) → Bookmark Data
    private var bookmarks: [String: Data] = [:]

    private let defaultsKey = "io.freetubeapp.freetube.bookmarks"

    /// ブックマークを保存し、キー (URI 用) を返す。
    func store(_ url: URL) -> String? {
        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try url.bookmarkData(options: [],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            let key = UUID().uuidString
            bookmarks[key] = data
            save()
            return key
        } catch {
            NSLog("Bookmark 保存失敗: \(error)")
            return nil
        }
    }

    /// key を URL に戻す。stale の場合は再構築する。
    func resolve(key: String) -> URL? {
        guard let data = bookmarks[key] else { return nil }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale {
                // 再構築を試みる (失敗しても致命的ではない)
                if url.startAccessingSecurityScopedResource() {
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let refreshed = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                        bookmarks[key] = refreshed
                        save()
                    }
                }
            }
            return url
        } catch {
            NSLog("Bookmark 解決失敗: \(error)")
            return nil
        }
    }

    func remove(key: String) {
        bookmarks.removeValue(forKey: key)
        save()
    }

    // MARK: 永続化

    private func load() {
        guard let raw = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] else { return }
        bookmarks = raw
    }
    private func save() {
        UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
    }
}
