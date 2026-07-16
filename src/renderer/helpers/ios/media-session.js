// -----------------------------------------------------------------------------
// iOS 版 Media Session ブリッジ。
// Swift 側では MPRemoteCommandCenter + MPNowPlayingInfoCenter を用いた
// `MediaSessionFacade.swift` が対応する。
//
// STATE_* の数値は Android の android.media.session.PlaybackState.STATE_*
// と互換の値を維持する:
//   - STATE_PAUSED   = 2
//   - STATE_PLAYING  = 3
//   - STATE_BUFFERING = 6
// Swift 側でも同じ数値を受け取り、iOS の再生状態にマッピングする。
// -----------------------------------------------------------------------------

import android from 'android'

export const STATE_PLAYING = 3
export const STATE_PAUSED = 2
export const STATE_BUFFERING = 6

/**
 * creates a new media session / or updates the previous one
 * @param {string} title
 * @param {string} artist
 * @param {number} duration
 * @param {string?} cover
 * @returns {Promise<void>}
 */
export function createMediaSession(title, artist, duration, cover = null) {
  android.createMediaSession(title, artist, duration, cover)
}

/**
 * Updates the current media session's state
 * @param {number} state the playback state, either `STATE_PAUSED` or `STATE_PLAYING`
 * @param {number?} position playback position in milliseconds
 */
export function updateMediaSessionState(state, position = null) {
  android.updateMediaSessionState(state?.toString() || null, position?.toString() || null)
}
