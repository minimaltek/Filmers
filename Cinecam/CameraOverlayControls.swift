//
//  CameraOverlayControls.swift
//  Cinecam
//
//  Camera preview overlay controls — clean, minimal layout
//

import SwiftUI
import AVFoundation

struct CameraOverlayControls: View {
    @ObservedObject var cameraManager: CameraManager
    @ObservedObject var sessionManager: CameraSessionManager
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.verticalSizeClass) var verticalSizeClass
    /// ガイドモード: 0=セーフエリア, 1=セーフエリア+十字, 2=三分割法, 3=オフ
    @State private var guideMode: Int = 0
    /// マルチモニター表示フラグ
    @State private var showMultiMonitor = false
    
    private var isLandscape: Bool {
        horizontalSizeClass == .regular ||
        (horizontalSizeClass == .compact && verticalSizeClass == .compact)
    }
    
    var body: some View {
        ZStack {
            // Guide overlay (modes 0-2)
            if guideMode < 3 {
                guideOverlay
                    .allowsHitTesting(false)
            }
            
            if isLandscape {
                landscapeLayout
            } else {
                portraitLayout
            }
        }
    }
    
    // MARK: - Portrait Layout
    
    private var portraitLayout: some View {
        ZStack {
            VStack(spacing: 0) {
                // Top bar
                topBarPortrait
                    .padding(.horizontal, 20)
                
                Spacer()
                
                // Lens selector (horizontal) + front/back toggle
                HStack(spacing: 12) {
                    lensSelector(vertical: false)
                    frontBackToggle
                }
                .padding(.bottom, 12)
                
                // Focus & Exposure locks (horizontal)
                HStack(spacing: 16) {
                    focusLockButton
                    exposureLockButton
                }
                .padding(.bottom, 20)
                
                // Exposure bias display
                if cameraManager.exposureMode == .locked {
                    exposureBiasLabel
                        .padding(.bottom, 8)
                }
                
                // Record button
                recordButton
                    .padding(.bottom, 20)
            }
            
            // Center recording timer overlay
            if cameraManager.isRecording {
                centerRecordingTimer
            }
        }
    }
    
    // MARK: - Landscape Layout
    
    private var landscapeLayout: some View {
        ZStack {
            HStack(spacing: 0) {
                // Left side: close, torch, action safe, focus, exposure
                VStack(alignment: .leading, spacing: 16) {
                    closeButton
                    if cameraManager.hasTorch {
                        torchButton
                    }
                    guideToggle
                    multiMonitorButton
                    
                    Spacer()
                    
                    focusLockButton
                    exposureLockButton
                    
                    if cameraManager.exposureMode == .locked {
                        exposureBiasLabel
                    }
                }
                .padding(.leading, 20)
                .padding(.vertical, 20)
                
                Spacer()
                
                // Right side: lens buttons + front/back toggle
                VStack(spacing: 12) {
                    if cameraManager.isRecording {
                        recordingTimerBadge
                    }
                    
                    Spacer()
                    
                    frontBackToggle
                    lensSelector(vertical: true)
                    
                    Spacer()
                }
                .padding(.trailing, 20)
                .padding(.vertical, 20)
            }
            
            // Record button at bottom center
            VStack {
                Spacer()
                recordButton
                    .padding(.bottom, 20)
            }
            
            // Center recording timer overlay
            if cameraManager.isRecording {
                centerRecordingTimer
            }
        }
    }
    
    // MARK: - Top Bar (Portrait)
    
    private var topBarPortrait: some View {
        HStack {
            closeButton
            if cameraManager.hasTorch {
                torchButton
            }
            
            Spacer()
            
            if cameraManager.isRecording {
                recordingTimerBadge
            }
            
            guideToggle
            multiMonitorButton
        }
    }
    
    // MARK: - Individual Controls
    
    private var closeButton: some View {
        Button(action: {
            sessionManager.stopCameraAndReturnToMenu()
        }) {
            Image(systemName: "xmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.6))
                .clipShape(Circle())
        }
    }
    
    private var torchButton: some View {
        controlButton(
            icon: cameraManager.torchMode == .off ? "bolt.slash.fill" : "bolt.fill",
            isActive: cameraManager.torchMode != .off
        ) {
            cameraManager.toggleTorch()
        }
    }
    
    private var frontBackToggle: some View {
        Button(action: {
            CameraHelper.toggleFrontBackCamera(
                currentCamera: cameraManager.currentCamera,
                cameraManager: cameraManager
            )
        }) {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.6))
                .clipShape(Circle())
        }
    }
    
    private var recordingTimerBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
            Text(TimeFormatter.formatDuration(cameraManager.recordingDuration))
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.6))
        .cornerRadius(20)
    }
    
    private var focusLockButton: some View {
        controlButton(
            icon: "scope",
            isActive: cameraManager.focusMode == .locked
        ) {
            if cameraManager.focusMode == .locked {
                cameraManager.focusMode = .continuousAutoFocus
            } else {
                cameraManager.focusMode = .locked
            }
        }
    }
    
    private var exposureLockButton: some View {
        controlButton(
            icon: cameraManager.exposureMode == .locked ? "sun.max.fill" : "sun.max",
            isActive: cameraManager.exposureMode == .locked
        ) {
            if cameraManager.exposureMode == .locked {
                cameraManager.exposureMode = .continuousAutoExposure
            } else {
                cameraManager.exposureMode = .locked
            }
        }
    }
    
    private var exposureBiasLabel: some View {
        Text(String(format: "%+.1f", cameraManager.exposureBias))
            .font(.caption)
            .foregroundColor(.yellow)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.6))
            .cornerRadius(8)
    }
    
    // MARK: - Lens Selector
    
    @ViewBuilder
    private func lensSelector(vertical: Bool) -> some View {
        let cameras = CameraHelper.uniqueBackCameras()
        if cameras.count > 1 {
            let content = ForEach(cameras, id: \.uniqueID) { camera in
                lensButton(for: camera)
            }
            
            if vertical {
                VStack(spacing: 8) { content }
            } else {
                HStack(spacing: 12) { content }
            }
        }
    }
    
    private func lensButton(for camera: AVCaptureDevice) -> some View {
        let isSelected = cameraManager.currentCamera?.uniqueID == camera.uniqueID
        return Button(action: {
            cameraManager.switchCamera(to: camera)
        }) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.6))
                    .frame(width: 44, height: 44)
                
                if isSelected {
                    Circle()
                        .stroke(Color.yellow, lineWidth: 2)
                        .frame(width: 44, height: 44)
                }
                
                Text(CameraHelper.zoomLabel(for: camera.deviceType))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isSelected ? .yellow : .white)
            }
        }
    }
    
    // MARK: - Center Recording Timer
    
    private var centerRecordingTimer: some View {
        VStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                
                Text(TimeFormatter.formatDuration(cameraManager.recordingDuration))
                    .font(.system(size: 28, weight: .thin, design: .monospaced))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 15)
                    .fill(Color.black.opacity(0.5))
            )
        }
    }
    
    // MARK: - Record Button
    
    private var recordButton: some View {
        Button(action: {
            if sessionManager.isMaster {
                if cameraManager.isRecording {
                    sessionManager.stopRecordingAll()
                } else {
                    sessionManager.startRecordingAll()
                }
            }
        }) {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 70, height: 70)
                
                if cameraManager.isRecording {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.red)
                        .frame(width: 28, height: 28)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 60, height: 60)
                }
            }
        }
        .disabled(sessionManager.isWaitingForReady || !sessionManager.isMaster)
        .opacity(sessionManager.isMaster ? 1.0 : 0.5)
    }
    
    // MARK: - Guide Overlay (4-stage cycle)
    
    private var guideToggle: some View {
        controlButton(
            icon: "rectangle.inset.filled",
            isActive: guideMode < 3
        ) {
            guideMode = (guideMode + 1) % 4
        }
    }
    
    private var multiMonitorButton: some View {
        controlButton(
            icon: "rectangle.split.2x2",
            isActive: false
        ) {
            sessionManager.startMultiMonitor()
            showMultiMonitor = true
        }
        .fullScreenCover(isPresented: $showMultiMonitor) {
            MultiMonitorView(sessionManager: sessionManager, cameraManager: cameraManager)
        }
    }
    
    private var guideOverlay: some View {
        GeometryReader { geo in
            let crop = cropRect(screen: geo.size)
            
            // Mode 0: セーフエリア枠
            // Mode 1: セーフエリア枠 + 中央十字
            // Mode 2: 三分割法グリッド
            
            switch guideMode {
            case 0:
                // セーフエリア（クロップ領域の90%）
                safeAreaRect(crop: crop)
                
            case 1:
                // セーフエリア + 中央十字
                safeAreaRect(crop: crop)
                centerCrosshair(crop: crop)
                
            case 2:
                // セーフエリア + その内側で三分割法
                safeAreaRect(crop: crop)
                ruleOfThirdsGrid(crop: crop)
                
            default:
                EmptyView()
            }
        }
        .ignoresSafeArea()
    }
    
    /// セーフエリア枠（クロップ領域の90%）
    private func safeAreaRect(crop: CGRect) -> some View {
        let safeW = crop.width * 0.9
        let safeH = crop.height * 0.9
        return Rectangle()
            .stroke(Color.white.opacity(0.4), lineWidth: 1)
            .frame(width: safeW, height: safeH)
            .position(x: crop.midX, y: crop.midY)
    }
    
    /// 中央十字マーク
    private func centerCrosshair(crop: CGRect) -> some View {
        let armLen: CGFloat = 20
        let cx = crop.midX
        let cy = crop.midY
        return ZStack {
            // 水平線
            Rectangle()
                .fill(Color.white.opacity(0.5))
                .frame(width: armLen * 2, height: 1)
                .position(x: cx, y: cy)
            // 垂直線
            Rectangle()
                .fill(Color.white.opacity(0.5))
                .frame(width: 1, height: armLen * 2)
                .position(x: cx, y: cy)
        }
    }
    
    /// 三分割法グリッド（セーフエリア内に描画）
    private func ruleOfThirdsGrid(crop: CGRect) -> some View {
        // セーフエリア（90%）の矩形を基準にする
        let safeW = crop.width * 0.9
        let safeH = crop.height * 0.9
        let sx = crop.midX - safeW / 2
        let sy = crop.midY - safeH / 2
        return ZStack {
            // 縦線2本
            ForEach([1, 2], id: \.self) { i in
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 1, height: safeH)
                    .position(x: sx + safeW * CGFloat(i) / 3.0, y: crop.midY)
            }
            // 横線2本
            ForEach([1, 2], id: \.self) { i in
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: safeW, height: 1)
                    .position(x: crop.midX, y: sy + safeH * CGFloat(i) / 3.0)
            }
        }
    }
    
    /// クロップ領域の矩形を計算
    private func cropRect(screen: CGSize) -> CGRect {
        let w = screen.width
        let h = screen.height
        guard h > 0 else { return .zero }
        let screenRatio = w / h
        let targetRatio = cameraManager.desiredOrientation.aspectRatio
        
        let cropW: CGFloat
        let cropH: CGFloat
        if targetRatio > screenRatio + 0.05 {
            cropW = w
            cropH = w / targetRatio
        } else if targetRatio < screenRatio - 0.05 {
            cropH = h
            cropW = h * targetRatio
        } else {
            cropW = w
            cropH = h
        }
        return CGRect(x: (w - cropW) / 2, y: (h - cropH) / 2, width: cropW, height: cropH)
    }
    
    // MARK: - Helper
    
    private func controlButton(icon: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.6))
                    .frame(width: 44, height: 44)
                
                if isActive {
                    Circle()
                        .stroke(Color.yellow, lineWidth: 2)
                        .frame(width: 44, height: 44)
                }
                
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(isActive ? .yellow : .white)
            }
        }
    }
}

#Preview {
    CameraOverlayControls(
        cameraManager: .previewMock,
        sessionManager: CameraSessionManager()
    )
    .background(Color.black.ignoresSafeArea())
}
