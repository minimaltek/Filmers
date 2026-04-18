//
//  FilmersApp.swift
//  Filmers
//
//  Created by minimaltek on 2026/02/16.
//

import SwiftUI

// 録画中かどうかをアプリ全体で共有するフラグ
// AppDelegate から参照するためにグローバルで持つ
enum OrientationLock {
    static var isRecording = false {
        didSet { notifyOrientationChange() }
    }
    /// カメラ起動中フラグ（撮影画面では回転許可、それ以外は縦固定）
    static var isCameraActive = false {
        didSet { notifyOrientationChange() }
    }
    
    /// supportedInterfaceOrientations の変更をシステムに通知
    static func notifyOrientationChange() {
        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let rootVC = windowScene.windows.first?.rootViewController else { return }
            rootVC.setNeedsUpdateOfSupportedInterfaceOrientations()
            
            // iPhone: カメラ停止時に横向きだった場合、強制的に縦に戻す
            if !isCameraActive && UIDevice.current.userInterfaceIdiom != .pad {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 起動直後にorientation制約を評価させ、一瞬横になるのを防ぐ
        DispatchQueue.main.async {
            OrientationLock.notifyOrientationChange()
        }
        return true
    }
    
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
struct FilmersApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
