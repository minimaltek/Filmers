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
    static var isCameraActive = false  // カメラが起動しているかどうか
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        // カメラ起動中は縦画面固定
        if OrientationLock.isCameraActive {
            return .portrait
        }
        
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
        // 通常時はすべての向きを許可
        return .allButUpsideDown  // 上下逆さまを除外
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
