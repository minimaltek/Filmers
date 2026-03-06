//
//  CameraManager.swift
//  Cinecam
//
//  Phase 2: カメラ録画機能
//

import Foundation
import AVFoundation
import UIKit
import CoreImage
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
    /// 現在のカメラデバイスがトーチ（撮影ライト）を搭載しているか
    var hasTorch: Bool {
        currentCamera?.hasTorch == true
    }
    @Published var exposureBias: Float = 0.0  // 露出補正値
    
    // 録画設定（UserDefaults で永続化）
    @Published var desiredOrientation: VideoOrientation = .cinema {
        didSet { UserDefaults.standard.set(desiredOrientation.rawValue, forKey: "cinecam.desiredOrientation") }
    }
    var videoOrientation: AVCaptureVideoOrientation = .landscapeRight  // デフォルト: 横向き
    @Published var videoCodec: AVVideoCodecType = .hevc {
        didSet { UserDefaults.standard.set(VideoCodec.from(avCodec: videoCodec).rawValue, forKey: "cinecam.videoCodec") }
    }
    
    private var captureSession: AVCaptureSession?
    
    /// カメラセッションが実行中かどうか
    var isCameraSessionRunning: Bool {
        captureSession?.isRunning == true
    }
    private var videoOutput: AVCaptureMovieFileOutput?
    private var currentVideoURL: URL?
    private var recordingStartTime: Date?
    private var timer: Timer?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    
    // MARK: - Snapshot (Multi-Monitor)
    private var snapshotOutput: AVCaptureVideoDataOutput?
    private let snapshotQueue = DispatchQueue(label: "com.cinecam.snapshot", qos: .utility)
    /// CIContext はコストが高いので使い回す
    private lazy var snapshotCIContext = CIContext(options: [.useSoftwareRenderer: false])
    /// 最新スナップショット（JPEG Data） — メインスレッドから読み書きする
    @Published var latestSnapshot: Data?
    /// スナップショット取得を有効にするフラグ
    var isSnapshotEnabled = false
    /// フレーム間引き：最後にスナップショットを処理した時刻
    private var lastSnapshotTime: CFAbsoluteTime = 0
    /// スナップショットの最小処理間隔（秒）
    private let snapshotInterval: CFTimeInterval = 0.4

    // AVCaptureSession 専用の直列キュー。
    // global(qos:) を使うと MCSession の内部処理と同じスレッドプールを奪い合い、
    // startRunning() の長時間ブロックが MCSession のタイムアウト切断を引き起こす。
    private let sessionQueue = DispatchQueue(label: "com.cinecam.captureSession", qos: .default)
    
    // 録画開始時のタイムスタンプ（同期用）
    private var syncTimestamp: TimeInterval = 0
    private var sessionID: String = ""
    /// カメラ切替のための意図的な録画停止中フラグ（安全ガード用）
    private var isSwitchingCamera = false
    
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
            // スナップショット接続
            if let snapConn = self.snapshotOutput?.connection(with: .video),
               snapConn.isVideoOrientationSupported {
                snapConn.videoOrientation = orientation
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
        // UserDefaults から保存済み設定を復元
        if let orientationRaw = UserDefaults.standard.string(forKey: "cinecam.desiredOrientation"),
           let orientation = VideoOrientation(rawValue: orientationRaw) {
            desiredOrientation = orientation
            videoOrientation = orientation.avOrientation
        }
        if let codecRaw = UserDefaults.standard.string(forKey: "cinecam.videoCodec"),
           let codec = VideoCodec(rawValue: codecRaw) {
            videoCodec = codec.avCodec
        }
    }
    
    // MARK: - Public Methods
    
    /// カメラのセットアップと起動
    func setupCamera() {
        #if DEBUG
        print("🎥 [CameraManager] setupCamera() called")
        #endif
        // Preview 環境では実セッションを起動しない
        if PreviewDetection.isRunningForPreviews {
            #if DEBUG
            print("🧪 [CameraManager] Running in Preview – skipping camera setup")
            #endif
            return
        }
        // 既にセッションが起動済みならスキップ（2重セットアップ防止）
        if let session = captureSession, session.isRunning {
            #if DEBUG
            print("⚠️ [CameraManager] Session already running – skipping setup")
            #endif
            return
        }
        checkCameraPermission { [weak self] granted in
            #if DEBUG
            print("🎥 [CameraManager] Permission granted: \(granted)")
            #endif
            if granted {
                // カメラを設定して起動する
                self?.configureCaptureSession(thenStart: true)
            } else {
                self?.error = "Camera access is not permitted"
                #if DEBUG
                print("❌ [CameraManager] Camera permission denied")
                #endif
            }
        }
    }
    
    /// セッション起動(録画開始直前に呼ぶ)
    func startSession(completion: @escaping () -> Void) {
        // Preview 環境ではセッションを起動しない
        if PreviewDetection.isRunningForPreviews {
            #if DEBUG
            print("🧪 [CameraManager] Running in Preview – skipping startSession")
            #endif
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
            #if DEBUG
            print("🎥 カメラセッション開始")
            #endif
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
        #if DEBUG
        print("🎥 [CameraManager] configureCaptureSession called, thenStart: \(thenStart)")
        #endif
        // Preview 環境では実セッションを構成しない
        if PreviewDetection.isRunningForPreviews {
            #if DEBUG
            print("🧪 [CameraManager] Running in Preview – skipping configureCaptureSession")
            #endif
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
        // ★ UIKit API はメインスレッドでのみ呼べるので、事前に取得しておく
        let capturedOrientation = CameraManager.currentCaptureOrientation()
        sessionQueue.async { [weak self] in
            guard let self else { return }

            #if DEBUG
            print("🎥 [CameraManager] Creating AVCaptureSession...")
            #endif
            let session = AVCaptureSession()
            session.beginConfiguration()
            session.sessionPreset = self.videoResolution

            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                #if DEBUG
                print("❌ [CameraManager] Camera not found")
                #endif
                DispatchQueue.main.async { self.error = "Camera not found" }
                return
            }

            #if DEBUG
            print("🎥 [CameraManager] Camera found: \(camera.localizedName)")
            #endif

            do {
                let videoInput = try AVCaptureDeviceInput(device: camera)
                if session.canAddInput(videoInput) { 
                    session.addInput(videoInput)
                    self.videoInput = videoInput
                    #if DEBUG
                    print("✅ [CameraManager] Video input added")
                    #endif
                }

                if let audioDevice = AVCaptureDevice.default(for: .audio) {
                    let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                    if session.canAddInput(audioInput) { 
                        session.addInput(audioInput)
                        self.audioInput = audioInput
                        #if DEBUG
                        print("✅ [CameraManager] Audio input added")
                        #endif
                    }
                }

                let output = AVCaptureMovieFileOutput()
                
                // コーデック設定
                if output.availableVideoCodecTypes.contains(self.videoCodec),
                   let videoConnection = output.connection(with: .video) {
                    output.setOutputSettings([AVVideoCodecKey: self.videoCodec], for: videoConnection)
                    #if DEBUG
                    print("✅ [CameraManager] Video codec set to: \(self.videoCodec.rawValue)")
                    #endif
                }
                
                if session.canAddOutput(output) {
                    session.addOutput(output)
                    if let connection = output.connection(with: .video),
                       connection.isVideoOrientationSupported {
                        // 端末の現在の向きに合わせて録画する
                        connection.videoOrientation = capturedOrientation
                    }
                    #if DEBUG
                    print("✅ [CameraManager] Video output added")
                    #endif
                }
                
                // スナップショット用 VideoDataOutput
                let snapOutput = AVCaptureVideoDataOutput()
                snapOutput.alwaysDiscardsLateVideoFrames = true
                snapOutput.setSampleBufferDelegate(self, queue: self.snapshotQueue)
                if session.canAddOutput(snapOutput) {
                    session.addOutput(snapOutput)
                    if let snapConn = snapOutput.connection(with: .video),
                       snapConn.isVideoOrientationSupported {
                        snapConn.videoOrientation = capturedOrientation
                    }
                    self.snapshotOutput = snapOutput
                    #if DEBUG
                    print("✅ [CameraManager] Snapshot output added")
                    #endif
                }

                session.commitConfiguration()
                #if DEBUG
                print("✅ [CameraManager] Session configuration committed")
                #endif

                let preview = AVCaptureVideoPreviewLayer(session: session)
                preview.videoGravity = .resizeAspectFill
                if preview.connection?.isVideoOrientationSupported == true {
                    // 端末の現在の向きに合わせる
                    preview.connection?.videoOrientation = capturedOrientation
                }

                // UI 更新だけメインスレッドへ
                DispatchQueue.main.async {
                    self.captureSession = session
                    self.videoOutput = output
                    self.previewLayer = preview
                    self.currentCamera = camera
                    #if DEBUG
                    print("✅ [CameraManager] previewLayer set on main thread")
                    #endif
                }
                
                // 初期設定を適用
                self.configureDevice(camera)

                if thenStart {
                    // startRunning() は同じ sessionQueue で同期実行（ブロックするがキューは専用なので安全）
                    #if DEBUG
                    print("🎥 [CameraManager] Starting camera session...")
                    #endif
                    session.startRunning()
                    #if DEBUG
                    print("✅ [CameraManager] Camera session started, isRunning: \(session.isRunning)")
                    #endif
                    DispatchQueue.main.async {
                        completion?()
                    }
                } else {
                    #if DEBUG
                    print("⚠️ [CameraManager] Session configured but NOT started (thenStart=false)")
                    #endif
                }

            } catch {
                #if DEBUG
                print("❌ [CameraManager] Configuration error: \(error.localizedDescription)")
                #endif
                DispatchQueue.main.async {
                    self.error = "Failed to configure camera: \(error.localizedDescription)"
                }
            }
        }
    }
    
    // MARK: - Camera Control Methods
    
    /// カメラを切り替え
    func switchCamera(to camera: AVCaptureDevice) {
        let capturedOrientation = CameraManager.currentCaptureOrientation()
        sessionQueue.async { [weak self] in
            guard let self,
                  let session = self.captureSession,
                  let currentInput = self.videoInput else { return }
            
            // 録画中はカメラ切替を拒否（UI側で非活性にしているが念のためガード）
            guard self.videoOutput?.isRecording != true else {
                #if DEBUG
                print("⚠️ [CameraManager] Cannot switch camera while recording")
                #endif
                return
            }
            
            let previousPreset = session.sessionPreset
            self.performCameraSwitch(session: session, from: currentInput, to: camera,
                                     orientation: capturedOrientation, previousPreset: previousPreset)
        }
    }
    
    /// カメラ入力の切り替え（録画状態に関係なく安全に実行）
    private func performCameraSwitch(session: AVCaptureSession,
                                     from currentInput: AVCaptureDeviceInput,
                                     to camera: AVCaptureDevice,
                                     orientation: AVCaptureVideoOrientation,
                                     previousPreset: AVCaptureSession.Preset) {
        session.beginConfiguration()
        session.removeInput(currentInput)
        
        // プリセット調整
        if camera.supportsSessionPreset(self.videoResolution) {
            if session.sessionPreset != self.videoResolution {
                session.sessionPreset = self.videoResolution
                #if DEBUG
                print("✅ [CameraManager] Preset restored to \(self.videoResolution.rawValue)")
                #endif
            }
        } else {
            let fallbacks: [AVCaptureSession.Preset] = [.hd1920x1080, .hd1280x720, .high]
            for preset in fallbacks {
                if camera.supportsSessionPreset(preset) {
                    session.sessionPreset = preset
                    #if DEBUG
                    print("⚠️ [CameraManager] Preset downgraded to \(preset.rawValue) for \(camera.localizedName)")
                    #endif
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
                    connection.videoOrientation = orientation
                }
                // スナップショット出力のorientationも再設定
                if let snapConn = self.snapshotOutput?.connection(with: .video),
                   snapConn.isVideoOrientationSupported {
                    snapConn.videoOrientation = orientation
                }
                
                // プレビューレイヤーのorientationも再設定
                DispatchQueue.main.async {
                    self.currentCamera = camera
                    self.zoomFactor = 1.0
                    if let previewConnection = self.previewLayer?.connection,
                       previewConnection.isVideoOrientationSupported {
                        previewConnection.videoOrientation = orientation
                    }
                }
                
                self.configureDevice(camera)
                #if DEBUG
                print("✅ カメラ切り替え: \(camera.localizedName)")
                #endif
            } else {
                // canAddInput失敗 → 元のカメラ入力を復元
                #if DEBUG
                print("⚠️ [CameraManager] canAddInput failed – restoring previous camera")
                #endif
                session.sessionPreset = previousPreset
                if session.canAddInput(currentInput) {
                    session.addInput(currentInput)
                }
            }
        } catch {
            // 例外発生 → 元のカメラ入力を復元
            #if DEBUG
            print("❌ [CameraManager] switchCamera error: \(error.localizedDescription) – restoring previous camera")
            #endif
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
            #if DEBUG
            print("⚠️ デバイス設定エラー: \(error.localizedDescription)")
            #endif
        }
    }
    
    /// 解像度を更新
    private func updateSessionPreset() {
        sessionQueue.async { [weak self] in
            guard let self, let session = self.captureSession else { return }
            session.beginConfiguration()
            if session.canSetSessionPreset(self.videoResolution) {
                session.sessionPreset = self.videoResolution
                #if DEBUG
                print("✅ 解像度変更: \(self.videoResolution.rawValue)")
                #endif
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
                #if DEBUG
                print("✅ ビデオ安定化: \(self.videoStabilization ? "ON" : "OFF")")
                #endif
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
                    #if DEBUG
                    print("✅ フォーカスモード: \(self.focusMode.rawValue)")
                    #endif
                }
                device.unlockForConfiguration()
            } catch {
                #if DEBUG
                print("⚠️ フォーカスモード設定エラー: \(error.localizedDescription)")
                #endif
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
                    #if DEBUG
                    print("✅ 露出モード: \(self.exposureMode.rawValue)")
                    #endif
                }
                device.unlockForConfiguration()
            } catch {
                #if DEBUG
                print("⚠️ 露出モード設定エラー: \(error.localizedDescription)")
                #endif
            }
        }
    }
    
    /// 露出補正値（EV）を設定
    func setExposureBias(_ bias: Float) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentCamera else { return }
            let clamped = max(device.minExposureTargetBias, min(bias, device.maxExposureTargetBias))
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(clamped, completionHandler: nil)
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.exposureBias = clamped
                }
            } catch {
                #if DEBUG
                print("⚠️ 露出補正エラー: \(error.localizedDescription)")
                #endif
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
                    #if DEBUG
                    print("✅ ホワイトバランス: \(self.whiteBalanceMode.rawValue)")
                    #endif
                }
                device.unlockForConfiguration()
            } catch {
                #if DEBUG
                print("⚠️ ホワイトバランス設定エラー: \(error.localizedDescription)")
                #endif
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
                #if DEBUG
                print("⚠️ ズーム設定エラー: \(error.localizedDescription)")
                #endif
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
                #if DEBUG
                print("⚠️ トーチが利用できません")
                #endif
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
                #if DEBUG
                print("⚠️ トーチ設定エラー: \(error.localizedDescription)")
                #endif
            }
        }
    }
    
    /// 録画開始（カメラセッションは常時起動済みを前提とする）
    func startRecording(timestamp: TimeInterval, sessionID: String) {
        // Preview 環境では録画を行わない
        if PreviewDetection.isRunningForPreviews {
            #if DEBUG
            print("🧪 [CameraManager] Running in Preview – skipping startRecording")
            #endif
            return
        }
        #if DEBUG
        print("📹 [CameraManager] ========== START RECORDING ==========")
        print("📹 [CameraManager] SessionID: \(sessionID)")
        #endif

        self.syncTimestamp = timestamp
        self.sessionID = sessionID

        // セッションが動いていない場合のみ起動してから録画（フォールバック）
        guard let session = captureSession, session.isRunning else {
            #if DEBUG
            print("⚠️ [CameraManager] Session not running – starting session first")
            #endif
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
            error = "Video output is not configured"
            #if DEBUG
            print("❌ [CameraManager] videoOutput が nil")
            #endif
            return
        }
        guard !output.isRecording else {
            #if DEBUG
            print("⚠️ [CameraManager] 既に録画中です")
            #endif
            return
        }

        let fileName = "cinecam_\(sessionID)_\(UIDevice.current.name.replacingOccurrences(of: " ", with: "_"))_\(Int(timestamp)).mov"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
        currentVideoURL = fileURL

        #if DEBUG
        print("📁 [CameraManager] 保存先: \(fileURL.path)")
        #endif
        output.startRecording(to: fileURL, recordingDelegate: self)

        DispatchQueue.main.async {
            self.isRecording = true
            OrientationLock.isRecording = true
            // recordingStartTime は didStartRecordingTo デリゲートで設定する
            // （実際にカメラが録画を開始した瞬間に合わせるため）
        }
        #if DEBUG
        print("🎥 [CameraManager] 録画開始: \(fileName)")
        print("📹 [CameraManager] ==========================================")
        #endif
    }
    /// 録画停止（停止後はカメラセッションも完全に止める）
    func stopRecording() {
        #if DEBUG
        print("📹 [CameraManager] ========== STOP RECORDING ==========")
        print("📹 [CameraManager] Current SessionID: '\(self.sessionID)'")
        #endif
        
        guard let output = videoOutput, output.isRecording else {
            #if DEBUG
            print("⚠️ [CameraManager] 録画していません")
            #endif
            return
        }
        
        #if DEBUG
        print("📹 [CameraManager] Stopping recording...")
        #endif
        output.stopRecording()
        // ※ セッション停止は fileOutput(_:didFinishRecordingTo:) の完了後に行う
        // （先に止めると録画ファイルが壊れる可能性があるため）
        
        DispatchQueue.main.async {
            self.isRecording = false
            OrientationLock.isRecording = false
            self.stopTimer()
            self.recordingDuration = 0
        }
        
        #if DEBUG
        print("⏹️ [CameraManager] 録画停止リクエスト送信")
        print("📹 [CameraManager] ==========================================")
        #endif
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
            #if DEBUG
            print("🧪 [CameraManager] Running in Preview – skipping stopSession")
            #endif
            return
        }
        sessionQueue.async { [weak self] in
            self?.captureSession?.stopRunning()
            #if DEBUG
            print("🛑 カメラセッション停止")
            #endif
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
        #if DEBUG
        print("📹 録画開始: \(fileURL.lastPathComponent)")
        #endif
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
        #if DEBUG
        print("📹 [CameraManager] ========== DID FINISH RECORDING ==========")
        print("📹 [CameraManager] URL: \(outputFileURL.path)")
        print("📹 [CameraManager] File exists: \(FileManager.default.fileExists(atPath: outputFileURL.path))")
        print("📹 [CameraManager] SessionID: '\(self.sessionID)'")
        print("📹 [CameraManager] SessionID isEmpty: \(self.sessionID.isEmpty)")
        print("📹 [CameraManager] Callback exists: \(onRecordingCompleted != nil)")
        #endif
        
        if let error = error {
            #if DEBUG
            print("❌ [CameraManager] Recording error: \(error.localizedDescription)")
            #endif
            DispatchQueue.main.async {
                self.isRecording = false
                OrientationLock.isRecording = false
                self.stopTimer()
                self.recordingDuration = 0
            }
            self.error = "Recording error: \(error.localizedDescription)"
            // エラーでもファイルが残っていれば保存を試みる
            if FileManager.default.fileExists(atPath: outputFileURL.path),
               let fileSize = try? FileManager.default.attributesOfItem(atPath: outputFileURL.path)[.size] as? UInt64,
               fileSize > 1000 {
                #if DEBUG
                print("📹 [CameraManager] Error but file exists (\(fileSize) bytes) – attempting to save")
                #endif
                self.lastRecordedVideoURL = outputFileURL
                let currentSessionID = self.sessionID
                if !currentSessionID.isEmpty {
                    onRecordingCompleted?(outputFileURL, currentSessionID)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.sessionID = ""
                    }
                }
            }
            return
        }
        
        #if DEBUG
        print("✅ [CameraManager] Recording completed: \(outputFileURL.lastPathComponent)")
        #endif
        
        // ファイルサイズ確認
        if let fileSize = try? FileManager.default.attributesOfItem(atPath: outputFileURL.path)[.size] as? UInt64 {
            #if DEBUG
            print("📹 [CameraManager] File size: \(fileSize) bytes")
            #endif
        }
        
        // ファイルパスを保存
        self.lastRecordedVideoURL = outputFileURL
        
        // SessionIDを一時保存（コールバック用）
        let currentSessionID = self.sessionID
        
        if !currentSessionID.isEmpty {
            #if DEBUG
            print("📹 [CameraManager] ✅ Calling completion callback with SessionID: \(currentSessionID)")
            #endif
            onRecordingCompleted?(outputFileURL, currentSessionID)
            #if DEBUG
            print("📹 [CameraManager] ✅ Callback invoked")
            #endif
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                #if DEBUG
                print("📹 [CameraManager] Clearing SessionID")
                #endif
                self.sessionID = ""
            }
        } else {
            #if DEBUG
            print("⚠️ [CameraManager] ❌ SessionID is empty, NOT calling callback")
            #endif
        }
        
        #if DEBUG
        print("📹 [CameraManager] ================================================")
        #endif
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate (Snapshot)

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isSnapshotEnabled else { return }
        
        // フレーム間引き：snapshotInterval 未満のフレームはスキップ
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastSnapshotTime >= snapshotInterval else { return }
        lastSnapshotTime = now
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // desiredOrientation に合わせてクロップ
        let fullW = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let fullH = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let targetRatio = desiredOrientation.aspectRatio
        let currentRatio = fullW / fullH
        
        let cropRect: CGRect
        if abs(currentRatio - targetRatio) < 0.05 {
            cropRect = CGRect(x: 0, y: 0, width: fullW, height: fullH)
        } else if targetRatio > currentRatio {
            let newH = fullW / targetRatio
            cropRect = CGRect(x: 0, y: (fullH - newH) / 2, width: fullW, height: newH)
        } else {
            let newW = fullH * targetRatio
            cropRect = CGRect(x: (fullW - newW) / 2, y: 0, width: newW, height: fullH)
        }
        
        let cropped = ciImage.cropped(to: cropRect)
        
        // 帯域節約のため小さいサイズにリサイズ（幅320px程度）
        let scale = 320.0 / cropRect.width
        let resized = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        guard let cgImage = snapshotCIContext.createCGImage(resized, from: resized.extent) else { return }
        let uiImage = UIImage(cgImage: cgImage)
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.4) else { return }
        
        DispatchQueue.main.async {
            self.latestSnapshot = jpegData
        }
    }
}

