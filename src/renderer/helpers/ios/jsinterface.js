// -----------------------------------------------------------------------------
// iOS 版 JS <-> Native ブリッジのユーティリティ。
//
// Android 版と同じ「非同期処理を promise ID で紐付ける」パターンをそのまま
// 採用する。iOS 側の Swift (`FreeTubeJavaScriptInterface.swift`) と、
// WKUserScript で挿入される `window.Android` shim が Android と同形の
// API (メソッドが同期的に promise ID を返し、後で結果を getSyncMessage で
// 取得できる) を提供しているため、Android 版と同じロジックで動く。
//
// なぜ import 名が `android` のままか:
//   iOS 版 webpack config で `externals: { android: 'Android' }` を
//   Android 版と共有しており、`window.Android` を iOS 側で注入している。
//   これにより既存 Vue コンポーネントの `Android.foo()` 直接呼び出しとも
//   互換性が保たれる。
// -----------------------------------------------------------------------------

import android from 'android'

/**
 *
 * @param {String} id the result of a js interface async function
 * @returns {Promise<String>}
 */
export function awaitAsyncResult(id) {
  return new Promise((resolve, reject) => {
    const resolveWrapper = () => {
      resolve(android.getSyncMessage(id))
      window.removeEventListener(`${id}-resolve`, resolveWrapper)
      window.removeEventListener(`${id}-reject`, rejectWrapper)
    }
    window.addEventListener(`${id}-resolve`, resolveWrapper)
    const rejectWrapper = () => {
      reject(android.getSyncMessage(id))
      window.removeEventListener(`${id}-resolve`, resolveWrapper)
      window.removeEventListener(`${id}-reject`, rejectWrapper)
    }
    window.addEventListener(`${id}-reject`, rejectWrapper)
  })
}
