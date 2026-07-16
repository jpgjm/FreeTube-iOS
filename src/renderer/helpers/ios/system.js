// -----------------------------------------------------------------------------
// iOS 版システム API ブリッジ。
//
// - updateAndroidTheme (関数名は Android 版との API 互換のためそのまま維持)
//   iOS では status bar / bottom safe area の背景色を Swift 側で
//   UIStatusBarStyle / UIWindow.tintColor 相当にマップする。
//
// - getConsoleLogs は Swift 側でメモリ内に貯めているコンソールログを返す。
//
// - getUpdateInfo は自身の GitHub リポジトリ (iOS フォーク) のリリース情報を
//   GitHub API から取得する。Android 版とは REPO_ID のみ異なる。
// -----------------------------------------------------------------------------

import android from 'android'
import { isColourDark, versionNumberGt } from './utils'
import packageDetails from '../../../../package.json'
import { marked } from 'marked'

export function updateAndroidTheme(usesMain = false) {
  const bodyStyle = getComputedStyle(document.body)
  const isDark = isColourDark(bodyStyle.getPropertyValue('--primary-text-color'))
  const isDarkTop = usesMain ? isColourDark(bodyStyle.getPropertyValue('--text-with-main-color')) : isDark
  const top = !usesMain ? bodyStyle.getPropertyValue('--card-bg-color') : bodyStyle.getPropertyValue('--primary-color')
  const bottom = bodyStyle.getPropertyValue('--side-nav-color')
  android.themeSystemUi(bottom, top, isDark, isDarkTop)
}

export function getConsoleLogs() {
  return JSON.parse(android.getLogs())
}

// iOS 用リポジトリ (README の指示通り、フォークの owner/repo に書き換える箇所)
const REPO_ID = 'YourGitHubUser/FreeTube-iOS'

/**
 * @typedef ChangeLog
 * @property {String} title
 * @property {String} body
 */

/**
 * @typedef UpdateInfo
 * @property {true} updateAvailable
 * @property {String} version
 * @property {ChangeLog} changeLog
 * @property {String} downloadLink
 */

/**
 * @typedef NoUpdateInfo
 * @property {false} updateAvailable
 */

/**
 *
 * @returns {Promise<UpdateInfo|NoUpdateInfo>}
 */
export async function getUpdateInfo() {
  try {
    const isNightly = packageDetails.version.indexOf('nightly') !== -1

    const updateUrl = isNightly
      ? `https://api.github.com/repos/${REPO_ID}/actions/runs`
      : `https://api.github.com/repos/${REPO_ID}/releases?per_page=1`

    const response = await fetch(updateUrl)
    const updatesJSON = await response.json()

    let currentVersion
    let latestVersion
    let downloadLink
    let changelogTitle
    let changelogBody

    if (!isNightly) {
      const latestRelease = updatesJSON[0]
      const tagName = latestRelease.tag_name
      currentVersion = packageDetails.version
      latestVersion = tagName
      changelogTitle = latestRelease.name
      changelogBody = latestRelease.body
        .replaceAll(/@(\S+)\b/g, '[@$1](https://github.com/$1)')
        .replaceAll(/https:\/\/github\.com\/FreeTubeApp\/FreeTube\/pull\/(\d+)/g, '[#$1]($&)')
      changelogBody = `${changelogBody}`
      changelogBody = marked.parse(changelogBody)
      downloadLink = `https://github.com/${REPO_ID}/releases`
    } else if (isNightly) {
      currentVersion = packageDetails.version.split('-nightly-')[1]
      const buildRuns = updatesJSON.workflow_runs.filter(run => run.name === 'Build iOS IPA')
      if (buildRuns.length > 0) {
        const latestRun = buildRuns[0]
        latestVersion = latestRun.run_number
        downloadLink = latestRun.html_url
        changelogTitle = `Nightly ${latestVersion}`
        changelogBody = marked.parse(`latest commit:\r\n\`\`\`\r\n${buildRuns[0].head_commit.message}\r\n\`\`\``)
      } else {
        latestVersion = currentVersion
      }
    }

    const updateAvailable = versionNumberGt(latestVersion, currentVersion)
    return {
      updateAvailable,
      version: latestVersion,
      downloadLink,
      changeLog: {
        title: changelogTitle,
        body: changelogBody
      }
    }
  } catch (error) {
    console.error('errored while checking for updates', `https://api.github.com/repos/${REPO_ID}/releases?per_page=1`, error)
    return {
      updateAvailable: false
    }
  }
}
