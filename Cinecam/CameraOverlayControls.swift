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
    
    private var isLandscape: Bool {
        horizontalSizeClass == .regular ||
        (horizontalSizeClass == .compact && verticalSizeClass == .compact)
    }
    
    var body: some View {
        if isLandscape {
            landscapeLayout
        } else {
            portraitLayout
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
                // Left side: close, torch, focus, exposure
                VStack(alignment: .leading, spacing: 16) {
                    closeButton
                    torchButton
                    
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
                VStack(spacing: 16) {
                    if cameraManager.isRecording {
                        recordingTimerBadge
                    }
                    
                    Spacer()
                    
                    lensSelector(vertical: true)
                    frontBackToggle
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
            torchButton
            
            Spacer()
            
            if cameraManager.isRecording {
                recordingTimerBadge
            }
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
