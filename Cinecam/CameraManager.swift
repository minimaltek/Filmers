//
//  CameraManager.swift
//  Cinecam
//
//  Phase 2: カメラ録画機能
//

import Foundation
import AVFoundation
import UIKit
import Photos
import Combine

class CameraManager: NSObject, ObservableObject {
    // MARK: - Properties
    
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    @Published var error: String?
    
    // カメラ設定
    @Published var currentCamera: AVCaptureDevice?
    @Published var videoResolution: AVCaptureSession.Preset = .hd1920x1080 {
        didSet { updateSessionPreset() }
    }
    @Published var frameRate: Int = 30 {
        didSet { updateFrameRate() }
    }
    @Published var videoStabilization: Bool = true {
        didSet { updateVideoStabilization() }
    }
    @Published var focusMode: AVCaptureDevice.FocusMode = .continuousAutoFocus {
        didSet { updateFocusMode() }
    }
    @Published var exposureMode: AVCaptureDevice.ExposureMode = .continuousAutoExposure {
        didSet { updateExposureMode() }
    }
    @Published var whiteBalanceMode: AVCaptureDevice.WhiteBalanceMode = .continuousAutoWhiteBalance {
        didSet { updateWhiteBalanceMode() }
    }
    @Published var zoomFactor: CGFloat = 1.0 {
        didSet { updateZoomFactor() }
    }
    @Published var torchMode: AVCaptureDevice.TorchMode = .off
    @Published var exposureBias: Float = 0.0  // 露出補正値
    
    // 録画設定
    var videoOrientation: AVCaptureVideoOrientation = .landscapeRight  // デフォルト: 横向き
    @Published var videoCodec: AVVideoCodecType = .hevc  // .h264, .hevc, .proRes422, .proRes4444
    
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureMovieFileOutput?
    private var currentVideoURL: URL?
    private var recordingStartTime: Date?
    private var timer: Timer?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?

    // AVCaptureSession 専用の直列キュー。
    // global(qos:) を使うと MCSession の内部処理と同じスレッドプールを奪い合い、
    // startRunning() の長時間ブロックが MCSession のタイムアウト切断を引き起こす。
    private let sessionQueue = DispatchQueue(label: "com.cinecam.captureSession", qos: .default)
    
    // 録画開始時のタイムスタンプ（同期用）
    private var syncTimestamp: TimeInterval = 0
    private var sessionID: String = ""
    
    // 録画完了時のファイルパス
    var lastRecordedVideoURL: URL?
    
    // 録画完了コールバック
    var onRecordingCompleted: ((URL, String) -> Void)?  // (videoURL, sessionID)
    
    // MARK: - Initialization
    
    override init() {
        super.init()
    }
    
    // MARK: - Public Methods
    
    /// カメラのセットアップと起動
    func setupCamera() {
        print("🎥 [CameraManager] setupCamera() called")
        checkCameraPermission { [weak self] granted in
            print("🎥 [CameraManager] Permission granted: \(granted)")
            if granted {
                // カメラを設定して起動する
                self?.configureCaptureSession(thenStart: true)
            } else {
                self?.error = "カメラの使用が許可されていません"
                print("❌ [CameraManager] Camera permission denied")
            }
        }
    }
    
    /// セッション起動（録画開始直前に呼ぶ）
    func startSession(completion: @escaping () -> Void) {
        guard let session = captureSession else {
            // まだセットアップされていなければセットアップしてから起動
            checkCameraPermission { [weak self] granted in
                guard let self, granted else { return }
                self.configureCaptureSession(thenStart: true, completion: completion)
            }
            return
        }
        guard !session.isRunning else {
            completion()
            return
        }
        sessionQueue.async {
            session.startRunning()
            print("🎥 カメラセッション開始")
            DispatchQueue.main.async { completion() }
        }
    }
    
    /// カメラ権限チェック
    private func checkCameraPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
            
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
            
        case .denied, .restricted:
            completion(false)
            
        @unknown default:
            completion(false)
        }
    }
    
    /// キャプチャセッションの設定
    private func configureCaptureSession(thenStart: Bool = false, completion: (() -> Void)? = nil) {
        print("🎥 [CameraManager] configureCaptureSession called, thenStart: \(thenStart)")
        // AVCaptureSession の設定・起動はすべて専用直列キューで行う。
        // global(qos: .userInitiated) を使うと MCSession の内部処理と
        // スレッドプールを奪い合い、startRunning() の長時間ブロック（数秒）が
        // MCSession のタイムアウト切断を引き起こす。
        sessionQueue.async { [weak self] in
            guard let self else { return }

            print("🎥 [CameraManager] Creating AVCaptureSession...")
            let session = AVCaptureSession()
            session.beginConfiguration()
            session.sessionPreset = self.videoResolution

            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                print("❌ [CameraManager] Camera not found")
                DispatchQueue.main.async { self.error = "カメラが見つかりません" }
                return
            }

            print("🎥 [CameraManager] Camera found: \(camera.localizedName)")

            do {
                let videoInput = try AVCaptureDeviceInput(device: camera)
                if session.canAddInput(videoInput) { 
                    session.addInput(videoInput)
                    self.videoInput = videoInput
                    print("✅ [CameraManager] Video input added")
                }

                if let audioDevice = AVCaptureDevice.default(for: .audio) {
                    let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                    if session.canAddInput(audioInput) { 
                        session.addInput(audioInput)
                        self.audioInput = audioInput
                        print("✅ [CameraManager] Audio input added")
                    }
                }

                let output = AVCaptureMovieFileOutput()
                
                // コーデック設定
                if output.availableVideoCodecTypes.contains(self.videoCodec) {
                    output.setOutputSettings([AVVideoCodecKey: self.videoCodec], for: output.connection(with: .video)!)
                    print("✅ [CameraManager] Video codec set to: \(self.videoCodec.rawValue)")
                }
                
                if session.canAddOutput(output) {
                    session.addOutput(output)
                    if let connection = output.connection(with: .video),
                       connection.isVideoOrientationSupported {
                        connection.videoOrientation = self.videoOrientation
                    }
                    print("✅ [CameraManager] Video output added")
                }

                session.commitConfiguration()
                print("✅ [CameraManager] Session configuration committed")

                let preview = AVCaptureVideoPreviewLayer(session: session)
                preview.videoGravity = .resizeAspectFill
                if preview.connection?.isVideoOrientationSupported == true {
                    preview.connection?.videoOrientation = self.videoOrientation
                }

                // UI 更新だけメインスレッドへ
                DispatchQueue.main.async {
                    self.captureSession = session
                    self.videoOutput = output
                    self.previewLayer = preview
                    self.currentCamera = camera
                    print("✅ [CameraManager] previewLayer set on main thread")
                }
                
                // 初期設定を適用
                self.configureDevice(camera)

                if thenStart {
                    // startRunning() は同じ sessionQueue で同期実行（ブロックするがキューは専用なので安全）
                    print("🎥 [CameraManager] Starting camera session...")
                    session.startRunning()
                    print("✅ [CameraManager] Camera session started, isRunning: \(session.isRunning)")
                    DispatchQueue.main.async {
                        completion?()
                    }
                } else {
                    print("⚠️ [CameraManager] Session configured but NOT started (thenStart=false)")
                }

            } catch {
                print("❌ [CameraManager] Configuration error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.error = "カメラの設定に失敗しました: \(error.localizedDescription)"
                }
            }
        }
    }
    
    // MARK: - Camera Control Methods
    
    /// カメラを切り替え
    func switchCamera(to camera: AVCaptureDevice) {
        sessionQueue.async { [weak self] in
            guard let self,
                  let session = self.captureSession,
                  let currentInput = self.videoInput else { return }
            
            session.beginConfiguration()
            session.removeInput(currentInput)
            
            do {
                let newInput = try AVCaptureDeviceInput(device: camera)
                if session.canAddInput(newInput) {
                    session.addInput(newInput)
                    self.videoInput = newInput
                    
                    DispatchQueue.main.async {
                        self.currentCamera = camera
                        self.zoomFactor = 1.0
                    }
                    
                    self.configureDevice(camera)
                    print("✅ カメラ切り替え: \(camera.localizedName)")
                }
            } catch {
                DispatchQueue.main.async {
                    self.error = "カメラの切り替えに失敗しました"
                }
            }
            
            session.commitConfiguration()
        }
    }
    
    /// デバイスの設定を適用
    private func configureDevice(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            
            // フォーカスモード
            if device.isFocusModeSupported(focusMode) {
                device.focusMode = focusMode
            }
            
            // 露出モード
            if device.isExposureModeSupported(exposureMode) {
                device.exposureMode = exposureMode
            }
            
            // ホワイトバランス
            if device.isWhiteBalanceModeSupported(whiteBalanceMode) {
                device.whiteBalanceMode = whiteBalanceMode
            }
            
            // フレームレート
            let targetFrameRate = CMTime(value: 1, timescale: CMTimeScale(frameRate))
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
                $0.minFrameDuration <= targetFrameRate && targetFrameRate <= $0.maxFrameDuration
            }) {
                device.activeVideoMinFrameDuration = targetFrameRate
                device.activeVideoMaxFrameDuration = targetFrameRate
            }
            
            device.unlockForConfiguration()
        } catch {
            print("⚠️ デバイス設定エラー: \(error.localizedDescription)")
        }
    }
    
    /// 解像度を更新
    private func updateSessionPreset() {
        sessionQueue.async { [weak self] in
            guard let self, let session = self.captureSession else { return }
            session.beginConfiguration()
            if session.canSetSessionPreset(self.videoResolution) {
                session.sessionPreset = self.videoResolution
                print("✅ 解像度変更: \(self.videoResolution.rawValue)")
            }
            session.commitConfiguration()
        }
    }
    
    /// フレームレートを更新
    private func updateFrameRate() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentCamera else { return }
            self.configureDevice(device)
        }
    }
    
    /// ビデオ安定化を更新
    private func updateVideoStabilization() {
        sessionQueue.async { [weak self] in
            guard let self, 
                  let output = self.videoOutput,
                  let connection = output.connection(with: .video) else { return }
            
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = self.videoStabilization ? .auto : .off
                print("✅ ビデオ安定化: \(self.videoStabilization ? "ON" : "OFF")")
            }
        }
    }
    
    /// フォーカスモードを更新
    private func updateFocusMode() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentCamera else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(self.focusMode) {
                    device.focusMode = self.focusMode
                    print("✅ フォーカスモード: \(self.focusMode.rawValue)")
                }
                device.unlockForConfiguration()
            } catch {
                print("⚠️ フォーカスモード設定エラー: \(error.localizedDescription)")
            }
        }
    }
    
    /// 露出モードを更新
    private func updateExposureMode() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentCamera else { return }
            do {
                try device.lockForConfiguration()
                if device.isExposureModeSupported(self.exposureMode) {
                    device.exposureMode = self.exposureMode
                    print("✅ 露出モード: \(self.exposureMode.rawValue)")
                }
                device.unlockForConfiguration()
            } catch {
                print("⚠️ 露出モード設定エラー: \(error.localizedDescription)")
            }
        }
    }
    
    /// ホワイトバランスを更新
    private func updateWhiteBalanceMode() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentCamera else { return }
            do {
                try device.lockForConfiguration()
                if device.isWhiteBalanceModeSupported(self.whiteBalanceMode) {
                    device.whiteBalanceMode = self.whiteBalanceMode
                    print("✅ ホワイトバランス: \(self.whiteBalanceMode.rawValue)")
                }
                device.unlockForConfiguration()
            } catch {
                print("⚠️ ホワイトバランス設定エラー: \(error.localizedDescription)")
            }
        }
    }
    
    /// ズーム倍率を更新
    private func updateZoomFactor() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentCamera else { return }
            do {
                try device.lockForConfiguration()
                let maxZoom = min(device.maxAvailableVideoZoomFactor, 10)
                device.videoZoomFactor = max(1.0, min(self.zoomFactor, maxZoom))
                device.unlockForConfiguration()
            } catch {
                print("⚠️ ズーム設定エラー: \(error.localizedDescription)")
            }
        }
    }
    
    /// トーチをトグル
    func toggleTorch() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentCamera else { return }
            
            guard device.hasTorch else {
                print("⚠️ トーチが利用できません")
                return
            }
            
            do {
                try device.lockForConfiguration()
                
                if device.torchMode == .off {
                    if device.isTorchModeSupported(.on) {
                        try device.setTorchModeOn(level: 1.0)
                        DispatchQueue.main.async {
                            self.torchMode = .on
                        }
                    }
                } else {
                    device.torchMode = .off
                    DispatchQueue.main.async {
                        self.torchMode = .off
                    }
                }
                
                device.unlockForConfiguration()
            } catch {
                print("⚠️ トーチ設定エラー: \(error.localizedDescription)")
            }
        }
    }
    
    /// 録画開始（カメラセッションは常時起動済みを前提とする）
    func startRecording(timestamp: TimeInterval, sessionID: String) {
        print("📹 [CameraManager] ========== START RECORDING ==========")
        print("📹 [CameraManager] SessionID: \(sessionID)")

        self.syncTimestamp = timestamp
        self.sessionID = sessionID

        // セッションが動いていない場合のみ起動してから録画（フォールバック）
        guard let session = captureSession, session.isRunning else {
            print("⚠️ [CameraManager] Session not running – starting session first")
            startSession { [weak self] in
                self?.beginRecording(timestamp: timestamp, sessionID: sessionID)
            }
            return
        }

        // 通常パス: すでに起動済みなので即録画開始
        beginRecording(timestamp: timestamp, sessionID: sessionID)
    }

    private func beginRecording(timestamp: TimeInterval, sessionID: String) {
        guard let output = videoOutput else {
            error = "ビデオ出力が設定されていません"
            print("❌ [CameraManager] videoOutput が nil")
            return
        }
        guard !output.isRecording else {
            print("⚠️ [CameraManager] 既に録画中です")
            return
        }

        let fileName = "cinecam_\(sessionID)_\(UIDevice.current.name.replacingOccurrences(of: " ", with: "_"))_\(Int(timestamp)).mov"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
        currentVideoURL = fileURL

        print("📁 [CameraManager] 保存先: \(fileURL.path)")
        output.startRecording(to: fileURL, recordingDelegate: self)

        DispatchQueue.main.async {
            self.isRecording = true
            OrientationLock.isRecording = true
            // recordingStartTime は didStartRecordingTo デリゲートで設定する
            // （実際にカメラが録画を開始した瞬間に合わせるため）
        }
        print("🎥 [CameraManager] 録画開始: \(fileName)")
        print("📹 [CameraManager] ==========================================")
    }
    /// 録画停止（停止後はカメラセッションも完全に止める）
    func stopRecording() {
        print("📹 [CameraManager] ========== STOP RECORDING ==========")
        print("📹 [CameraManager] Current SessionID: '\(self.sessionID)'")
        
        guard let output = videoOutput, output.isRecording else {
            print("⚠️ [CameraManager] 録画していません")
            return
        }
        
        print("📹 [CameraManager] Stopping recording...")
        output.stopRecording()
        // ※ セッション停止は fileOutput(_:didFinishRecordingTo:) の完了後に行う
        // （先に止めると録画ファイルが壊れる可能性があるため）
        
        DispatchQueue.main.async {
            self.isRecording = false
            OrientationLock.isRecording = false
            self.stopTimer()
            self.recordingDuration = 0
        }
        
        print("⏹️ [CameraManager] 録画停止リクエスト送信")
        print("📹 [CameraManager] ==========================================")
    }
    
    /// タイマー開始
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.recordingStartTime else { return }
            self.recordingDuration = Date().timeIntervalSince(startTime)
        }
    }
    
    /// タイマー停止
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    /// カメラセッション停止
    func stopSession() {
        sessionQueue.async { [weak self] in
            self?.captureSession?.stopRunning()
            print("🛑 カメラセッション停止")
        }
        stopTimer()
        DispatchQueue.main.async {
            self.previewLayer = nil
        }
    }
    
    // MARK: - Helper Methods
    
    /// カメラロールに保存
    private func saveToPhotoLibrary(videoURL: URL) {
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized else {
                print("写真ライブラリへのアクセスが許可されていません")
                return
            }
            
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
            }) { success, error in
                DispatchQueue.main.async {
                    if success {
                        print("✅ カメラロールに保存完了: \(videoURL.lastPathComponent)")
                    } else if let error = error {
                        print("❌ 保存失敗: \(error.localizedDescription)")
                        self.error = "保存失敗: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        print("📹 録画開始: \(fileURL.lastPathComponent)")
        // カメラが実際に録画を開始した瞬間にタイマーをスタート
        // （beginRecording() 呼び出しタイミングではなくここで設定することで
        //   マスター・スレーブ間の非同期起動ズレをタイマーに反映させない）
        DispatchQueue.main.async {
            self.isRecording = true
            self.recordingStartTime = Date()
            self.startTimer()
        }
    }
    
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        print("📹 [CameraManager] ========== DID FINISH RECORDING ==========")
        print("📹 [CameraManager] URL: \(outputFileURL.path)")
        print("📹 [CameraManager] File exists: \(FileManager.default.fileExists(atPath: outputFileURL.path))")
        print("📹 [CameraManager] SessionID: '\(self.sessionID)'")
        print("📹 [CameraManager] SessionID isEmpty: \(self.sessionID.isEmpty)")
        print("📹 [CameraManager] Callback exists: \(onRecordingCompleted != nil)")
        
        if let error = error {
            print("❌ [CameraManager] 録画エラー: \(error.localizedDescription)")
            self.error = "録画エラー: \(error.localizedDescription)"
            return
        }
        
        print("✅ [CameraManager] 録画完了: \(outputFileURL.lastPathComponent)")
        
        // ファイルサイズ確認
        if let fileSize = try? FileManager.default.attributesOfItem(atPath: outputFileURL.path)[.size] as? UInt64 {
            print("📹 [CameraManager] File size: \(fileSize) bytes")
        }
        
        // ファイルパスを保存
        self.lastRecordedVideoURL = outputFileURL
        
        // カメラロールに保存
        saveToPhotoLibrary(videoURL: outputFileURL)

        // ✅ カメラセッションは停止しない（次の録画やプレビューに備えて維持する）
        //    セッション停止は stopSession()（onDisappear）でのみ行う
        
        // SessionIDを一時保存（コールバック用）
        let currentSessionID = self.sessionID
        
        // 録画完了コールバック（SessionIDと共に通知）
        if !currentSessionID.isEmpty {
            print("📹 [CameraManager] ✅ Calling completion callback with SessionID: \(currentSessionID)")
            onRecordingCompleted?(outputFileURL, currentSessionID)
            print("📹 [CameraManager] ✅ Callback invoked")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                print("📹 [CameraManager] Clearing SessionID")
                self.sessionID = ""
            }
        } else {
            print("⚠️ [CameraManager] ❌ SessionID is empty, NOT calling callback")
        }
        
        print("📹 [CameraManager] ================================================")
    }
}
