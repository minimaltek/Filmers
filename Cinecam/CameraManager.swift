//
//  CameraManager.swift
//  Cinecam
//
//  Phase 2: カメラ録画機能
//

import Foundation
import AVFoundation
import UIKit
// Photos framework は不要（カメラロールへの保存は CinecamExportEngine で行う）
import Combine

class CameraManager: NSObject, ObservableObject {
    // MARK: - Preview Support
    
    /// プレビュー用のモックインスタンス
    static var previewMock: CameraManager {
        let m = CameraManager()
        // 実機ハード依存の起動は行わず、最低限のダミー状態を用意
        m.isRecording = false
        m.recordingDuration = 0
        m.previewLayer = nil
        m.currentCamera = nil
        return m
    }

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
    @Published var desiredOrientation: VideoOrientation = .cinema
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
    
    // MARK: - Orientation Helper
    
    /// 端末の現在の物理的な向きに対応する AVCaptureVideoOrientation を返す
    static func currentCaptureOrientation() -> AVCaptureVideoOrientation {
        // UIDevice.orientation is the physical device orientation,
        // which updates even when interface rotation is locked.
        switch UIDevice.current.orientation {
        case .portrait:            return .portrait
        case .portraitUpsideDown:   return .portraitUpsideDown
        case .landscapeLeft:       return .landscapeRight  // device left = video right
        case .landscapeRight:      return .landscapeLeft   // device right = video left
        default:
            // .faceUp / .faceDown / .unknown → fall back to interface orientation
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
                return .portrait
            }
            switch scene.interfaceOrientation {
            case .landscapeLeft:  return .landscapeLeft
            case .landscapeRight: return .landscapeRight
            default:              return .portrait
            }
        }
    }
    
    /// プレビューと録画接続のorientationを現在の端末向きに更新する
    func updateOrientationForConnections() {
        let orientation = CameraManager.currentCaptureOrientation()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            // 録画接続
            if let connection = self.videoOutput?.connection(with: .video),
               connection.isVideoOrientationSupported {
                connection.videoOrientation = orientation
            }
            // プレビュー接続
            DispatchQueue.main.async {
                if let previewConnection = self.previewLayer?.connection,
                   previewConnection.isVideoOrientationSupported {
                    previewConnection.videoOrientation = orientation
                }
            }
        }
    }
    
    // MARK: - Initialization
    
    override init() {
        super.init()
    }
    
    // MARK: - Public Methods
    
    /// カメラのセットアップと起動
    func setupCamera() {
        print("🎥 [CameraManager] setupCamera() called")
        // Preview 環境では実セッションを起動しない
        if PreviewDetection.isRunningForPreviews {
            print("🧪 [CameraManager] Running in Preview – skipping camera setup")
            return
        }
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
    
    /// セッション起動(録画開始直前に呼ぶ)
    func startSession(completion: @escaping () -> Void) {
        // Preview 環境ではセッションを起動しない
        if PreviewDetection.isRunningForPreviews {
            print("🧪 [CameraManager] Running in Preview – skipping startSession")
            completion()
            return
        }
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
        // Preview 環境では実セッションを構成しない
        if PreviewDetection.isRunningForPreviews {
            print("🧪 [CameraManager] Running in Preview – skipping configureCaptureSession")
            DispatchQueue.main.async {
                self.captureSession = nil
                self.videoOutput = nil
                self.previewLayer = nil
                self.currentCamera = nil
                completion?()
            }
            return
        }
        // Ensure device orientation notifications are enabled
        DispatchQueue.main.async {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        }
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
                        // 端末の現在の向きに合わせて録画する
                        connection.videoOrientation = CameraManager.currentCaptureOrientation()
                    }
                    print("✅ [CameraManager] Video output added")
                }

                session.commitConfiguration()
                print("✅ [CameraManager] Session configuration committed")

                let preview = AVCaptureVideoPreviewLayer(session: session)
                preview.videoGravity = .resizeAspectFill
                if preview.connection?.isVideoOrientationSupported == true {
                    // 端末の現在の向きに合わせる
                    preview.connection?.videoOrientation = CameraManager.currentCaptureOrientation()
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
            
            let previousPreset = session.sessionPreset
            
            session.beginConfiguration()
            session.removeInput(currentInput)
            
            // ユーザー設定のプリセットに戻せるか試し、非対応なら降格
            // （iPadのフロントカメラは4Kをサポートしないことが多い）
            if camera.supportsSessionPreset(self.videoResolution) {
                // バックカメラに戻す時など、ユーザー設定のプリセットに復帰
                if session.sessionPreset != self.videoResolution {
                    session.sessionPreset = self.videoResolution
                    print("✅ [CameraManager] Preset restored to \(self.videoResolution.rawValue)")
                }
            } else {
                let fallbacks: [AVCaptureSession.Preset] = [.hd1920x1080, .hd1280x720, .high]
                for preset in fallbacks {
                    if camera.supportsSessionPreset(preset) {
                        session.sessionPreset = preset
                        print("⚠️ [CameraManager] Preset downgraded to \(preset.rawValue) for \(camera.localizedName)")
                        break
                    }
                }
            }
            
            do {
                let newInput = try AVCaptureDeviceInput(device: camera)
                if session.canAddInput(newInput) {
                    session.addInput(newInput)
                    self.videoInput = newInput
                    
                    // ビデオ出力のorientation を再設定
                    if let connection = self.videoOutput?.connection(with: .video),
                       connection.isVideoOrientationSupported {
                        connection.videoOrientation = CameraManager.currentCaptureOrientation()
                    }
                    
                    // プレビューレイヤーのorientationも再設定
                    DispatchQueue.main.async {
                        self.currentCamera = camera
                        self.zoomFactor = 1.0
                        if let previewConnection = self.previewLayer?.connection,
                           previewConnection.isVideoOrientationSupported {
                            previewConnection.videoOrientation = CameraManager.currentCaptureOrientation()
                        }
                    }
                    
                    self.configureDevice(camera)
                    print("✅ カメラ切り替え: \(camera.localizedName)")
                } else {
                    // canAddInput失敗 → 元のカメラ入力を復元
                    print("⚠️ [CameraManager] canAddInput failed – restoring previous camera")
                    session.sessionPreset = previousPreset
                    if session.canAddInput(currentInput) {
                        session.addInput(currentInput)
                    }
                }
            } catch {
                // 例外発生 → 元のカメラ入力を復元
                print("❌ [CameraManager] switchCamera error: \(error.localizedDescription) – restoring previous camera")
                session.sessionPreset = previousPreset
                if session.canAddInput(currentInput) {
                    session.addInput(currentInput)
                }
                DispatchQueue.main.async {
                    self.error = "Failed to switch camera"
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
        // Preview 環境ではトーチを操作しない
        if PreviewDetection.isRunningForPreviews { return }
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
        // Preview 環境では録画を行わない
        if PreviewDetection.isRunningForPreviews {
            print("🧪 [CameraManager] Running in Preview – skipping startRecording")
            return
        }
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
        // Preview 環境では何もしない（UIのクリーンアップのみ）
        if PreviewDetection.isRunningForPreviews {
            DispatchQueue.main.async { self.previewLayer = nil }
            print("🧪 [CameraManager] Running in Preview – skipping stopSession")
            return
        }
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
        
        // カメラロールへの自動保存はしない
        // （アプリ内Documents管理 → 書き出し時にのみカメラロールに保存する）

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

