// -----------------------------------------------------------------------------
// FreeTube iOS 用 JS Bridge shim (WKUserScript として document-start に注入)
//
// 目的:
//   webpack (`_scripts/webpack.ios.config.js`) は
//     externals: { android: 'Android' }
//   となっており、helpers/ios/*.js は `import android from 'android'` の
//   結果として `window.Android` を得る。
//
//   したがってこのファイルが `window.Android` を、Android 版
//   `FreeTubeJavaScriptInterface.kt` が提供するのと同じ API 形状で用意する
//   必要がある。
//
// 実装方針:
//   - すべての method は「同期的に promise ID (文字列) を返す」形にする。
//   - 実際の native 処理は `webkit.messageHandlers.freetube.postMessage`
//     経由で Swift に丸投げする (非同期)。Swift は
//     `AsyncJSCommunicator.resolve/reject` 経由で結果を JS 側に届ける。
//   - JS 側 `awaitAsyncResult(id)` は
//       1. `window.dispatchEvent(new Event(id + '-resolve'))` を待って、
//       2. `Android.getSyncMessage(id)` で結果を取り出す
//     という Android 版と同一のシーケンスで完成する。
//
// -----------------------------------------------------------------------------

(function () {
  'use strict';

  if (window.Android && window.Android.__isFreeTubeIOSBridge) {
    return; // 二重注入ガード (WebView 再利用時の保険)
  }

  // Swift 側にメッセージを送るための小さなラッパ。
  // `webkit.messageHandlers.freetube` は ViewController の初期化時に
  // `WKUserContentController.add(_:name:)` で登録される。
  function postToNative(payload) {
    _health.postCount += 1;
    _health.lastPostAt = Date.now();
    _health.lastPostName = payload && payload.name;
    try {
      window.webkit.messageHandlers.freetube.postMessage(payload);
    } catch (e) {
      // Swift bridge が未登録 (Web preview 等) の場合はコンソールに出して握りつぶす
      console.error('[FreeTubeBridge] postToNative failed:', e && e.message ? e.message : e, JSON.stringify(payload));
      if (!_health.firstError) {
        _health.firstError = 'postToNative: ' + (e && e.message ? e.message : String(e));
      }
    }
  }

  // ---- Promise ID 発番 (JS 側完結) ------------------------------------------
  var nextId = 0;
  function newPromiseId() {
    nextId += 1;
    return 'p' + nextId;
  }

  // ---- 非同期 API を1発で作るヘルパ -----------------------------------------
  // - 名前と引数 → postToNative し、promise ID を同期的に返す。
  // - 実装は全部これで賄えるので、追加 API はここに1行足すだけで済む。
  function asyncCall(name) {
    return function () {
      var args = Array.prototype.slice.call(arguments);
      var id = newPromiseId();
      postToNative({ kind: 'call', id: id, name: name, args: args });
      return id;
    };
  }

  // ---- 同期 (fire-and-forget) API を作るヘルパ ------------------------------
  // - 戻り値のいらない Media Session 更新等はこちら。
  function fireAndForget(name) {
    return function () {
      var args = Array.prototype.slice.call(arguments);
      postToNative({ kind: 'fire', name: name, args: args });
    };
  }

  // ---- 同期 (native から即答が必要) API ------------------------------------
  // - WKWebView は同期呼び出しをサポートしないので、Android 版で唯一
  //   本当に同期な `getSyncMessage(id)` と `getLogs()` は
  //   JS 側キャッシュから取り出す形にする。
  //   - `_results` に Swift が事前に値を put しておく
  //   - `getSyncMessage` は pop するだけ
  //   - `getLogs` は Swift が定期的に flush 経由で `_logs` に注入

  var _results = new Map();
  var _logs = [];

  // ---- 診断用: bridge の健全性を1つのオブジェクトに集約 -----------
  //   (診断オーバーレイからここを覗いて何が起きてるか見る)
  var _health = {
    scriptStart: Date.now(),
    scriptEnd: null,
    postCount: 0,
    lastPostAt: null,
    lastPostName: null,
    resolveCount: 0,
    lastResolveAt: null,
    webkitHandlerAvailable: false,
    androidBridgeAvailable: false,
    firstError: null
  };

  function checkWebkitHandler() {
    try {
      _health.webkitHandlerAvailable =
        !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.freetube);
    } catch (e) { _health.webkitHandlerAvailable = false; }
    return _health.webkitHandlerAvailable;
  }
  checkWebkitHandler();

  var bridge = {
    __isFreeTubeIOSBridge: true,

    // AsyncJSCommunicator が値を仕込むための JS 側ストレージ。
    _results: _results,

    // Swift 側から `_logs` に push するために公開しておく。
    _logs: _logs,

    // ------------------------------------------------------------------
    // Sync accessors
    // ------------------------------------------------------------------

    getSyncMessage: function (id) {
      if (_results.has(id)) {
        var v = _results.get(id);
        _results.delete(id);
        return v;
      }
      return null;
    },

    getLogs: function () {
      // ヘルパ側は JSON.parse する。Swift が push 済みの配列をそのまま
      // 文字列化して返せば、JSON.parse で復元される。
      try {
        return JSON.stringify(_logs);
      } catch (e) {
        return '[]';
      }
    },

    // ------------------------------------------------------------------
    // Media Session (fire-and-forget)
    // ------------------------------------------------------------------

    createMediaSession:      fireAndForget('createMediaSession'),
    updateMediaSessionState: fireAndForget('updateMediaSessionState'),
    updateMediaSessionData:  fireAndForget('updateMediaSessionData'),
    cancelMediaNotification: fireAndForget('cancelMediaNotification'),

    // ------------------------------------------------------------------
    // File I/O
    // ------------------------------------------------------------------

    readFile:        asyncCall('readFile'),
    writeFile:       asyncCall('writeFile'),
    appendFile:      asyncCall('appendFile'),

    // Directory access
    getDirectory:            asyncCall('getDirectory'),
    listFilesInDataDir:      function () {
      // Android 版はここも同期返却 (JSON string)。
      // iOS 側では Swift に非同期問い合わせして即 JSON string を返せない
      // ので、`_dataDirListing` キャッシュを Swift 側に更新してもらう。
      // 起動直後は空配列で返る。初回書き込みは helpers 側で
      // `initializeDataDirectory` が createFile を非同期でやるので問題ない。
      return bridge._dataDirListing || '[]';
    },
    listFilesInTree:         function (uri) {
      // 同上。ツリー別のキャッシュ。Swift 側が更新する。
      return (bridge._treeListings && bridge._treeListings[uri]) || '[]';
    },
    createFileInTree:        asyncCall('createFileInTree'),
    revokePermissionForTree: fireAndForget('revokePermissionForTree'),

    // Dialogs
    requestSaveDialog:            asyncCall('requestSaveDialog'),
    requestOpenDialog:            asyncCall('requestOpenDialog'),
    requestDirectoryAccessDialog: asyncCall('requestDirectoryAccessDialog'),

    // ------------------------------------------------------------------
    // System / UI
    // ------------------------------------------------------------------

    themeSystemUi:     fireAndForget('themeSystemUi'),
    openExternalLink:  fireAndForget('openExternalLink'),

    enterPromptMode:   fireAndForget('enterPromptMode'),
    exitPromptMode:    fireAndForget('exitPromptMode'),

    restart:           fireAndForget('restart'),

    // ------------------------------------------------------------------
    // YouTube 認証 (PoToken / signature 解読)
    // ------------------------------------------------------------------

    generatePOToken:   asyncCall('generatePOToken'),
    runDecipherScript: asyncCall('runDecipherScript'),

    // ------------------------------------------------------------------
    // 静的キャッシュ (Swift が更新)
    // ------------------------------------------------------------------
    _dataDirListing: '[]',
    _treeListings: {}
  };

  window.Android = bridge;

  // console API を Swift 側にも流す (getConsoleLogs 用)。
  // 循環を避けるため、元関数を差し替える方式。
  var origLog = console.log.bind(console);
  var origWarn = console.warn.bind(console);
  var origError = console.error.bind(console);

  function stringify(arg) {
    if (typeof arg === 'string') return arg;
    try { return JSON.stringify(arg); } catch (e) { return String(arg); }
  }
  function record(level, args) {
    try {
      _logs.push({
        level: level,
        time: Date.now(),
        message: Array.prototype.map.call(args, stringify).join(' ')
      });
      // メモリ節約のため上限を設ける
      if (_logs.length > 2000) { _logs.splice(0, 500); }
    } catch (e) { /* noop */ }
  }
  console.log   = function () { record('log',   arguments); origLog.apply(null, arguments); };
  console.warn  = function () { record('warn',  arguments); origWarn.apply(null, arguments); };
  console.error = function () { record('error', arguments); origError.apply(null, arguments); };

  // ---- 未処理エラーの補足 -----------------------------------------------
  // Vue 起動時に throw されたエラー、Promise の unhandled rejection を
  // 全て _logs に記録する。診断オーバーレイでここが見えれば、なぜ画面が
  // 真っ黒なのかが特定できる。
  window.addEventListener('error', function (ev) {
    try {
      var msg = 'window.onerror: ' + (ev.message || 'unknown')
              + ' @ ' + (ev.filename || '?') + ':' + (ev.lineno || '?') + ':' + (ev.colno || '?');
      if (ev.error && ev.error.stack) { msg += '\n' + ev.error.stack; }
      _logs.push({ level: 'error', time: Date.now(), message: msg });
      if (!_health.firstError) { _health.firstError = msg.split('\n')[0]; }
    } catch (e) { /* noop */ }
  }, true);
  window.addEventListener('unhandledrejection', function (ev) {
    try {
      var reason = ev.reason;
      var msg = 'unhandledrejection: '
              + (reason && reason.message ? reason.message :
                 (typeof reason === 'string' ? reason : JSON.stringify(reason)));
      if (reason && reason.stack) { msg += '\n' + reason.stack; }
      _logs.push({ level: 'error', time: Date.now(), message: msg });
      if (!_health.firstError) { _health.firstError = msg.split('\n')[0]; }
    } catch (e) { /* noop */ }
  });

  // ---- bridge の存在ロギング --------------------------------------------
  // Swift 側の診断オーバーレイが `_health` を評価するために、初期化完了時刻を
  // 記録し、bridge が生きていることをログに残す。
  _health.androidBridgeAvailable = true;
  _health.scriptEnd = Date.now();
  _logs.push({
    level: 'log',
    time: Date.now(),
    message: 'bridge.js loaded (webkitHandler=' + _health.webkitHandlerAvailable + ')'
  });

  // bridge を最後に公開 (Swift 側からのメッセージ受信より先に定義するため)
  bridge._health = _health;
})();
