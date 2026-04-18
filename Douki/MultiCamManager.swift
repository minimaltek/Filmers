//
//  MultiCamManager.swift
//  Douki
//
//  Single-device dual-camera recording using AVCaptureMultiCamSession
//

import Foundation
import AVFoundation
import UIKit
import Combine

class MultiCamManager: NSObject, ObservableObject {
    // MARK: - Published State
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var backPreviewLayer: AVCaptureVideoPreviewLayer?
    @Published var frontPreviewLayer: AVCaptureVideoPreviewLayer?
    @Published var error: String?
    @Published var isSessionRunning = false
    
    // MARK: - Active Camera Control
    /// 現在操作中のカメラ（front/back切替で変わる）
    @Published var activePosition: AVCaptureDevice.Position = .back
    /// 操作中カメラのデバイス
    var activeDevice: AVCaptureDevice? {
        activePosition == .back ? backInput?.device : frontInput?.device
    }
    /// 操作中カメラにトーチがあるか
    var hasTorch: Bool { activeDevice?.hasTorch == true }
    
    // フォーカス・露出
    @Published var focusMode: AVCaptureDevice.FocusMode = .continuousAutoFocus
    @Published var exposureMode: AVCaptureDevice.ExposureMode = .continuousAutoExposure
    @Published var exposureBias: Float = 0.0
    @Published var torchMode: AVCaptureDevice.TorchMode = .off
    @Published var zoomFactor: CGFloat = 1.0
    
    // MARK: - Internal State
    private var multiCamSession: AVCaptureMultiCamSession?
    private let sessionQueue = DispatchQueue(label: "com.douki.multiCamSession", qos: .default)
    
    // Back camera pipeline
    private var backInput: AVCaptureDeviceInput?
    private var backOutput: AVCaptureMovieFileOutput?
    private var backVideoURL: URL?
    
    // Front camera pipeline
    private var frontInput: AVCaptureDeviceInput?
    private var frontOutput: AVCaptureMovieFileOutput?
    private var frontVideoURL: URL?
    
    // Audio
    private var audioInput: AVCaptureDeviceInput?
    
    // Recording state
    private var recordingStartTime: Date?
    private var timer: Timer?
    private var sessionID: String = ""
    private var syncTimestamp: TimeInterval = 0
    
    // Completion tracking — both cameras must finish
    private var backFinished = false
    private var frontFinished = false
    private var backFinalURL: URL?
    private var frontFinalURL: URL?
    
    // Settings (copied from CameraManager)
    var desiredOrientation: VideoOrientation = .cinema
    var videoCodec: AVVideoCodecType = .hevc
    
    /// Callback: delivers both video URLs when both outputs finish
    var onRecordingCompleted: ((_ backURL: URL, _ frontURL: URL, _ sessionID: String) -> Void)?
    
    // MARK: - Static
    
    static var isMultiCamSupported: Bool {
        AVCaptureMultiCamSession.isMultiCamSupported
    }
    
    // MARK: - Public API
    
    func setupAndStart() {
        if PreviewDetection.isRunningForPreviews { return }
        
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            DispatchQueue.main.async { self.error = "This device does not support Multi-Camera mode" }
            return
        }
        
        // 端末回転通知を有効化
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            configureMultiCamSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else {
                    DispatchQueue.main.async { self?.error = "Camera access is not permitted" }
                    return
                }
                self?.configureMultiCamSession()
            }
        default:
            DispatchQueue.main.async { self.error = "Camera access is not permitted" }
        }
    }
    
    func startRecording(timestamp: TimeInterval, sessionID: String) {
        self.syncTimestamp = timestamp
        self.sessionID = sessionID
        
        guard let backOut = backOutput, let frontOut = frontOutput else {
            error = "Video outputs not configured"
            return
        }
        guard !backOut.isRecording, !frontOut.isRecording else { return }
        
        // Reset completion tracking
        backFinished = false
        frontFinished = false
        backFinalURL = nil
        frontFinalURL = nil
        
        let deviceName = UIDevice.current.name.replacingOccurrences(of: " ", with: "_")
        let ts = Int(timestamp)
        
        let backFileName = "douki_\(sessionID)_\(deviceName)_BACK_\(ts).mov"
        let frontFileName = "douki_\(sessionID)_\(deviceName)_FRONT_\(ts).mov"
        
        let backURL = FileManager.default.temporaryDirectory.appendingPathComponent(backFileName)
        let frontURL = FileManager.default.temporaryDirectory.appendingPathComponent(frontFileName)
        
        try? FileManager.default.removeItem(at: backURL)
        try? FileManager.default.removeItem(at: frontURL)
        
        self.backVideoURL = backURL
        self.frontVideoURL = frontURL
        
        backOut.startRecording(to: backURL, recordingDelegate: self)
        frontOut.startRecording(to: frontURL, recordingDelegate: self)
        
        DispatchQueue.main.async {
            self.isRecording = true
            OrientationLock.isRecording = true
        }
    }
    
    func stopRecording() {
        backOutput?.stopRecording()
        frontOutput?.stopRecording()
        
        DispatchQueue.main.async {
            self.isRecording = false
            OrientationLock.isRecording = false
            self.stopTimer()
            self.recordingDuration = 0
        }
    }
    
    func stopSession() {
        sessionQueue.async { [weak self] in
            self?.multiCamSession?.stopRunning()
        }
        stopTimer()
        DispatchQueue.main.async {
            self.backPreviewLayer = nil
            self.frontPreviewLayer = nil
            self.isSessionRunning = false
        }
    }
    
    // MARK: - Private: Session Configuration
    
    private func configureMultiCamSession() {
        let capturedOrientation = CameraManager.currentCaptureOrientation()
        
        sessionQueue.async { [weak self] in
            guard let self else { return }
            
            let session = AVCaptureMultiCamSession()
            session.beginConfiguration()
            
            // ── Back Camera（端末で最も広角の物理カメラを選択） ──
            let backCamera: AVCaptureDevice = {
                // ultra-wide 優先、なければ wide-angle
                if let uw = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) {
                    return uw
                }
                return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)!
            }()
            guard let backIn = try? AVCaptureDeviceInput(device: backCamera) else {
                self.failSetup(session: session, message: "Cannot create back camera input")
                return
            }
            guard session.canAddInput(backIn) else {
                self.failSetup(session: session, message: "Cannot add back camera input")
                return
            }
            session.addInputWithNoConnections(backIn)
            self.backInput = backIn
            
            // Back camera format: 1080p 30fps
            self.configureDeviceFormat(backCamera, targetWidth: 1920, targetFPS: 30)
            
            // Back camera video output
            let backOut = AVCaptureMovieFileOutput()
            guard session.canAddOutput(backOut) else {
                self.failSetup(session: session, message: "Cannot add back video output")
                return
            }
            session.addOutputWithNoConnections(backOut)
            self.backOutput = backOut
            
            // Back camera video connection
            guard let backVideoPort = backIn.ports(for: .video, sourceDeviceType: backCamera.deviceType, sourceDevicePosition: .back).first else {
                self.failSetup(session: session, message: "Cannot get back camera video port")
                return
            }
            let backVideoConnection = AVCaptureConnection(inputPorts: [backVideoPort], output: backOut)
            if backVideoConnection.isVideoOrientationSupported {
                backVideoConnection.videoOrientation = capturedOrientation
            }
            guard session.canAddConnection(backVideoConnection) else {
                self.failSetup(session: session, message: "Cannot add back video connection")
                return
            }
            session.addConnection(backVideoConnection)
            
            // Back output codec
            if let videoConn = backOut.connection(with: .video),
               backOut.availableVideoCodecTypes.contains(self.videoCodec) {
                backOut.setOutputSettings([AVVideoCodecKey: self.videoCodec], for: videoConn)
            }
            
            // ── Front Camera ──
            guard let frontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
                self.failSetup(session: session, message: "Front camera not available")
                return
            }
            guard let frontIn = try? AVCaptureDeviceInput(device: frontCamera) else {
                self.failSetup(session: session, message: "Cannot create front camera input")
                return
            }
            guard session.canAddInput(frontIn) else {
                self.failSetup(session: session, message: "Cannot add front camera input")
                return
            }
            session.addInputWithNoConnections(frontIn)
            self.frontInput = frontIn
            
            // Front camera format: 720p 30fps (lower to reduce system load)
            self.configureDeviceFormat(frontCamera, targetWidth: 1280, targetFPS: 30)
            
            // Front camera video output
            let frontOut = AVCaptureMovieFileOutput()
            guard session.canAddOutput(frontOut) else {
                self.failSetup(session: session, message: "Cannot add front video output")
                return
            }
            session.addOutputWithNoConnections(frontOut)
            self.frontOutput = frontOut
            
            // Front camera video connection
            guard let frontVideoPort = frontIn.ports(for: .video, sourceDeviceType: .builtInWideAngleCamera, sourceDevicePosition: .front).first else {
                self.failSetup(session: session, message: "Cannot get front camera video port")
                return
            }
            let frontVideoConnection = AVCaptureConnection(inputPorts: [frontVideoPort], output: frontOut)
            if frontVideoConnection.isVideoOrientationSupported {
                frontVideoConnection.videoOrientation = capturedOrientation
            }
            // Mirror front camera so it matches what user sees
            if frontVideoConnection.isVideoMirroringSupported {
                frontVideoConnection.automaticallyAdjustsVideoMirroring = false
                frontVideoConnection.isVideoMirrored = true
            }
            guard session.canAddConnection(frontVideoConnection) else {
                self.failSetup(session: session, message: "Cannot add front video connection")
                return
            }
            session.addConnection(frontVideoConnection)
            
            // Front output codec
            if let videoConn = frontOut.connection(with: .video),
               frontOut.availableVideoCodecTypes.contains(self.videoCodec) {
                frontOut.setOutputSettings([AVVideoCodecKey: self.videoCodec], for: videoConn)
            }
            
            // ── Audio (connect to back output only) ──
            if let audioDevice = AVCaptureDevice.default(for: .audio),
               let audioIn = try? AVCaptureDeviceInput(device: audioDevice),
               session.canAddInput(audioIn) {
                session.addInputWithNoConnections(audioIn)
                self.audioInput = audioIn
                
                if let audioPort = audioIn.ports(for: .audio, sourceDeviceType: audioDevice.deviceType, sourceDevicePosition: .unspecified).first {
                    let audioConnection = AVCaptureConnection(inputPorts: [audioPort], output: backOut)
                    if session.canAddConnection(audioConnection) {
                        session.addConnection(audioConnection)
                    }
                }
            }
            
            // ── Preview Layers ──
            let backPreview = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
            backPreview.videoGravity = .resizeAspectFill
            let backPreviewConnection = AVCaptureConnection(inputPort: backVideoPort, videoPreviewLayer: backPreview)
            if session.canAddConnection(backPreviewConnection) {
                session.addConnection(backPreviewConnection)
            }
            
            let frontPreview = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
            frontPreview.videoGravity = .resizeAspectFill
            let frontPreviewConnection = AVCaptureConnection(inputPort: frontVideoPort, videoPreviewLayer: frontPreview)
            if frontPreviewConnection.isVideoMirroringSupported {
                frontPreviewConnection.automaticallyAdjustsVideoMirroring = false
                frontPreviewConnection.isVideoMirrored = true
            }
            if session.canAddConnection(frontPreviewConnection) {
                session.addConnection(frontPreviewConnection)
            }
            
            session.commitConfiguration()
            session.startRunning()
            self.multiCamSession = session
            
            DispatchQueue.main.async {
                self.backPreviewLayer = backPreview
                self.frontPreviewLayer = frontPreview
                self.isSessionRunning = true
            }
        }
    }
    
    private func failSetup(session: AVCaptureMultiCamSession, message: String) {
        session.commitConfiguration()
        DispatchQueue.main.async {
            self.error = message
            self.isSessionRunning = false
        }
    }
    
    /// Select a device format closest to target resolution and frame rate (early-exit on exact match)
    private func configureDeviceFormat(_ device: AVCaptureDevice, targetWidth: Int32, targetFPS: Int) {
        var bestFormat: AVCaptureDevice.Format?
        var bestDelta = Int32.max
        
        for format in device.formats where format.isMultiCamSupported {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let delta = abs(dims.width - targetWidth)
            guard delta < bestDelta else { continue }
            let ok = format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= Double(targetFPS) }
            guard ok else { continue }
            bestFormat = format
            bestDelta = delta
            if delta == 0 { break }
        }
        
        guard let format = bestFormat else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
            device.unlockForConfiguration()
        } catch {}
    }
    
    // MARK: - Camera Control
    
    /// 操作対象カメラを切り替え（プレビューのメイン表示も切替）
    func switchActiveCamera() {
        guard !isRecording else { return }
        activePosition = (activePosition == .back) ? .front : .back
        // 切替先のデバイスの現在設定を読み取り
        syncSettingsFromActiveDevice()
    }
    
    /// 端末の向きが変わった時に、全接続のorientationを更新
    func updateOrientationForConnections() {
        let orientation = CameraManager.currentCaptureOrientation()
        // 録画接続は sessionQueue で更新
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if let conn = self.backOutput?.connection(with: .video),
               conn.isVideoOrientationSupported {
                conn.videoOrientation = orientation
            }
            if let conn = self.frontOutput?.connection(with: .video),
               conn.isVideoOrientationSupported {
                conn.videoOrientation = orientation
            }
        }
        // プレビュー接続はメインスレッドで直接更新（CALayer はメインスレッド専用）
        if let conn = backPreviewLayer?.connection, conn.isVideoOrientationSupported {
            conn.videoOrientation = orientation
        }
        if let conn = frontPreviewLayer?.connection, conn.isVideoOrientationSupported {
            conn.videoOrientation = orientation
        }
    }
    
    /// 操作中カメラの設定を@Publishedプロパティに反映
    private func syncSettingsFromActiveDevice() {
        guard let device = activeDevice else { return }
        focusMode = device.focusMode
        exposureMode = device.exposureMode
        exposureBias = device.exposureTargetBias
        torchMode = device.torchMode
        zoomFactor = CGFloat(device.videoZoomFactor)
    }
    
    func setFocusMode(_ mode: AVCaptureDevice.FocusMode) {
        guard let device = activeDevice else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(mode) {
                    device.focusMode = mode
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.focusMode = mode }
            } catch {}
        }
    }
    
    func setExposureMode(_ mode: AVCaptureDevice.ExposureMode) {
        guard let device = activeDevice else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if device.isExposureModeSupported(mode) {
                    device.exposureMode = mode
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.exposureMode = mode }
            } catch {}
        }
    }
    
    func setExposureBias(_ bias: Float) {
        guard let device = activeDevice else { return }
        let clamped = max(device.minExposureTargetBias, min(bias, device.maxExposureTargetBias))
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(clamped)
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.exposureBias = clamped }
            } catch {}
        }
    }
    
    func toggleTorch() {
        guard let device = activeDevice, device.hasTorch else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                device.torchMode = device.torchMode == .off ? .on : .off
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.torchMode = device.torchMode }
            } catch {}
        }
    }
    
    func setZoomFactor(_ factor: CGFloat) {
        guard let device = activeDevice else { return }
        let minZoom = device.minAvailableVideoZoomFactor
        let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 10.0)
        let clamped = max(minZoom, min(factor, maxZoom))
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.zoomFactor = clamped }
            } catch {}
        }
    }
    
    // MARK: - Timer
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let startTime = self.recordingStartTime else { return }
            self.recordingDuration = Date().timeIntervalSince(startTime)
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        stopTimer()
        sessionQueue.async { [weak self] in
            self?.multiCamSession?.stopRunning()
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension MultiCamManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async {
            if self.recordingStartTime == nil {
                self.recordingStartTime = Date()
                self.startTimer()
            }
        }
    }
    
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        // backFinished / frontFinished の読み書きをすべてメインスレッドに統一し
        // 複数スレッドからの非アトミックなアクセスによる競合を防ぐ
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if output === self.backOutput {
                self.backFinished = true
                self.backFinalURL = outputFileURL
            } else if output === self.frontOutput {
                self.frontFinished = true
                self.frontFinalURL = outputFileURL
            }

            guard self.backFinished && self.frontFinished else { return }
            let currentSessionID = self.sessionID
            self.recordingStartTime = nil

            if let backURL = self.backFinalURL, let frontURL = self.frontFinalURL, !currentSessionID.isEmpty {
                self.onRecordingCompleted?(backURL, frontURL, currentSessionID)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.sessionID = ""
            }
        }
    }
}
