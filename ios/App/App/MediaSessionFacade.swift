//
//  MediaSessionFacade.swift
//  FreeTube iOS
//
//  Android 版 `MediaSessionFacade.kt` の iOS 版。
//
//  Android では MediaSession + Notification でロック画面/コントロール
//  センターを表示するが、iOS では以下の 2 つが対応する:
//    - MPNowPlayingInfoCenter: ロック画面 / コントロールセンターに
//      表示されるメタデータ (タイトル・アーティスト・アートワーク・進捗)
//    - MPRemoteCommandCenter: play/pause/next/previous/seek のハンドラ
//
//  JS 側 API (Android 版と同じ):
//    createMediaSession(title, artist, duration, cover)   -- 新規/更新
//    updateMediaSessionState(state, position)             -- 再生状態
//    updateMediaSessionData(title, artist, duration, cover) -- メタデータのみ
//    cancelMediaNotification()                            -- 破棄
//
//  state コードは Android の PlaybackState.STATE_* を踏襲:
//    2 = paused, 3 = playing, 6 = buffering
//

import Foundation
import MediaPlayer
import UIKit

final class MediaSessionFacade {

    // MARK: - コンストラクタ

    /// - Parameters:
    ///   - dispatchEvent: JS 側にイベントを送るコールバック
    ///     (例: `play`, `pause`, `next`, `previous`)
    ///   - onSeek: シークバー操作時に position(ms) を渡すコールバック
    init(dispatchEvent: @escaping (String) -> Void,
         onSeek: @escaping (Int64) -> Void) {
        self.dispatchEvent = dispatchEvent
        self.onSeek = onSeek
        registerRemoteCommands()
    }

    deinit {
        MPRemoteCommandCenter.shared().playCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().pauseCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().nextTrackCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().previousTrackCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.removeTarget(nil)
    }

    // MARK: - JS からの操作 (bridge 経由で呼ばれる)

    /// 新規セッション or メタデータ更新。
    /// Android 版と同じく、状態は paused で始める。
    func createMediaSession(title: String,
                            artist: String,
                            durationMs: Int64,
                            thumbnailUrl: String?) {
        currentTitle = title
        currentArtist = artist
        currentDurationMs = durationMs
        currentThumbnailUrl = thumbnailUrl
        currentState = STATE_PAUSED
        currentPositionMs = 0
        pushNowPlayingInfo(withArtwork: nil)
        // アートワークは非同期に取得後、再度 push する
        if let urlStr = thumbnailUrl, let url = URL(string: urlStr) {
            fetchArtwork(url: url) { [weak self] image in
                guard let self = self else { return }
                if title == self.currentTitle {   // まだ同じ曲なら反映
                    self.pushNowPlayingInfo(withArtwork: image)
                }
            }
        }
    }

    /// 再生状態のみ更新。position は nil ならこちらでは触らない。
    func updateMediaSessionState(state: Int?, positionMs: Int64?) {
        if let s = state { currentState = s }
        if let p = positionMs { currentPositionMs = p }
        pushNowPlayingInfo(withArtwork: cachedArtwork)
    }

    /// メタデータのみ更新 (曲は同じで chapter だけ変わった等の想定)。
    func updateMediaSessionData(title: String,
                                artist: String,
                                durationMs: Int64,
                                thumbnailUrl: String?) {
        currentTitle = title
        currentArtist = artist
        currentDurationMs = durationMs
        if thumbnailUrl != currentThumbnailUrl {
            currentThumbnailUrl = thumbnailUrl
            cachedArtwork = nil
            if let urlStr = thumbnailUrl, let url = URL(string: urlStr) {
                fetchArtwork(url: url) { [weak self] image in
                    guard let self = self else { return }
                    if title == self.currentTitle {
                        self.pushNowPlayingInfo(withArtwork: image)
                    }
                }
            }
        }
        pushNowPlayingInfo(withArtwork: cachedArtwork)
    }

    func cancelMediaNotification() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        cachedArtwork = nil
    }

    // MARK: - 内部状態

    private let dispatchEvent: (String) -> Void
    private let onSeek: (Int64) -> Void

    // Android PlaybackState.STATE_* との互換値
    private let STATE_PAUSED = 2
    private let STATE_PLAYING = 3
    private let STATE_BUFFERING = 6

    private var currentTitle: String = ""
    private var currentArtist: String = ""
    private var currentDurationMs: Int64 = 0
    private var currentPositionMs: Int64 = 0
    private var currentThumbnailUrl: String? = nil
    private var currentState: Int = 2  // paused
    private var cachedArtwork: UIImage? = nil

    // MARK: - MPRemoteCommandCenter 登録

    private func registerRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()

        // 一旦全部無効化してから、必要なものだけ有効化する
        c.playCommand.isEnabled = true
        c.pauseCommand.isEnabled = true
        c.nextTrackCommand.isEnabled = true
        c.previousTrackCommand.isEnabled = true
        c.changePlaybackPositionCommand.isEnabled = true

        c.playCommand.addTarget { [weak self] _ in
            self?.dispatchEvent("play"); return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            self?.dispatchEvent("pause"); return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            self?.dispatchEvent("next"); return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            self?.dispatchEvent("previous"); return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let ev = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let ms = Int64(ev.positionTime * 1000.0)
            self.currentPositionMs = ms
            self.onSeek(ms)
            return .success
        }
    }

    // MARK: - 現在情報を MPNowPlayingInfoCenter に押し込む

    private func pushNowPlayingInfo(withArtwork art: UIImage?) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentTitle,
            MPMediaItemPropertyArtist: currentArtist,
            MPMediaItemPropertyPlaybackDuration: Double(currentDurationMs) / 1000.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(currentPositionMs) / 1000.0,
            MPNowPlayingInfoPropertyPlaybackRate: currentState == STATE_PLAYING ? 1.0 : 0.0
        ]
        if let art = art {
            let artwork = MPMediaItemArtwork(boundsSize: art.size) { _ in art }
            info[MPMediaItemPropertyArtwork] = artwork
            cachedArtwork = art
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - アートワーク取得

    private func fetchArtwork(url: URL, completion: @escaping (UIImage?) -> Void) {
        // シンプルな one-shot DL。キャッシュは MPNowPlayingInfoCenter が持つので
        // ここでは何もキャッシュしない (曲が変わる度に必要な分だけ取る)。
        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            var img: UIImage? = nil
            if let data = data { img = UIImage(data: data) }
            DispatchQueue.main.async { completion(img) }
        }
        task.resume()
    }
}
