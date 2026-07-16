// -----------------------------------------------------------------------------
// iOS 版 YouTube 認証トークン (PoToken) 生成 / signature 解読ブリッジ。
//
// Android 版と同様、実際の BotGuard スクリプト実行は「隠しWebView」で
// 行う。iOS では `BotGuardWebView.swift` (非表示の WKWebView) が
// `botGuardScript.js` を読み込み、native → JS 呼び出しで PoToken を得る。
//
// signature 解読 (deciphering) も同様に `SigWebView.swift` の別 WKWebView
// が `decipher.html` を読み込んで担当する。
// -----------------------------------------------------------------------------

import android from 'android'
import { awaitAsyncResult } from './jsinterface'
import i18n from '../../i18n'

export async function generatePOToken(videoId, sessionContext) {
  const id = android.generatePOToken(videoId, sessionContext)
  return await awaitAsyncResult(id)
}

export async function runDecipherScript(id, code, timeout = 10000) {
  return new Promise(async (resolve, reject) => {
    setTimeout(() => {
      reject(new Error(i18n.global.t('Decipher Script Timed Out')))
    }, timeout)
    try {
      resolve(JSON.parse(await awaitAsyncResult(android.runDecipherScript(id, code, timeout))))
    } catch (ex) {
      reject(ex)
    }
  })
}
