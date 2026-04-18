//
//  SingleModeOverlayControls.swift
//  Filmers
//
//  Overlay controls for Single Mode dual-camera recording
//  Mirrors CameraOverlayControls layout with multi-cam specific behavior
//

import SwiftUI
import AVFoundation

struct SingleModeOverlayControls: View {
    @ObservedObject var multiCamManager: MultiCamManager
    var onExit: () -> Void
    
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.verticalSizeClass) var verticalSizeClass
    
    /// ガイドモード: 0=セーフエリア, 1=セーフエリア+十字, 2=三分割法, 3=オフ
    @State private var guideMode: Int = 0
    /// 露出ドラッグ開始時の基準値
    @State private var exposureDragStartBias: Float = 0.0
    /// 露出ドラッグ中フラグ
    @State private var isDraggingExposure = false
    
    private var isLandscape: Bool {
        horizontalSizeClass == .regular ||
        (horizontalSizeClass == .compact && verticalSizeClass == .compact)
    }
    
    /// 背面カメラ操作中か
    private var isBackActive: Bool {
        multiCamManager.activePosition == .back
    }
    
    var body: some View {
        ZStack {
            // 露出ロック中: ボタン以外のエリアをタップで解除
            if multiCamManager.exposureMode == .locked {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        multiCamManager.setExposureMode(.continuousAutoExposure)
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
                
                // Lens selector + camera toggle (背面カメラ時のみレンズ表示)
                HStack(spacing: 12) {
                    if isBackActive {
                        lensSelector(vertical: false)
                    }
                    cameraToggleButton
                }
                .padding(.bottom, 12)
                
                // Focus & Exposure locks + Guide toggle
                HStack(spacing: 16) {
                    focusLockButton
                    exposureLockButton
                    guideToggle
                }
                .padding(.bottom, 20)
                
                // Exposure bias display
                if multiCamManager.exposureMode == .locked {
                    exposureBiasLabel
                        .padding(.bottom, 8)
                }
                
                // Record button
                recordButton
                    .padding(.bottom, 20)
            }
            
            // PiPワイプ左上にモードバッジ（PiP実座標に合わせて配置）
            GeometryReader { geo in
                let safeTop = geo.safeAreaInsets.top
                let safeRight = geo.safeAreaInsets.trailing
                // PiP左端 = screenWidth - pipTrailing - pipWidth
                let pipTrailing: CGFloat = 16
                let pipWidth: CGFloat = 120
                let pipLeftX = geo.size.width - safeRight - pipTrailing - pipWidth
                let pipTop: CGFloat = isLandscape ? 16 : 60
                let badgeY = pipTop - safeTop - 6
                modeBadge
                    .position(x: pipLeftX + 30, y: badgeY + 12)
            }
            .allowsHitTesting(false)
            
            // Center recording timer overlay
            if multiCamManager.isRecording {
                centerRecordingTimer
            }
        }
    }
    
    // MARK: - Landscape Layout
    
    private var landscapeLayout: some View {
        ZStack {
            HStack(spacing: 0) {
                // Left side
                HStack(alignment: .bottom, spacing: 8) {
                    VStack(spacing: 12) {
                        closeButton
                        if multiCamManager.hasTorch {
                            torchButton
                        }
                        guideToggle
                        Spacer()
                    }
                    
                    VStack(spacing: 12) {
                        Spacer()
                        focusLockButton
                        exposureLockButton
                        if multiCamManager.exposureMode == .locked {
                            exposureBiasLabel
                        }
                    }
                }
                .padding(.leading, 20)
                .padding(.vertical, 12)
                
                Spacer()
                
                // Right side
                VStack(spacing: 12) {
                    if multiCamManager.isRecording {
                        recordingTimerBadge
                    }
                    
                    Spacer()
                }
                .padding(.trailing, 20)
                .padding(.vertical, 20)
            }
            
            // PiPワイプ左上にモードバッジ（PiP実座標に合わせて配置）
            // 横持ちではUIViewのboundsベースなのでsafeRightは除外
            GeometryReader { geo in
                let safeTop = geo.safeAreaInsets.top
                let pipTrailing: CGFloat = 16
                let pipWidth: CGFloat = 120
                let pipLeftX = geo.size.width - pipTrailing - pipWidth
                let pipTop: CGFloat = 16
                let badgeY = pipTop - safeTop - 6
                modeBadge
                    .position(x: pipLeftX + 68, y: badgeY + 12)
            }
            .allowsHitTesting(false)
            
            // Record button at bottom center
            VStack {
                Spacer()
                recordButton
                    .padding(.bottom, 4)
            }
            
            // Lens selector at right-bottom
            if isBackActive {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        lensSelector(vertical: false)
                            .padding(.trailing, 16)
                            .padding(.bottom, 12)
                    }
                }
            }
            
            // Center recording timer overlay
            if multiCamManager.isRecording {
                centerRecordingTimer
            }
        }
    }
    
    // MARK: - Top Bar (Portrait)
    
    private var topBarPortrait: some View {
        HStack {
            closeButton
            if multiCamManager.hasTorch {
                torchButton
            }
            
            Spacer()
        }
    }
    
    // MARK: - Individual Controls
    
    /// ワイプ（PiP）に映っているカメラ名を表示するバッジ
    private var modeBadge: some View {
        let pipIsBack = !isBackActive  // ワイプ = 非アクティブ側
        return HStack(spacing: 4) {
            Circle()
                .fill(pipIsBack ? Color.orange : Color.cyan)
                .frame(width: 6, height: 6)
            Text(pipIsBack ? "BACK" : "FRONT")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1)
        }
        .foregroundColor(pipIsBack ? .orange.opacity(0.8) : .cyan.opacity(0.8))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.6))
        .cornerRadius(16)
    }
    
    private var closeButton: some View {
        Button(action: {
            if !multiCamManager.isRecording {
                onExit()
            }
        }) {
            Image(systemName: "xmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.6))
                .clipShape(Circle())
        }
        .opacity(multiCamManager.isRecording ? 0.4 : 1.0)
        .disabled(multiCamManager.isRecording)
    }
    
    private var torchButton: some View {
        controlButton(
            icon: multiCamManager.torchMode == .off ? "bolt.slash.fill" : "bolt.fill",
            isActive: multiCamManager.torchMode != .off
        ) {
            multiCamManager.toggleTorch()
        }
    }
    
    /// 前面/背面カメラ操作切替ボタン
    private var cameraToggleButton: some View {
        Button(action: {
            multiCamManager.switchActiveCamera()
        }) {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.6))
                .clipShape(Circle())
                .opacity(multiCamManager.isRecording ? 0.4 : 1.0)
        }
        .disabled(multiCamManager.isRecording)
    }
    
    private var recordingTimerBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
            Text(TimeFormatter.formatDuration(multiCamManager.recordingDuration))
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
            isActive: multiCamManager.focusMode == .locked
        ) {
            if multiCamManager.focusMode == .locked {
                multiCamManager.setFocusMode(.continuousAutoFocus)
            } else {
                multiCamManager.setFocusMode(.locked)
            }
        }
    }
    
    private var exposureLockButton: some View {
        let isLocked = multiCamManager.exposureMode == .locked
        let hasBias = abs(multiCamManager.exposureBias) > 0.05
        return exposureButtonContent(isLocked: isLocked, hasBias: hasBias)
            .onTapGesture(count: 2) {
                multiCamManager.setExposureBias(0)
            }
            .onTapGesture(count: 1) {
                if !isDraggingExposure {
                    if isLocked {
                        multiCamManager.setExposureMode(.continuousAutoExposure)
                    } else {
                        multiCamManager.setExposureMode(.locked)
                    }
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        if multiCamManager.exposureMode == .locked {
                            if !isDraggingExposure {
                                exposureDragStartBias = multiCamManager.exposureBias
                                isDraggingExposure = true
                            }
                            let delta = Float(-value.translation.height / 80)
                            multiCamManager.setExposureBias(exposureDragStartBias + delta)
                        }
                    }
                    .onEnded { value in
                        if isDraggingExposure {
                            isDraggingExposure = false
                        }
                    }
            )
    }
    
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
        Text(String(format: "%+.1f", multiCamManager.exposureBias))
            .font(.caption)
            .foregroundColor(.yellow)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.6))
            .cornerRadius(8)
    }
    
    // MARK: - Lens Selector (背面カメラのみ、ズームで疑似切替)
    
    /// MultiCamSessionではズームファクターで疑似レンズ切替
    /// backカメラのinputデバイス（ultra-wide優先）を基準にズーム倍率を算出
    private var availableZoomLevels: [(label: String, zoom: CGFloat)] {
        guard multiCamManager.activePosition == .back,
              let device = multiCamManager.activeDevice else { return [] }
        let minZoom = device.minAvailableVideoZoomFactor
        let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 10.0)
        let isUltraWideBase = device.deviceType == .builtInUltraWideCamera
        
        var levels: [(String, CGFloat)] = []
        let cameras = CameraHelper.uniqueBackCameras()
        for camera in cameras {
            let zoom: CGFloat
            let label: String
            switch camera.deviceType {
            case .builtInUltraWideCamera:
                // ultra-wideがベースなら zoom 1.0
                zoom = isUltraWideBase ? 1.0 : 0.5
                label = "0.5×"
            case .builtInWideAngleCamera:
                // ultra-wideベースなら ~2.0（13mm→24mm≈1.85）
                zoom = isUltraWideBase ? 2.0 : 1.0
                label = "1×"
            case .builtInTelephotoCamera:
                // ultra-wideベースなら ~6.0（13mm→77mm≈5.9）
                zoom = isUltraWideBase ? 6.0 : 3.0
                label = "2×"
            default:
                continue
            }
            if zoom >= minZoom && zoom <= maxZoom {
                levels.append((label, zoom))
            }
        }
        return levels
    }
    
    @ViewBuilder
    private func lensSelector(vertical: Bool) -> some View {
        let levels = availableZoomLevels
        if levels.count > 1 {
            let content = ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                lensZoomButton(label: level.label, zoom: level.zoom)
            }
            
            if vertical {
                VStack(spacing: 8) { content }
            } else {
                HStack(spacing: 12) { content }
            }
        }
    }
    
    private func lensZoomButton(label: String, zoom: CGFloat) -> some View {
        let currentZoom = multiCamManager.zoomFactor
        // 選択判定: 対数スケールで近いかチェック（高ズーム域でも正確に判定）
        let isSelected = abs(log2(currentZoom) - log2(zoom)) < 0.3
        return Button(action: {
            multiCamManager.setZoomFactor(zoom)
        }) {
            ZStack {
                Circle()
                    .fill(isSelected ? Color.yellow : Color.black.opacity(0.6))
                    .frame(width: 44, height: 44)
                
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isSelected ? .black : .white)
            }
        }
        .disabled(isSelected)
    }
    
    // MARK: - Record Button
    
    private var recordButton: some View {
        Button(action: {
            if multiCamManager.isRecording {
                multiCamManager.stopRecording()
            } else {
                let sessionID = String(UUID().uuidString.prefix(8))
                let timestamp = Date().timeIntervalSince1970
                multiCamManager.startRecording(timestamp: timestamp, sessionID: sessionID)
            }
        }) {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 70, height: 70)
                
                if multiCamManager.isRecording {
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
    }
    
    // MARK: - Center Recording Timer
    
    private var centerRecordingTimer: some View {
        VStack {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 5, height: 5)
                
                Text(TimeFormatter.formatDuration(multiCamManager.recordingDuration))
                    .font(.system(size: 14, weight: .thin, design: .monospaced))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.5))
            )
        }
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
    
    private var guideOverlay: some View {
        GeometryReader { geo in
            let crop = cropRect(screen: geo.size)
            
            switch guideMode {
            case 0:
                safeAreaRect(crop: crop)
            case 1:
                safeAreaRect(crop: crop)
                centerCrosshair(crop: crop)
            case 2:
                safeAreaRect(crop: crop)
                ruleOfThirdsGrid(crop: crop)
            default:
                EmptyView()
            }
        }
        .ignoresSafeArea()
    }
    
    private func safeAreaRect(crop: CGRect) -> some View {
        let safeW = crop.width * 0.9
        let safeH = crop.height * 0.9
        return Rectangle()
            .stroke(Color.white.opacity(0.4), lineWidth: 1)
            .frame(width: safeW, height: safeH)
            .position(x: crop.midX, y: crop.midY)
    }
    
    private func centerCrosshair(crop: CGRect) -> some View {
        let armLen: CGFloat = 20
        let cx = crop.midX
        let cy = crop.midY
        return ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.5))
                .frame(width: armLen * 2, height: 1)
                .position(x: cx, y: cy)
            Rectangle()
                .fill(Color.white.opacity(0.5))
                .frame(width: 1, height: armLen * 2)
                .position(x: cx, y: cy)
        }
    }
    
    private func ruleOfThirdsGrid(crop: CGRect) -> some View {
        let safeW = crop.width * 0.9
        let safeH = crop.height * 0.9
        let sx = crop.midX - safeW / 2
        let sy = crop.midY - safeH / 2
        return ZStack {
            ForEach([1, 2], id: \.self) { i in
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 1, height: safeH)
                    .position(x: sx + safeW * CGFloat(i) / 3.0, y: crop.midY)
            }
            ForEach([1, 2], id: \.self) { i in
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: safeW, height: 1)
                    .position(x: crop.midX, y: sy + safeH * CGFloat(i) / 3.0)
            }
        }
    }
    
    private func cropRect(screen: CGSize) -> CGRect {
        let w = screen.width
        let h = screen.height
        guard h > 0 else { return .zero }
        let screenRatio = w / h
        let targetRatio = multiCamManager.desiredOrientation.aspectRatio
        
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
