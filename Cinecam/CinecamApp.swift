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
            let current = window?.windowScene?.interfaceOrientation ?? .portrait
            switch current {
            case .landscapeLeft:           return .landscapeLeft
            case .landscapeRight:          return .landscapeRight
            case .portraitUpsideDown:      return .portraitUpsideDown
            default:                       return .portrait
            }
        }
        // iPad は常に全向きを許可
        if UIDevice.current.userInterfaceIdiom == .pad {
            return .allButUpsideDown
        }
        // iPhone: カメラ起動中のみ回転を許可、それ以外は縦固定
        if OrientationLock.isCameraActive {
            return .allButUpsideDown
        }
        return .portrait
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
