//
//  AppDelegate.swift
//  FreeTube iOS
//
//  UIKit ベースの最小構成。SceneDelegate をエントリポイントに委譲する。
//

import UIKit
import AVFoundation

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // -----------------------------------------------------------------
        // バックグラウンド再生 (音声) を許可する AVAudioSession 設定。
        // Android 版の KeepAliveService (フォアグラウンド・サービス) 相当。
        // iOS では foreground service という概念は無く、代わりに
        // Info.plist の UIBackgroundModes=audio + AVAudioSession.category=.playback
        // が有効な間はバックグラウンドでも音声再生できる。
        // -----------------------------------------------------------------
        do {
            let session = AVAudioSession.sharedInstance()
            // Bluetooth 経由再生対応:
            //   iOS 18+ では `.allowBluetooth` が deprecated になり、
            //   `.allowBluetoothHFP` に改名された (機能は同じ)。
            //   deployment target は iOS 15.0 なので #available で振り分ける。
            let bluetoothOption: AVAudioSession.CategoryOptions
            if #available(iOS 18.0, *) {
                bluetoothOption = .allowBluetoothHFP
            } else {
                bluetoothOption = .allowBluetooth
            }
            try session.setCategory(.playback,
                                    mode: .moviePlayback,
                                    options: [.allowAirPlay, bluetoothOption])
            try session.setActive(true, options: [])
        } catch {
            NSLog("Failed to configure AVAudioSession: \(error)")
        }
        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration",
                                    sessionRole: connectingSceneSession.role)
    }
}
