//
//  CinecamApp.swift
//  Cinecam
//
//  Created by minimaltek on 2026/02/16.
//

import SwiftUI

// 録画中かどうかをアプリ全体で共有するフラグ
// AppDelegate から参照するためにグローバルで持つ
enum OrientationLock {
    static var isRecording = false
    /// カメラ起動中フラグ（画面回転を縦固定にする）
    static var isCameraActive = false
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        // 録画中は現在の向きに固定（回転を禁止）
        if OrientationLock.isRecording {
            // 現在の画面向きを取得して、その向きだけを許可する
            let current = window?.windowScene?.interfaceOrientation ?? .portrait
            switch current {
            case .landscapeLeft:           return .landscapeLeft
            case .landscapeRight:          return .landscapeRight
            case .portraitUpsideDown:      return .portraitUpsideDown
            default:                       return .portrait
            }
        }
        // カメラ起動中も回転を許可（プレビューが端末の向きに追従する）
        // 通常時・カメラ起動中ともに全向きを許可
        return .allButUpsideDown
    }
}

@main
struct CinecamApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
