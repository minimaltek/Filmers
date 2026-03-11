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
    /// 露出ドラッグ開始時の基準値
    @State private var exposureDragStartBias: Float = 0.0
    /// 露出ドラッグ中フラグ（タップ誤爆防止）
    @State private var isDraggingExposure = false
    
    private var isLandscape: Bool {
        horizontalSizeClass == .regular ||
        (horizontalSizeClass == .compact && verticalSizeClass == .compact)
    }
    
    var body: some View {
        ZStack {
            // 露出ロック中: ボタン以外のエリアをタップで解除
            if cameraManager.exposureMode == .locked {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        cameraManager.exposureMode = .continuousAutoExposure
                    }
            }
            
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
            
            // 録画中切断アラート
            recordingDisconnectBanner
            lostMasterBanner
        }
    }
    
    // MARK: - Landscape Layout
    
    private var landscapeLayout: some View {
        ZStack {
            HStack(spacing: 0) {
                // Left side: 2列レイアウト
                // 外側列: close, torch, guide, multimonitor
                // 内側列: focus, exposure (下寄せ)
                HStack(alignment: .bottom, spacing: 8) {
                    VStack(spacing: 12) {
                        closeButton
                        if cameraManager.hasTorch {
                            torchButton
                        }
                        guideToggle
                        multiMonitorButton
                        Spacer()
                    }
                    
                    VStack(spacing: 12) {
                        Spacer()
                        focusLockButton
                        exposureLockButton
                        if cameraManager.exposureMode == .locked {
                            exposureBiasLabel
                        }
                    }
                }
                .padding(.leading, 20)
                .padding(.vertical, 12)
                
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
                    .padding(.bottom, 4)
            }
            
            // Center recording timer overlay
            if cameraManager.isRecording {
                centerRecordingTimer
            }
            
            // 録画中切断アラート
            recordingDisconnectBanner
            lostMasterBanner
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
            guard !cameraManager.isRecording else { return }
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
                .opacity(cameraManager.isRecording ? 0.4 : 1.0)
        }
        .disabled(cameraManager.isRecording)
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
        let isLocked = cameraManager.exposureMode == .locked
        let hasBias = abs(cameraManager.exposureBias) > 0.05
        return exposureButtonContent(isLocked: isLocked, hasBias: hasBias)
            .onTapGesture(count: 2) {
                // ダブルタップで露出補正を0にリセット
                cameraManager.setExposureBias(0)
            }
            .onTapGesture(count: 1) {
                // シングルタップでロック切替
                if !isDraggingExposure {
                    if isLocked {
                        cameraManager.exposureMode = .continuousAutoExposure
                    } else {
                        cameraManager.exposureMode = .locked
                    }
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        if cameraManager.exposureMode == .locked {
                            if !isDraggingExposure {
                                exposureDragStartBias = cameraManager.exposureBias
                                isDraggingExposure = true
                            }
                            let delta = Float(-value.translation.height / 80)
                            cameraManager.setExposureBias(exposureDragStartBias + delta)
                        }
                    }
                    .onEnded { _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            isDraggingExposure = false
                        }
                    }
            )
    }
    
    /// 露出ボタンの見た目（ジェスチャーを分離するため別ビューに）
    private func exposureButtonContent(isLocked: Bool, hasBias: Bool) -> some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.6))
                .frame(width: 44, height: 44)
            
            if isLocked || hasBias {
                Circle()
                    .stroke(Color.yellow, lineWidth: 2)
                    .frame(width: 44, height: 44)
            }
            
            Image(systemName: isLocked ? "sun.max.fill" : "sun.max")
                .font(.system(size: 18))
                .foregroundColor((isLocked || hasBias) ? .yellow : .white)
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
        let isDisabled = isSelected || cameraManager.isRecording
        return Button(action: {
            guard !isSelected, !cameraManager.isRecording else { return }
            cameraManager.switchCamera(to: camera)
        }) {
            ZStack {
                Circle()
                    .fill(isSelected ? Color.yellow : Color.black.opacity(0.6))
                    .frame(width: 44, height: 44)
                
                Text(CameraHelper.zoomLabel(for: camera.deviceType))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isSelected ? .black : .white)
            }
            .opacity(isDisabled && !isSelected ? 0.4 : 1.0)
        }
        .disabled(isDisabled)
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
    
    // MARK: - Recording Disconnect Banners
    
    /// マスター用: スレーブが録画中に切断された時のアラートバナー
    @ViewBuilder
    private var recordingDisconnectBanner: some View {
        if let peerName = sessionManager.recordingDisconnectPeerName {
            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.yellow)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(peerName)の接続が切れました")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                        Text("録画を停止しますか？")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                
                HStack(spacing: 16) {
                    Button(action: {
                        sessionManager.stopRecordingFromDisconnectAlert()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill")
                            Text("STOP ALL")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.red)
                        .cornerRadius(12)
                    }
                    
                    Button(action: {
                        sessionManager.dismissDisconnectAlert()
                    }) {
                        Text("CONTINUE")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.2))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.4), lineWidth: 1)
                            )
                    }
                }
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.red.opacity(0.6), lineWidth: 2)
                    )
            )
        }
    }
    
    /// スレーブ用: マスターとの接続が録画中に切れた時のアラートバナー
    @ViewBuilder
    private var lostMasterBanner: some View {
        if sessionManager.lostMasterDuringRecording {
            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 24))
                        .foregroundColor(.red)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("マスターとの接続が切れました")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                        Text("録画を停止してください")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                
                Button(action: {
                    sessionManager.stopRecordingLocally()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                        Text("STOP")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 14)
                    .background(Color.red)
                    .cornerRadius(12)
                }
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.red.opacity(0.6), lineWidth: 2)
                    )
            )
        }
    }
    
    // MARK: - Record Button
    
    private var recordButton: some View {
        let isSlave = !sessionManager.isMaster
        return Button(action: {
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
                    .stroke(isSlave ? Color.gray.opacity(0.5) : Color.white, lineWidth: 4)
                    .frame(width: 70, height: 70)
                
                if cameraManager.isRecording {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.red)
                        .frame(width: 28, height: 28)
                } else {
                    Circle()
                        .fill(isSlave ? Color.gray : Color.red)
                        .frame(width: 60, height: 60)
                }
            }
        }
        .disabled(sessionManager.isWaitingForReady || isSlave)
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
