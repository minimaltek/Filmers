//
//  CameraUtilities.swift
//  Cinecam
//
//  共通のユーティリティ関数と定数
//

import Foundation
import AVFoundation

// MARK: - Preview Detection

enum PreviewDetection {
    /// Canvas / SwiftUI Preview で実行中かどうか
    static var isRunningForPreviews: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        #else
        return false
        #endif
    }
}

// MARK: - Time Formatting

enum TimeFormatter {
    /// 録画時間を "HH:MM:SS" 形式でフォーマット
    static func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
    
    /// 録画時間を "MM:SS" 形式でフォーマット
    static func formatDurationShort(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Camera Helpers

enum CameraHelper {
    /// フロント/バックのカメラをトグル
    static func toggleFrontBackCamera(
        currentCamera: AVCaptureDevice?,
        cameraManager: CameraManager
    ) {
        if PreviewDetection.isRunningForPreviews { return }
        
        let currentPosition = currentCamera?.position ?? .back
        let targetPosition: AVCaptureDevice.Position = (currentPosition == .back) ? .front : .back
        
        if let target = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: targetPosition
        ) {
            cameraManager.switchCamera(to: target)
        }
    }
    
    /// カメラデバイスタイプのズームラベルを取得
    static func zoomLabel(for deviceType: AVCaptureDevice.DeviceType) -> String {
        switch deviceType {
        case .builtInUltraWideCamera:
            return "0.5×"
        case .builtInWideAngleCamera:
            return "1×"
        case .builtInTelephotoCamera:
            return "2×"
        default:
            return "1×"
        }
    }
    
    /// カメラデバイスタイプのアイコンを取得
    static func icon(for deviceType: AVCaptureDevice.DeviceType) -> String {
        switch deviceType {
        case .builtInUltraWideCamera:
            return "circle.hexagonpath"
        case .builtInWideAngleCamera:
            return "camera.fill"
        case .builtInTelephotoCamera:
            return "camera.aperture"
        case .builtInTripleCamera, .builtInDualCamera, .builtInDualWideCamera:
            return "camera.metering.multispot"
        default:
            return "camera"
        }
    }
    
    /// カメラデバイスタイプのラベルを取得
    static func label(for deviceType: AVCaptureDevice.DeviceType) -> String {
        switch deviceType {
        case .builtInUltraWideCamera:
            return "超広角\n(0.5x)"
        case .builtInWideAngleCamera:
            return "広角\n(1x)"
        case .builtInTelephotoCamera:
            return "望遠\n(2x)"
        case .builtInTripleCamera:
            return "トリプル"
        case .builtInDualCamera:
            return "デュアル"
        case .builtInDualWideCamera:
            return "デュアル広角"
        default:
            return "カメラ"
        }
    }
    
    /// 利用可能なバックカメラをズームラベルで重複排除して取得
    /// 同じラベル（例: "1×"）を持つ複数デバイスのうち最初の1台だけを返す
    static func uniqueBackCameras() -> [AVCaptureDevice] {
        var seen = Set<String>()
        return availableBackCameras().filter { camera in
            let label = zoomLabel(for: camera.deviceType)
            if seen.contains(label) { return false }
            seen.insert(label)
            return true
        }
    }
    
    /// 利用可能なバックカメラを取得（個別の物理カメラのみ）
    static func availableBackCameras() -> [AVCaptureDevice] {
        if PreviewDetection.isRunningForPreviews { return [] }
        
        // 個別の物理カメラのみ取得（マルチカメラ仮想デバイスは除外）
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInUltraWideCamera,
                .builtInWideAngleCamera,
                .builtInTelephotoCamera
            ],
            mediaType: .video,
            position: .back
        )
        
        // 超広角 < 広角 < 望遠 の順にソート
        return discoverySession.devices.sorted { lhs, rhs in
            let order: [AVCaptureDevice.DeviceType] = [
                .builtInUltraWideCamera,
                .builtInWideAngleCamera,
                .builtInTelephotoCamera
            ]
            return (order.firstIndex(of: lhs.deviceType) ?? 0) < (order.firstIndex(of: rhs.deviceType) ?? 0)
        }
    }
}

// MARK: - Resolution Helper

extension AVCaptureSession.Preset {
    /// 解像度の短い表示名を取得
    var displayName: String {
        switch self {
        case .hd4K3840x2160:
            return "4K"
        case .hd1920x1080:
            return "HD"
        case .hd1280x720:
            return "720p"
        default:
            return "HD"
        }
    }
}
