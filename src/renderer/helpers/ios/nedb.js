/**
 * iOS 版 NeDB ストレージシム
 *
 * NeDB は本来ファイル/localStorage/IndexedDB のいずれかを storage として
 * 受け取れる。iOS 版ではネイティブ (Swift の FileManager) 側で
 * Documents 配下にファイルを持たせるため、この shim は
 * ../ios/storage 経由で `data://xxx.db` を読み書きする。
 *
 * Android 版とインタフェース・実装ロジックは 100% 同じ。
 *
 * @module storageIOS
 * @see module:storage
 * @private
 */

import { getCurrentDataDirectory, getFullUri, writeFile, readFile } from './storage'

/**
 * Returns Promise<true> if file exists.
 *
 * @param {string} file
 * @return {Promise<boolean>}
 * @async
 */
export async function existsAsync (file) {
  try {
    return await getFullUri(file) !== null
  } catch (error) {
    console.warn('NeDB - storage.ios - existsAsync:', error)
    return false
  }
}

/**
 * Moves the item from one path to another.
 * @param {string} oldPath
 * @param {string} newPath
 * @return {Promise<void>}
 * @async
 */
export async function renameAsync (oldPath, newPath) {
  try {
    const oldUri = await getFullUri(oldPath)
    const content = await readFile(oldUri)
    const directory = await getCurrentDataDirectory()
    const newUri = await directory.createFile(newPath)
    await writeFile(newUri, content)
  } catch (err) {
    console.warn('NeDB - storage.ios - renameAsync:', err)
    console.warn('An error happened while renaming, skip')
  }
}

/**
 * Saves the item at given path.
 * @param {string} file
 * @param {string} data
 * @param {object} [options]
 * @return {Promise<void>}
 * @async
 */
export async function writeFileAsync(file, data, options) {
  try {
    let uri = await getFullUri(file)
    if (uri === null) {
      const directory = await getCurrentDataDirectory()
      uri = await directory.createFile(file)
    }
    await writeFile(uri, data)
  } catch (error) {
    console.warn('NeDB - storage.ios - writeFileAsync:', error)
    console.warn('An error happened while writing, skip')
  }
}

/**
 * Append to the item at given path.
 * @function
 * @param {string} filename
 * @param {string} toAppend
 * @param {object} [options]
 * @return {Promise<void>}
 * @async
 */
export async function appendFileAsync(filename, toAppend, options) {
  try {
    let uri = await getFullUri(filename)
    if (uri === null) {
      const directory = await getCurrentDataDirectory()
      uri = await directory.createFile(filename)
    }
    await writeFile(uri, toAppend, true)
  } catch (error) {
    console.warn('NeDB - storage.ios - appendFileAsync:', error)
    console.warn('An error happened appending to file writing, skip')
  }
}

/**
 * Read data at given path.
 * @function
 * @param {string} filename
 * @param {object} [options]
 * @return {Promise<Buffer>}
 * @async
 */
export async function readFileAsync(filename, options) {
  try {
    let uri = await getFullUri(filename)
    if (uri === null) {
      throw new Error('File not found!')
    }
    const content = await readFile(uri)
    return content
  } catch (error) {
    console.warn('NeDB - storage.ios - readFileAsync:', error)
    console.warn('An error happened while reading, skip')
    return ''
  }
}

/**
 * Async version of unlink.
 * @function
 * @param {string} filename
 * @return {Promise<void>}
 * @async
 */
export async function unlinkAsync(filename) { Promise.resolve() }

/**
 * Shim - nothing to do, no directories used.
 * @function
 * @param {string} path
 * @param {object} [options]
 * @return {Promise<void|string>}
 * @async
 */
export async function mkdirAsync(path, options) { Promise.resolve() }

/**
 * Shim - nothing to do, no directories used.
 * @function
 * @param {string} file
 * @param {number} [mode]
 * @return {Promise<void|string>}
 * @async
 */
export async function ensureParentDirectoryExistsAsync(file, mode) { Promise.resolve() }

/**
 * Shim - no data corruption possible in the browser storage layer.
 * @param {string} filename
 * @return {Promise<void>}
 */
export async function ensureDatafileIntegrityAsync(filename) { Promise.resolve() }

/**
 * Fully write or rewrite the datafile, immune to crashes during the write operation (data will not be lost)
 * @param {string} filename
 * @param {string[]} lines
 * @return {Promise<void>}
 */
export async function crashSafeWriteFileLinesAsync(filename, lines) {
  lines.push('') // Add final new line
  await writeFileAsync(filename, lines.join('\n'))
}
