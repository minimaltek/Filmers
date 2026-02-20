//
//  CameraControlPanel.swift
//  Cinecam
//
//  カメラ撮影設定パネル
//

import SwiftUI
import AVFoundation

struct CameraControlPanel: View {
    @ObservedObject var cameraManager: CameraManager
    @Binding var isExpanded: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // 展開/折りたたみボタン
            Button(action: {
                withAnimation(.spring(response: 0.3)) {
                    isExpanded.toggle()
                }
            }) {
                HStack {
                    Image(systemName: "camera.circle.fill")
                        .font(.title3)
                    Text("カメラ設定")
                        .font(.headline)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .foregroundColor(.white)
                .padding()
                .background(Color.white.opacity(0.1))
                .cornerRadius(12)
            }
            
            // 設定パネル本体
            if isExpanded {
                VStack(spacing: 16) {
                    // カメラ選択
                    cameraSelectionView
                    
                    Divider()
                        .background(Color.white.opacity(0.2))
                    
                    // ビデオ設定
                    videoSettingsView
                    
                    Divider()
                        .background(Color.white.opacity(0.2))
                    
                    // フォーカス・露出設定
                    focusExposureView
                }
                .padding()
                .background(Color.black.opacity(0.7))
                .cornerRadius(12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
    
    // MARK: - カメラ選択
    
    private var cameraSelectionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("レンズ")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    // 利用可能なカメラデバイスを取得
                    ForEach(availableCameras, id: \.uniqueID) { camera in
                        cameraButton(for: camera)
                    }
                }
            }
        }
    }
    
    private func cameraButton(for camera: AVCaptureDevice) -> some View {
        let isSelected = cameraManager.currentCamera?.uniqueID == camera.uniqueID
        let icon = cameraIcon(for: camera.deviceType)
        let label = cameraLabel(for: camera.deviceType)
        
        return Button(action: {
            cameraManager.switchCamera(to: camera)
        }) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                Text(label)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 60)
            }
            .foregroundColor(isSelected ? .black : .white)
            .frame(width: 80, height: 80)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.white : Color.white.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.orange : Color.clear, lineWidth: 2)
            )
        }
    }
    
    // MARK: - ビデオ設定
    
    private var videoSettingsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ビデオ設定")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
            
            // 解像度
            HStack {
                Text("解像度")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                Picker("", selection: $cameraManager.videoResolution) {
                    Text("4K").tag(AVCaptureSession.Preset.hd4K3840x2160)
                    Text("1080p").tag(AVCaptureSession.Preset.hd1920x1080)
                    Text("720p").tag(AVCaptureSession.Preset.hd1280x720)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            
            // フレームレート
            HStack {
                Text("フレームレート")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                Picker("", selection: $cameraManager.frameRate) {
                    Text("24 fps").tag(24)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            
            // ビデオ安定化
            Toggle(isOn: $cameraManager.videoStabilization) {
                HStack {
                    Image(systemName: "gyroscope")
                        .foregroundColor(.white.opacity(0.7))
                    Text("ビデオ安定化")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.9))
                }
            }
            .tint(.orange)
        }
    }
    
    // MARK: - フォーカス・露出設定
    
    private var focusExposureView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("フォーカス・露出")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
            
            // フォーカスモード
            HStack {
                Text("フォーカス")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                Picker("", selection: $cameraManager.focusMode) {
                    Text("自動").tag(AVCaptureDevice.FocusMode.continuousAutoFocus)
                    Text("ロック").tag(AVCaptureDevice.FocusMode.locked)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            
            // 露出モード
            HStack {
                Text("露出")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                Picker("", selection: $cameraManager.exposureMode) {
                    Text("自動").tag(AVCaptureDevice.ExposureMode.continuousAutoExposure)
                    Text("ロック").tag(AVCaptureDevice.ExposureMode.locked)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            
            // ホワイトバランス
            HStack {
                Text("ホワイトバランス")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                Picker("", selection: $cameraManager.whiteBalanceMode) {
                    Text("自動").tag(AVCaptureDevice.WhiteBalanceMode.continuousAutoWhiteBalance)
                    Text("ロック").tag(AVCaptureDevice.WhiteBalanceMode.locked)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            
            // ズーム（利用可能な場合）
            if let camera = cameraManager.currentCamera,
               camera.maxAvailableVideoZoomFactor > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("ズーム")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.9))
                        Spacer()
                        Text(String(format: "%.1fx", cameraManager.zoomFactor))
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    Slider(
                        value: $cameraManager.zoomFactor,
                        in: 1...min(camera.maxAvailableVideoZoomFactor, 10)
                    )
                    .tint(.orange)
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private var availableCameras: [AVCaptureDevice] {
        var cameras: [AVCaptureDevice] = []
        
        // 背面カメラの検出
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInTelephotoCamera,
                .builtInUltraWideCamera,
                .builtInTripleCamera,
                .builtInDualCamera,
                .builtInDualWideCamera
            ],
            mediaType: .video,
            position: .back
        )
        
        cameras.append(contentsOf: discoverySession.devices)
        
        return cameras
    }
    
    private func cameraIcon(for deviceType: AVCaptureDevice.DeviceType) -> String {
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
    
    private func cameraLabel(for deviceType: AVCaptureDevice.DeviceType) -> String {
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
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        
        VStack {
            Spacer()
            CameraControlPanel(
                cameraManager: CameraManager(),
                isExpanded: .constant(true)
            )
            .padding()
        }
    }
}
