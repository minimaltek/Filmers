//
//  PreviewView.swift
//  Cinecam
//

import SwiftUI
import AVKit
import AVFoundation
import AVFAudio
import Combine
// MARK: - FilterParamsHolder
/// AVMutableVideoComposition プレビュー用のスレッドセーフなフィルタパラメータホルダー。
/// composition の handler が毎フレーム snapshot() で読み取り、
/// パラメータ変更は update() で即座に反映される（composition 再生成不要）。
final class FilterParamsHolder: @unchecked Sendable {
    private let lock = NSLock()

    private var _videoFilter: String? = nil
    private var _kaleidoscopeType: String? = nil
    private var _kaleidoscopeSize: Float = 200
    private var _centerX: Float = 0.5
    private var _centerY: Float = 0.5
    private var _tileHeight: Float = 200
    private var _mirrorDirection: Int = 0
    private var _rotationAngle: Float = 0
    private var _generation: Int = 0

    struct Snapshot {
        let videoFilter: String?
        let kaleidoscopeType: String?
        let kaleidoscopeSize: Float
        let centerX: Float
        let centerY: Float
        let tileHeight: Float
        let mirrorDirection: Int
        let rotationAngle: Float
        let generation: Int
        var hasEffect: Bool { videoFilter != nil || kaleidoscopeType != nil }
    }

    func update(
        videoFilter: String?,
        kaleidoscopeType: String?,
        kaleidoscopeSize: Float,
        centerX: Float,
        centerY: Float,
        tileHeight: Float,
        mirrorDirection: Int,
        rotationAngle: Float = 0
    ) {
        lock.lock()
        _videoFilter = videoFilter
        _kaleidoscopeType = kaleidoscopeType
        _kaleidoscopeSize = kaleidoscopeSize
        _centerX = centerX
        _centerY = centerY
        _tileHeight = tileHeight
        _mirrorDirection = mirrorDirection
        _rotationAngle = rotationAngle
        _generation += 1
        lock.unlock()
    }

    /// AUTO回転用: rotationAngle だけをアトミックに更新する（他パラメータはそのまま）
    func updateRotationAngle(_ angle: Float) {
        lock.lock()
        _rotationAngle = angle
        _generation += 1
        lock.unlock()
    }

    /// 現在の rotationAngle を読み取る
    func currentRotationAngle() -> Float {
        lock.lock()
        defer { lock.unlock() }
        return _rotationAngle
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            videoFilter: _videoFilter,
            kaleidoscopeType: _kaleidoscopeType,
            kaleidoscopeSize: _kaleidoscopeSize,
            centerX: _centerX,
            centerY: _centerY,
            tileHeight: _tileHeight,
            mirrorDirection: _mirrorDirection,
            rotationAngle: _rotationAngle,
            generation: _generation
        )
    }
}

// MARK: - PlaybackController
// Timer・AVPlayer の状態をクラスで管理することで、
// struct（PreviewView）からのクロージャ参照問題を回避する

@MainActor
final class PlaybackController: ObservableObject {
    @Published var isPlaying = false
    @Published var playheadTime: Double = 0
    /// 現在プレビューに表示すべきデバイス（セグメントがない黒画面区間では "" になることもある）
    @Published var activePreviewDevice: String = "" {
        didSet { metalRenderer.activeDevice = activePreviewDevice }
    }

    /// Metal ベースのプレビューレンダラー（AVPlayerItemVideoOutput → CIFilter → MTKView）
    let metalRenderer = MetalPreviewRenderer()

    private(set) var players: [String: AVPlayer] = [:]
    private var playheadTimer: Timer?
    /// シーク中は tick() の処理をスキップする
    private var isSeeking = false
    /// シークのたびにインクリメント。古いシークコールバックを無効化するために使う
    private var seekGeneration: Int = 0
    /// トリムハンドルドラッグ中フラグ（tolerant seek を使う）
    var isTrimming = false
    /// トリムドラッグ中のシークスロットル（前回シーク時刻）
    private var lastTrimSeekTime: CFAbsoluteTime = 0
    /// 黒画面区間の再生用：区間終了時刻
    private var blackUntil: Double = 0
    /// totalDuration キャッシュ（tick 内で参照）
    var totalDuration: Double = 0
    /// 次セグメントの事前seek済み情報（device, segmentID）
    private var preloadedNext: (device: String, segID: UUID)? = nil

    /// 再生スピード倍率（1.0 = 通常速度）
    var playbackRate: Float = 1.0

    /// 音声ソースデバイス（nil = 編集に従う）
    var audioSourceDevice: String? = nil
    /// 各デバイスの映像開始オフセット（音声同期のシークに使用）
    var videoStartByDevice: [String: Double] = [:]

    // MARK: - Per-Segment Filter
    /// セグメント単位のフィルタ設定（PreviewView から同期）
    var segmentFilterSettings: [UUID: SegmentFilterSettings] = [:]
    /// グローバルフィルタ設定（セグメント個別設定がない場合のフォールバック）
    var globalFilterSettings = SegmentFilterSettings()
    /// 最後にフィルタを適用したセグメントID（重複適用防止）
    private var lastAppliedFilterSegID: UUID? = nil
    /// フィルタ適用の世代番号（古い非同期Taskの結果を破棄するため）
    private var filterGeneration: Int = 0
    /// フィルタパラメータホルダー（composition handler が毎フレーム snapshot() で読み取る）
    let filterParamsHolder = FilterParamsHolder()

    // MARK: - Composition Management (Export Only)
    // プレビューは MetalPreviewRenderer が担当。
    // AVMutableVideoComposition は export 時のみ使用される。

    // (buildAndApplyComposition / ensureComposition / removeAllCompositions は Metal 移行により削除)

    // MARK: - Pitch Shift (AVAudioEngine)
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var timePitchNode: AVAudioUnitTimePitch?
    private var audioFile: AVAudioFile?
    /// 現在ピッチエンジンで再生中のデバイス名
    private var pitchEngineDevice: String = ""
    /// ピッチ値（セント単位: 0 = 無効）
    var pitchCents: Float = 0 {
        didSet {
            timePitchNode?.pitch = pitchCents
        }
    }
    /// エンジンが動作中か
    private var isPitchEngineRunning: Bool { audioEngine?.isRunning ?? false }

    // MARK: - Auto Rotation
    private var autoRotateTimer: Timer?
    private var autoRotateLastTime: CFAbsoluteTime = 0
    /// AUTO回転速度（rad/sec, 0 = OFF）
    var autoRotateSpeed: Float = 0
    /// AUTO回転中の現在角度（オーバーレイ同期用）
    @Published var liveRotationAngle: Float = 0

    /// AUTO回転を開始する
    func startAutoRotation(speed: Float) {
        autoRotateSpeed = speed
        guard speed != 0 else {
            stopAutoRotation()
            return
        }
        autoRotateLastTime = CFAbsoluteTimeGetCurrent()
        autoRotateTimer?.invalidate()
        autoRotateTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickAutoRotation()
            }
        }
    }

    /// AUTO回転を停止する
    func stopAutoRotation() {
        autoRotateTimer?.invalidate()
        autoRotateTimer = nil
        autoRotateSpeed = 0
    }

    /// AUTO回転タイマーの毎フレーム処理
    private func tickAutoRotation() {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = Float(now - autoRotateLastTime)
        autoRotateLastTime = now
        guard autoRotateSpeed != 0, dt > 0, dt < 1.0 else { return }
        let currentAngle = filterParamsHolder.currentRotationAngle()
        let newAngle = currentAngle + autoRotateSpeed * dt
        filterParamsHolder.updateRotationAngle(newAngle)
        liveRotationAngle = newAngle
        // 一時停止中はフレームを強制更新
        if !isPlaying {
            metalRenderer.requestRender()
        }
    }

    func setup(videos: [String: URL]) {
        players = videos.mapValues { AVPlayer(url: $0) }
        metalRenderer.filterParamsHolder = filterParamsHolder
        metalRenderer.setup(players: players)
    }

    /// AVPlayer を現在の playbackRate で再生する
    private func playAtRate(_ player: AVPlayer?) {
        player?.rate = playbackRate
    }

    func teardown() {
        seekGeneration += 1   // 残留シークコールバックを無効化
        preloadedNext = nil
        players.values.forEach { $0.pause() }
        stopPitchEngine()
        stopAutoRotation()
        stopTimer()
        metalRenderer.teardown()
    }

    // MARK: - Pitch Engine Setup / Control

    /// デバイス → 抽出済み M4A URL のキャッシュ
    private var extractedAudioByDevice: [String: URL] = [:]
    /// 現在抽出中のデバイス（二重実行防止）
    private var extractingDevices: Set<String> = []
    /// 抽出完了待ちコールバック（抽出中に呼ばれた場合にキューイング）
    private var pendingCallbacks: [String: [(URL?) -> Void]] = [:]
    /// 音声抽出中フラグ（UI でローディング表示に使う）
    @Published var isExtractingAudio: Bool = false

    /// 動画ファイルから音声を M4A に抽出する（バックグラウンド、高速）
    func extractAudioIfNeeded(device: String, videoURL: URL, completion: @escaping (URL?) -> Void) {
        // キャッシュにある場合は即返す
        if let cached = extractedAudioByDevice[device],
           FileManager.default.fileExists(atPath: cached.path) {
            completion(cached)
            return
        }
        // 既に抽出中なら完了待ちキューに追加
        if extractingDevices.contains(device) {
            pendingCallbacks[device, default: []].append(completion)
            print("[PITCH] Queued callback for \(device) (waiting for extraction)")
            return
        }
        extractingDevices.insert(device)
        isExtractingAudio = true

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pitch_\(device.hashValue)")
            .appendingPathExtension("m4a")

        print("[PITCH] Extracting audio for \(device)...")

        // AVURLAsset / AVAssetExportSession の生成はメインスレッドをブロックするため
        // バックグラウンドで実行する
        Task.detached(priority: .userInitiated) { [weak self] in
            // 前回の残りファイルを削除
            try? FileManager.default.removeItem(at: outURL)

            let asset = AVURLAsset(url: videoURL)
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                print("[PITCH] Could not create export session")
                await MainActor.run { [weak self] in
                    self?.extractingDevices.remove(device)
                    self?.isExtractingAudio = !(self?.extractingDevices.isEmpty ?? true)
                    completion(nil)
                }
                return
            }
            session.outputFileType = .m4a
            session.outputURL = outURL

            await session.export()
            let status = session.status
            let error = session.error

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.extractingDevices.remove(device)
                self.isExtractingAudio = !self.extractingDevices.isEmpty

                let resultURL: URL?
                switch status {
                case .completed:
                    print("[PITCH] Audio extracted: \(outURL.lastPathComponent)")
                    self.extractedAudioByDevice[device] = outURL
                    resultURL = outURL
                default:
                    print("[PITCH] Export failed: \(error?.localizedDescription ?? "unknown")")
                    resultURL = nil
                }

                // メインのコールバック
                completion(resultURL)
                // 待機中のコールバックも全て呼ぶ
                if let pending = self.pendingCallbacks.removeValue(forKey: device) {
                    for cb in pending { cb(resultURL) }
                }
            }
        }
    }

    /// 抽出済み M4A ファイルでピッチエンジンをセットアップする
    private func setupPitchEngine(for audioURL: URL) {
        stopPitchEngine()

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)

            let file = try AVAudioFile(forReading: audioURL)
            print("[PITCH] Audio file opened: format=\(file.processingFormat), length=\(file.length)")

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let timePitch = AVAudioUnitTimePitch()
            timePitch.pitch = pitchCents
            timePitch.rate = 1.0

            engine.attach(player)
            engine.attach(timePitch)
            engine.connect(player, to: timePitch, format: file.processingFormat)
            engine.connect(timePitch, to: engine.mainMixerNode, format: file.processingFormat)

            try engine.start()
            print("[PITCH] Engine started successfully")

            self.audioEngine = engine
            self.playerNode = player
            self.timePitchNode = timePitch
            self.audioFile = file
        } catch {
            print("[PITCH] Engine setup failed: \(error)")
        }
    }

    /// ピッチエンジンを停止・破棄する
    func stopPitchEngine() {
        playerNode?.stop()
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil
        timePitchNode = nil
        audioFile = nil
        pitchEngineDevice = ""
    }

    /// 抽出済み一時ファイルを削除する
    func cleanupExtractedAudio() {
        for (_, url) in extractedAudioByDevice {
            try? FileManager.default.removeItem(at: url)
        }
        extractedAudioByDevice.removeAll()
    }

    /// ピッチエンジンで指定秒から再生を開始する（audioURL は抽出済み M4A）
    func pitchEnginePlay(from seconds: Double, audioURL: URL, device: String) {
        guard pitchCents != 0 else { return }

        if pitchEngineDevice != device || audioEngine == nil {
            setupPitchEngine(for: audioURL)
            pitchEngineDevice = device
        }
        guard let file = audioFile, let player = playerNode else {
            print("[PITCH] pitchEnginePlay: file or player is nil — setup likely failed")
            return
        }

        player.stop()
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(seconds * sampleRate)
        let totalFrames = file.length
        guard startFrame >= 0, startFrame < totalFrames else {
            print("[PITCH] pitchEnginePlay: startFrame=\(startFrame) out of range (total=\(totalFrames))")
            return
        }
        let frameCount = AVAudioFrameCount(totalFrames - startFrame)
        guard frameCount > 0 else { return }

        player.scheduleSegment(file, startingFrame: startFrame, frameCount: frameCount, at: nil)
        player.play()
        print("[PITCH] Playing from \(seconds)s (frame \(startFrame)), \(frameCount) frames, pitch=\(pitchCents) cents")
    }

    /// ピッチエンジンの再生を一時停止する
    func pitchEnginePause() {
        playerNode?.stop()
    }

    // MARK: - Audio Source Sync

    /// 音声ソースデバイスのプレイヤーを playheadTime に同期する
    /// - 再生中: ずれが大きい時だけシーク、それ以外は自然再生に任せる
    /// - 停止中: シーク位置を合わせるだけ
    func syncAudioSource(playheadTime: Double) {
        guard let srcDevice = audioSourceDevice,
              let player = players[srcDevice],
              let videoStart = videoStartByDevice[srcDevice] else { return }

        // 音声ソースの録画内時刻を算出（編集タイムライン位置 → ソースファイル内位置）
        let srcTime = playheadTime - videoStart
        guard srcTime >= 0 else {
            player.pause()
            return
        }

        let current = CMTimeGetSeconds(player.currentTime())
        let drift = abs(current - srcTime)

        if isPlaying {
            // 再生中: 0.5秒以上ずれたらシーク（頻繁なシークは音声が途切れる原因）
            if drift > 0.5 {
                let target = CMTimeMakeWithSeconds(srcTime, preferredTimescale: 600)
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] finished in
                    if finished { self?.playAtRate(player) }
                }
            } else if player.rate == 0 {
                // 一時停止されていたら再開（セグメント切替で pause された場合の復帰）
                playAtRate(player)
            }
        } else {
            // 停止中: 位置だけ合わせる
            if drift > 0.05 {
                let target = CMTimeMakeWithSeconds(srcTime, preferredTimescale: 600)
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            if player.rate != 0 { player.pause() }
        }
    }

    /// 音声ソースデバイスの再生を開始する（togglePlayback 時に呼ぶ）
    func startAudioSource(playheadTime: Double) {
        guard let srcDevice = audioSourceDevice,
              srcDevice != activePreviewDevice,
              let player = players[srcDevice],
              let videoStart = videoStartByDevice[srcDevice] else { return }
        let srcTime = playheadTime - videoStart
        guard srcTime >= 0 else { return }
        let target = CMTimeMakeWithSeconds(srcTime, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] finished in
            if finished { self?.playAtRate(player) }
        }
    }

    /// 音声ソースデバイスのプレイヤーを停止する
    func pauseAudioSource() {
        guard let srcDevice = audioSourceDevice,
              let player = players[srcDevice] else { return }
        player.pause()
    }

    // MARK: - Video Filter (Metal Preview)

    /// フィルタパラメータを更新する（Metal レンダラーが次フレームで自動反映）
    func applyVideoFilter(filterName: String?, kaleidoscopeType: String?, kaleidoscopeSize: Float, centerX: Float = 0.5, centerY: Float = 0.5, tileHeight: Float = 200, mirrorDirection: Int = 0, rotationAngle: Float = 0) {
        filterParamsHolder.update(
            videoFilter: filterName,
            kaleidoscopeType: kaleidoscopeType,
            kaleidoscopeSize: kaleidoscopeSize,
            centerX: centerX,
            centerY: centerY,
            tileHeight: tileHeight,
            mirrorDirection: mirrorDirection,
            rotationAngle: rotationAngle
        )
        // 一時停止中は Metal レンダラーに強制再描画を要求
        if !isPlaying {
            metalRenderer.requestRender()
        }
    }

    /// セグメント切り替え時にそのセグメントのフィルタ・速度を適用する
    /// - 辞書にセグメント固有設定があればそれを使い、なければグローバルフォールバック
    /// - 同じセグメントが既に適用済みならスキップ（force=true でスキップ無効化）
    func applyFilterForSegment(segmentID: UUID, device: String, force: Bool = false) {
        // 同一セグメントなら再適用不要（force の場合は常に適用）
        if !force {
            guard segmentID != lastAppliedFilterSegID else { return }
        }
        lastAppliedFilterSegID = segmentID

        let settings = segmentFilterSettings[segmentID] ?? globalFilterSettings

        // セグメント固有の速度があればそれを使用、なければグローバル
        let segSpeed = settings.speedRate
        if segSpeed != 1.0 {
            playbackRate = segSpeed
        } else {
            // グローバル設定に戻す（globalFilterSettings.speedRate を使う）
            playbackRate = globalFilterSettings.speedRate
        }
        // 再生中のプレイヤーに即座に反映
        if isPlaying, let player = players[device], player.rate != 0 {
            player.rate = playbackRate
        }

        // filterParamsHolder を更新（Metal レンダラーが次フレームで自動読取）
        filterParamsHolder.update(
            videoFilter: settings.videoFilter,
            kaleidoscopeType: settings.kaleidoscopeType,
            kaleidoscopeSize: settings.kaleidoscopeSize,
            centerX: settings.kaleidoscopeCenterX,
            centerY: settings.kaleidoscopeCenterY,
            tileHeight: settings.tileHeight,
            mirrorDirection: settings.mirrorDirection,
            rotationAngle: settings.rotationAngle
        )
    }

    /// フィルタ設定変更時に呼ぶ（lastAppliedFilterSegID をリセットして再適用を強制）
    func invalidateFilterCache() {
        lastAppliedFilterSegID = nil
        filterGeneration += 1
    }

    /// CIFilter 適用ヘルパー（プレビュー・エクスポート共通）
    /// centerX/centerY は 0.0〜1.0 の正規化値（0.5 = 映像中央）
    nonisolated static func applyFilters(to image: CIImage, videoFilter: String?, kaleidoscopeType: String?, kaleidoscopeSize: Float, centerX: Float = 0.5, centerY: Float = 0.5, tileHeight: Float = 200, mirrorDirection: Int = 0, rotationAngle: Float = 0) -> CIImage {
        var result = image
        let extent = image.extent

        // 通常フィルタ
        if let filterName = videoFilter {
            switch filterName {

            // ── 超ビビッド: 彩度+コントラストを大幅に強調 ──
            case "custom_vivid":
                if let satFilter = CIFilter(name: "CIColorControls") {
                    satFilter.setValue(result, forKey: kCIInputImageKey)
                    satFilter.setValue(2.0, forKey: "inputSaturation")  // 彩度2倍
                    satFilter.setValue(0.15, forKey: "inputContrast")    // コントラスト強化
                    satFilter.setValue(0.02, forKey: "inputBrightness")
                    if let out = satFilter.outputImage {
                        result = out.cropped(to: extent)
                    }
                }

            // ── 漫画風: エッジ検出 + ポスタライズの組み合わせ ──
            case "custom_comic":
                // ステップ1: ポスタライズで色数を減らす
                if let poster = CIFilter(name: "CIColorPosterize") {
                    poster.setValue(result, forKey: kCIInputImageKey)
                    poster.setValue(6.0, forKey: "inputLevels")
                    if let out = poster.outputImage {
                        result = out.cropped(to: extent)
                    }
                }
                // ステップ2: エッジ検出でアウトラインを生成
                let originalForEdge = result
                if let edges = CIFilter(name: "CIEdges") {
                    edges.setValue(originalForEdge, forKey: kCIInputImageKey)
                    edges.setValue(5.0, forKey: "inputIntensity")
                    if let edgeOut = edges.outputImage {
                        // ステップ3: エッジを反転して黒い線にする
                        if let invert = CIFilter(name: "CIColorInvert") {
                            invert.setValue(edgeOut.cropped(to: extent), forKey: kCIInputImageKey)
                            if let inverted = invert.outputImage {
                                // ステップ4: 乗算合成でポスタライズ画像の上に黒い線を重ねる
                                if let blend = CIFilter(name: "CIMultiplyBlendMode") {
                                    blend.setValue(result, forKey: kCIInputImageKey)
                                    blend.setValue(inverted.cropped(to: extent), forKey: "inputBackgroundImage")
                                    if let out = blend.outputImage {
                                        result = out.cropped(to: extent)
                                    }
                                }
                            }
                        }
                    }
                }

            // ── ポスタライズ: 色数を減らしてポップアート風に ──
            case "custom_posterize":
                if let poster = CIFilter(name: "CIColorPosterize") {
                    poster.setValue(result, forKey: kCIInputImageKey)
                    poster.setValue(4.0, forKey: "inputLevels")
                    if let out = poster.outputImage {
                        result = out.cropped(to: extent)
                    }
                }

            // ── Bloom: 光がにじむ効果 ──
            case "CIBloom":
                if let bloom = CIFilter(name: "CIBloom") {
                    bloom.setValue(result, forKey: kCIInputImageKey)
                    bloom.setValue(10.0, forKey: "inputRadius")
                    bloom.setValue(1.0, forKey: "inputIntensity")
                    if let out = bloom.outputImage {
                        result = out.cropped(to: extent)
                    }
                }

            // ── サーマル: 赤外線カメラ風の疑似カラー ──
            case "CIFalseColor":
                if let fc = CIFilter(name: "CIFalseColor") {
                    fc.setValue(result, forKey: kCIInputImageKey)
                    fc.setValue(CIColor(red: 0.0, green: 0.0, blue: 0.5), forKey: "inputColor0")
                    fc.setValue(CIColor(red: 1.0, green: 0.8, blue: 0.0), forKey: "inputColor1")
                    if let out = fc.outputImage {
                        result = out.cropped(to: extent)
                    }
                }

            // ── 標準 CIFilter（パラメータ不要なもの）──
            default:
                if let ciFilter = CIFilter(name: filterName) {
                    ciFilter.setValue(result, forKey: kCIInputImageKey)
                    if let filtered = ciFilter.outputImage {
                        result = filtered.cropped(to: extent)
                    }
                }
            }
        }

        // 万華鏡フィルタ
        if let kType = kaleidoscopeType {
            // 正規化値からピクセル座標に変換（CIImage の Y 軸は下から上）
            let cx = extent.origin.x + extent.width * CGFloat(centerX)
            let cy = extent.origin.y + extent.height * CGFloat(centerY)
            let center = CIVector(x: cx, y: cy)
            switch kType {
            case "CITriangleKaleidoscope":
                if let kf = CIFilter(name: "CITriangleKaleidoscope") {
                    kf.setValue(result, forKey: kCIInputImageKey)
                    kf.setValue(center, forKey: "inputPoint")
                    kf.setValue(kaleidoscopeSize, forKey: "inputSize")
                    kf.setValue(rotationAngle, forKey: "inputRotation")
                    kf.setValue(1.4, forKey: "inputDecay")
                    if let out = kf.outputImage {
                        result = out.cropped(to: extent)
                    }
                }
            case "CIKaleidoscope":
                if let kf = CIFilter(name: "CIKaleidoscope") {
                    kf.setValue(result, forKey: kCIInputImageKey)
                    kf.setValue(center, forKey: "inputCenter")
                    kf.setValue(6, forKey: "inputCount")
                    kf.setValue(rotationAngle, forKey: "inputAngle")
                    if let out = kf.outputImage {
                        result = out.cropped(to: extent)
                    }
                }
            case "CIFourfoldReflectedTile":
                // パターン塗りつぶし: 中心の■領域をクロップしてタイル敷き
                let halfW = CGFloat(kaleidoscopeSize) / 2
                let halfH = CGFloat(tileHeight) / 2
                let cx = center.x
                let cy = center.y
                let cropRect = CGRect(
                    x: cx - halfW, y: cy - halfH,
                    width: CGFloat(kaleidoscopeSize), height: CGFloat(tileHeight)
                )
                let cropped = result.cropped(to: cropRect)
                // 原点(0,0)に移動してからタイリング（原点ズレによるタイル不整合を防止）
                let translated = cropped.transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
                if let tileFilt = CIFilter(name: "CIAffineTile") {
                    tileFilt.setValue(translated, forKey: kCIInputImageKey)
                    tileFilt.setValue(NSValue(cgAffineTransform: .identity), forKey: "inputTransform")
                    if let out = tileFilt.outputImage {
                        result = out.cropped(to: extent)
                    }
                }
            case "CISixfoldReflectedTile":
                if let kf = CIFilter(name: "CISixfoldReflectedTile") {
                    kf.setValue(result, forKey: kCIInputImageKey)
                    kf.setValue(center, forKey: "inputCenter")
                    kf.setValue(kaleidoscopeSize, forKey: "inputWidth")
                    kf.setValue(rotationAngle, forKey: "inputAngle")
                    if let out = kf.outputImage {
                        result = out.cropped(to: extent)
                    }
                }
            case "CIEightfoldReflectedTile":
                if let kf = CIFilter(name: "CIEightfoldReflectedTile") {
                    kf.setValue(result, forKey: kCIInputImageKey)
                    kf.setValue(center, forKey: "inputCenter")
                    kf.setValue(kaleidoscopeSize, forKey: "inputWidth")
                    kf.setValue(rotationAngle, forKey: "inputAngle")
                    if let out = kf.outputImage {
                        result = out.cropped(to: extent)
                    }
                }

            case "custom_mirror":
                // ミラー反転: 保持側を鏡面的に繰り返して画面全体を埋める
                // 保持側 + その反転コピーを1ペアとし、CIAffineTile で水平に繰り返す
                let splitX = extent.origin.x + extent.width * CGFloat(centerX)
                let ox = extent.origin.x
                let oy = extent.origin.y
                let eh = extent.height

                if mirrorDirection == 0 {
                    // L: 左側を保持 → 左半分を鏡面反転して右側を繰り返し埋める
                    let keepW = splitX - ox
                    guard keepW > 1 else { break }
                    let keepHalf = result.cropped(to: CGRect(x: ox, y: oy, width: keepW, height: eh))
                    // 原点に正規化: (0, 0, keepW, eh)
                    let norm = keepHalf.transformed(by: CGAffineTransform(translationX: -ox, y: -oy))
                    // 反転コピーを右に配置: (keepW, 0, keepW, eh)
                    let flippedCopy = norm
                        .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                        .transformed(by: CGAffineTransform(translationX: keepW * 2, y: 0))
                    // 元 + 反転 = 1ペア (0, 0, keepW*2, eh)
                    let pair = norm.composited(over: flippedCopy)
                    // CIAffineTile で1ペアをそのまま繰り返し
                    if let tile = CIFilter(name: "CIAffineTile") {
                        tile.setValue(pair, forKey: kCIInputImageKey)
                        tile.setValue(NSValue(cgAffineTransform: .identity), forKey: "inputTransform")
                        if let tiled = tile.outputImage {
                            result = tiled
                                .transformed(by: CGAffineTransform(translationX: ox, y: oy))
                                .cropped(to: extent)
                        }
                    }
                } else {
                    // R: 右側を保持 → 右半分を鏡面反転して左側を繰り返し埋める
                    let keepW = extent.maxX - splitX
                    guard keepW > 1 else { break }
                    let keepHalf = result.cropped(to: CGRect(x: splitX, y: oy, width: keepW, height: eh))
                    // 原点に正規化: (0, 0, keepW, eh)
                    let norm = keepHalf.transformed(by: CGAffineTransform(translationX: -splitX, y: -oy))
                    // 反転コピーを左に配置: (-keepW, 0, keepW, eh)
                    let flippedCopy = norm
                        .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                    // 反転 + 元 = 1ペア (-keepW, 0, keepW*2, eh)
                    let pair = norm.composited(over: flippedCopy)
                    // CIAffineTile で1ペアをそのまま繰り返し
                    if let tile = CIFilter(name: "CIAffineTile") {
                        tile.setValue(pair, forKey: kCIInputImageKey)
                        tile.setValue(NSValue(cgAffineTransform: .identity), forKey: "inputTransform")
                        if let tiled = tile.outputImage {
                            result = tiled
                                .transformed(by: CGAffineTransform(translationX: splitX, y: oy))
                                .cropped(to: extent)
                        }
                    }
                }

            case "custom_prism":
                // 魔法プリズム効果: 中心◯はクリアな元映像、外側は万華鏡＋ぼかし
                let original = result
                let r = CGFloat(kaleidoscopeSize)

                // ① 万華鏡を適用（外側用）
                var kaleidoResult = result
                if let kf = CIFilter(name: "CIKaleidoscope") {
                    kf.setValue(result, forKey: kCIInputImageKey)
                    kf.setValue(center, forKey: "inputCenter")
                    kf.setValue(8, forKey: "inputCount")
                    kf.setValue(rotationAngle, forKey: "inputAngle")
                    if let out = kf.outputImage {
                        kaleidoResult = out.cropped(to: extent)
                    }
                }

                // ② 万華鏡結果にガウシアンブラーをかける
                if let blur = CIFilter(name: "CIGaussianBlur") {
                    blur.setValue(kaleidoResult, forKey: kCIInputImageKey)
                    blur.setValue(8.0, forKey: "inputRadius")
                    if let out = blur.outputImage {
                        kaleidoResult = out.cropped(to: extent)
                    }
                }

                // ③ RadialGradient マスク: CIBlendWithMask は輝度で判定
                // 白(1,1,1)=前景(万華鏡)、黒(0,0,0)=背景(元映像)
                // → 中心を黒、外側を白にする
                if let radialGrad = CIFilter(name: "CIRadialGradient") {
                    radialGrad.setValue(center, forKey: "inputCenter")
                    radialGrad.setValue(r * 0.4, forKey: "inputRadius0")  // クリア領域の半径
                    radialGrad.setValue(r * 0.8, forKey: "inputRadius1")  // フェード完了の半径
                    radialGrad.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 1), forKey: "inputColor0")  // 中心=黒(元映像)
                    radialGrad.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor1")  // 外側=白(万華鏡)
                    if let mask = radialGrad.outputImage?.cropped(to: extent) {
                        // ④ マスクを使って元映像と万華鏡をブレンド
                        if let blend = CIFilter(name: "CIBlendWithMask") {
                            blend.setValue(kaleidoResult, forKey: kCIInputImageKey)       // マスク不透明部分 → 万華鏡
                            blend.setValue(original, forKey: "inputBackgroundImage")       // マスク透明部分 → 元映像
                            blend.setValue(mask, forKey: "inputMaskImage")
                            if let out = blend.outputImage {
                                result = out.cropped(to: extent)
                            }
                        }
                    }
                }

            default:
                break
            }
        }

        return result
    }

    /// 全プレイヤーを pause する（音声ソースデバイスは除外）
    private func pauseAllPlayers() {
        for (device, player) in players {
            if device == audioSourceDevice { continue }
            player.pause()
        }
    }

    /// 指定プレイヤーを pause する（音声ソースデバイスならスキップ）
    private func pausePlayer(for device: String) {
        guard !device.isEmpty else { return }
        if device == audioSourceDevice { return }
        players[device]?.pause()
    }

    // MARK: - Seek

    /// プレイヘッドを指定秒にシークし、対応デバイスのプレイヤーを合わせる。
    /// セグメントが存在しない区間では全プレイヤーを停止し黒画面を表示する。
    func seekPreview(to seconds: Double, timeline: ExclusiveEditTimeline, selectedDevice: String) {
        guard timeline.totalDuration > 0 else { return }
        // セグメントに当たるデバイスを探す
        if let device = timeline.activeDevice(at: seconds),
           let seg = timeline.segments(for: device)
            .filter({ $0.isValid })
            .first(where: { $0.trimIn <= seconds && seconds < $0.trimOut }) {
            let srcTime = seg.sourceInTime + (seconds - seg.trimIn)
            // 前のデバイスを止めて切り替え
            if activePreviewDevice != device {
                pausePlayer(for: activePreviewDevice)
                activePreviewDevice = device
            }

            // セグメントに合わせたフィルタ適用
            applyFilterForSegment(segmentID: seg.id, device: device)

            let target = CMTimeMakeWithSeconds(srcTime, preferredTimescale: 600)
            let useTolerant = isTrimming
            let tolerance = CMTimeMakeWithSeconds(useTolerant ? 0.15 : 0, preferredTimescale: 600)
            players[device]?.seek(
                to: target,
                toleranceBefore: tolerance,
                toleranceAfter: tolerance
            )
        } else {
            // セグメント外 → 全プレイヤー停止・黒画面（音声ソースは継続）
            pauseAllPlayers()
            // 選択デバイスの直近セグメントへ仮シーク（表示位置合わせのため）
            let segs = timeline.segments(for: selectedDevice)
                .filter { $0.isValid }
                .sorted { $0.trimIn < $1.trimIn }
            if let nearest = segs.min(by: {
                min(abs($0.trimIn - seconds), abs($0.trimOut - seconds)) <
                min(abs($1.trimIn - seconds), abs($1.trimOut - seconds))
            }) {
                let srcTime = abs(nearest.trimIn - seconds) < abs(nearest.trimOut - seconds)
                    ? nearest.sourceInTime : nearest.sourceOutTime
                players[selectedDevice]?.seek(
                    to: CMTimeMakeWithSeconds(srcTime, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero
                )
            }
            activePreviewDevice = ""
        }
    }

    /// トリム中のスロットル付きシーク（50ms間隔で間引く）
    func throttledSeekForTrim(to seconds: Double, timeline: ExclusiveEditTimeline, selectedDevice: String) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastTrimSeekTime >= 0.05 else { return }
        lastTrimSeekTime = now
        seekPreview(to: seconds, timeline: timeline, selectedDevice: selectedDevice)
    }

    func seekToSegment(device: String, seg: ClipSegment) {
        // 前のデバイスのプレイヤーを止める
        if !activePreviewDevice.isEmpty && activePreviewDevice != device {
            pausePlayer(for: activePreviewDevice)
        }
        activePreviewDevice = device
        playheadTime = seg.trimIn
        blackUntil = 0

        // セグメント切り替え時にフィルタを適用
        applyFilterForSegment(segmentID: seg.id, device: device)

        let player = players[device]

        // 音声ソースデバイスの場合はシークせず継続再生（音声を途切れさせない）
        if device == audioSourceDevice {
            preloadedNext = nil
            isSeeking = false
            if isPlaying, player?.rate == 0 { playAtRate(player) }
            return
        }

        // 事前seekが完了していれば、seekをスキップして即再生
        if let preloaded = preloadedNext,
           preloaded.device == device,
           preloaded.segID == seg.id {
            preloadedNext = nil
            isSeeking = false
            if isPlaying { playAtRate(player) }
            return
        }
        preloadedNext = nil

        isSeeking = true
        seekGeneration += 1
        let generation = seekGeneration

        let twoFrames = CMTimeMakeWithSeconds(2.0 / 30.0, preferredTimescale: 600)
        player?.seek(
            to: CMTimeMakeWithSeconds(seg.sourceInTime, preferredTimescale: 600),
            toleranceBefore: twoFrames, toleranceAfter: .zero
        ) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor [weak self] in
                guard let self, self.seekGeneration == generation else { return }
                self.isSeeking = false
                if self.isPlaying { self.playAtRate(player) }
            }
        }
    }

    /// 再生を止めて先頭セグメントに静かに戻す（play しない）。
    /// 全セグメント終了後の巻き戻し専用。
    private func resetToStart(firstSeg: (device: String, seg: ClipSegment)?) {
        // まず全フラグを停止状態に
        isPlaying = false
        blackUntil = 0
        stopTimer()
        pauseAllPlayers()
        pauseAudioSource()  // 音声ソースも停止（巻き戻し時は全停止）
        pitchEnginePause()  // ピッチエンジンも停止
        // seekGeneration を上げて残留コールバックを無効化
        seekGeneration += 1
        let generation = seekGeneration
        isSeeking = true   // シーク完了まで tick をブロック

        guard let first = firstSeg else {
            isSeeking = false
            activePreviewDevice = ""
            playheadTime = 0
            return
        }
        activePreviewDevice = first.device
        playheadTime = first.seg.trimIn
        let player = players[first.device]
        player?.seek(
            to: CMTimeMakeWithSeconds(first.seg.sourceInTime, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.seekGeneration == generation else { return }
                self.isSeeking = false
                // isPlaying は false なので play() しない
            }
        }
    }

    /// 黒画面区間に入る：全プレイヤーを止め、until 秒まで時刻を進めながら黒画面を維持する
    private func enterBlackRegion(from: Double, until: Double) {
        pauseAllPlayers()
        activePreviewDevice = ""
        blackUntil = until
        isSeeking = false
    }

    // MARK: - Playback

    /// 先頭セグメントの開始位置にジャンプする（再生中なら停止する）
    func jumpToStart(allSegments: [(device: String, seg: ClipSegment)]) {
        guard let first = allSegments.first else { return }
        if isPlaying {
            isPlaying = false
            pauseAllPlayers()
            pauseAudioSource()
            pitchEnginePause()
            stopTimer()
        }
        seekGeneration += 1
        let generation = seekGeneration
        isSeeking = true
        blackUntil = 0
        activePreviewDevice = first.device
        playheadTime = first.seg.trimIn
        players[activePreviewDevice]?.seek(
            to: CMTimeMakeWithSeconds(first.seg.sourceInTime, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.seekGeneration == generation else { return }
                self.isSeeking = false
            }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 末尾セグメントの終了位置にジャンプする（再生中なら停止する）
    func jumpToEnd(allSegments: [(device: String, seg: ClipSegment)], totalDuration: Double) {
        guard let last = allSegments.last else { return }
        if isPlaying {
            isPlaying = false
            pauseAllPlayers()
            pauseAudioSource()
            pitchEnginePause()
            stopTimer()
        }
        // 末尾セグメントの1フレーム手前にシーク（trimOut ぴったりだと範囲外扱いになるため）
        let frameTime = 1.0 / 30.0
        let targetTimeline = max(last.seg.trimIn, last.seg.trimOut - frameTime)
        let targetSource  = last.seg.sourceInTime + (targetTimeline - last.seg.trimIn)

        seekGeneration += 1
        let generation = seekGeneration
        isSeeking = true
        blackUntil = 0
        activePreviewDevice = last.device
        playheadTime = targetTimeline
        players[activePreviewDevice]?.seek(
            to: CMTimeMakeWithSeconds(targetSource, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.seekGeneration == generation else { return }
                self.isSeeking = false
            }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func togglePlayback(
        allSegments: [(device: String, seg: ClipSegment)],
        totalDuration: Double
    ) {
        if isPlaying {
            isPlaying = false
            isSeeking = false
            seekGeneration += 1          // 進行中のシークコールバックを無効化
            preloadedNext = nil
            pauseAllPlayers()
            pauseAudioSource()
            pitchEnginePause()
            stopTimer()
        } else {
            guard totalDuration > 0 else { return }
            isPlaying = true
            self.totalDuration = totalDuration
            let pt = playheadTime

            if let current = allSegments.first(where: { $0.seg.trimIn <= pt && pt < $0.seg.trimOut }) {
                // プレイヘッドがセグメント内 → 現在位置から再生
                if activePreviewDevice != current.device {
                    pausePlayer(for: activePreviewDevice)
                    activePreviewDevice = current.device
                }
                let srcTime = current.seg.sourceInTime + (pt - current.seg.trimIn)
                let player = players[current.device]
                isSeeking = true
                blackUntil = 0
                seekGeneration += 1
                let generation = seekGeneration
                // 再生開始シークも toleranceBefore に余裕を持たせて高速化する
                let twoFrames = CMTimeMakeWithSeconds(2.0 / 30.0, preferredTimescale: 600)
                player?.seek(
                    to: CMTimeMakeWithSeconds(srcTime, preferredTimescale: 600),
                    toleranceBefore: twoFrames, toleranceAfter: .zero
                ) { [weak self] finished in
                    guard finished else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.seekGeneration == generation else { return }
                        self.isSeeking = false
                        if self.isPlaying { self.playAtRate(player) }
                    }
                }
            } else if let next = allSegments.first(where: { $0.seg.trimIn >= pt }) {
                // セグメント外 かつ 後ろにセグメントあり → 黒画面区間を経由
                enterBlackRegion(from: pt, until: next.seg.trimIn)
            } else if let first = allSegments.first {
                // 全セグメントより後ろ → 先頭から
                seekToSegment(device: first.device, seg: first.seg)
            } else {
                isPlaying = false
                return
            }
            startTimer()
        }
    }

    // MARK: - Timer（30fps パルス）

    /// 毎フレーム呼ばれる再生状態の更新。View の onChange(timerTick) から呼ぶ。
    func tick(allSegments: [(device: String, seg: ClipSegment)], totalDuration: Double) {
        guard isPlaying, !isSeeking else { return }
        self.totalDuration = totalDuration
        let first = allSegments.first

        // ── 黒画面区間の処理 ──────────────────────────────────
        if activePreviewDevice.isEmpty {
            let dt = 1.0 / 30.0
            let nextTime = playheadTime + dt

            // 全区間終了チェック
            if nextTime >= totalDuration {
                resetToStart(firstSeg: first)
                return
            }

            // 次のセグメント開始に到達したか（1フレーム先読みで取りこぼし防止）
            if let nextSeg = allSegments.first(where: {
                $0.seg.trimIn > playheadTime && $0.seg.trimIn <= nextTime + dt
            }) {
                playheadTime = nextSeg.seg.trimIn
                blackUntil = 0
                seekToSegment(device: nextSeg.device, seg: nextSeg.seg)
                return
            }

            // まだ黒画面区間内 → 時刻だけ進める
            playheadTime = nextTime
            return
        }

        // ── 通常再生区間の処理 ────────────────────────────────
        guard let player = players[activePreviewDevice] else { return }

        // AVPlayer の currentTime をソースファイル内秒数として取得
        let now = CMTimeGetSeconds(player.currentTime())

        // 再生中のセグメントを特定
        guard let currentEntry = allSegments.first(where: {
            $0.device == activePreviewDevice &&
            now >= $0.seg.sourceInTime - 0.05 &&
            now < $0.seg.sourceOutTime
        }) else {
            // セグメントが見つからない → 次セグメントへ / 黒画面 / 終了
            #if DEBUG
            let deviceSegs = allSegments.filter { $0.device == activePreviewDevice }
            let ranges = deviceSegs.map { "[\($0.seg.sourceInTime)...\($0.seg.sourceOutTime)]" }.joined(separator: ", ")
            print("[TICK] No segment found: device=\(activePreviewDevice) now=\(now) playhead=\(playheadTime) segs=\(ranges)")
            #endif
            isSeeking = true
            if let next = allSegments.first(where: { $0.seg.trimIn > playheadTime }) {
                let gap = next.seg.trimIn - playheadTime
                if gap > 0.1 {
                    isSeeking = false
                    enterBlackRegion(from: playheadTime, until: next.seg.trimIn)
                } else {
                    seekToSegment(device: next.device, seg: next.seg)
                }
            } else if playheadTime < totalDuration - 0.1 {
                isSeeking = false
                enterBlackRegion(from: playheadTime, until: totalDuration)
            } else {
                resetToStart(firstSeg: first)
            }
            return
        }

        // プレイヘッドをタイムライン時間に変換（後退しない）
        let newPlayhead = currentEntry.seg.trimIn + (now - currentEntry.seg.sourceInTime)
        playheadTime = max(playheadTime - 0.1, newPlayhead)

        // 次セグメントへの事前seek（終端0.5秒前に発行）
        let preloadThreshold = 0.5
        let frameTime = 1.0 / 30.0
        if now >= currentEntry.seg.sourceOutTime - preloadThreshold,
           now < currentEntry.seg.sourceOutTime - frameTime,
           preloadedNext == nil {
            if let next = allSegments.first(where: { $0.seg.trimIn > currentEntry.seg.trimIn }),
               next.device != activePreviewDevice || next.seg.id != currentEntry.seg.id {
                // 音声ソースデバイスはシークしない（連続再生を途切れさせないため）
                if next.device == audioSourceDevice {
                    preloadedNext = (next.device, next.seg.id)
                } else {
                    let nextPlayer = players[next.device]
                    let twoFrames = CMTimeMakeWithSeconds(2.0 / 30.0, preferredTimescale: 600)
                    nextPlayer?.seek(
                        to: CMTimeMakeWithSeconds(next.seg.sourceInTime, preferredTimescale: 600),
                        toleranceBefore: twoFrames, toleranceAfter: .zero
                    ) { [weak self] finished in
                        guard finished else { return }
                        Task { @MainActor [weak self] in
                            self?.preloadedNext = (next.device, next.seg.id)
                        }
                    }
                }
            }
        }

        // セグメント終端判定（1フレーム手前で切り替え）
        guard now >= currentEntry.seg.sourceOutTime - frameTime else { return }

        // 終端処理：isSeeking を即セットして多重発火を防ぐ
        // 音声ソースデバイスのプレイヤーは止めない（音声を途切れさせないため）
        if activePreviewDevice != audioSourceDevice {
            player.pause()
        }
        isSeeking = true

        if let next = allSegments.first(where: { $0.seg.trimIn > currentEntry.seg.trimIn }) {
            let gap = next.seg.trimIn - currentEntry.seg.trimOut
            if gap > frameTime {
                isSeeking = false
                enterBlackRegion(from: currentEntry.seg.trimOut, until: next.seg.trimIn)
            } else {
                seekToSegment(device: next.device, seg: next.seg)
            }
        } else if currentEntry.seg.trimOut < totalDuration - frameTime {
            isSeeking = false
            enterBlackRegion(from: currentEntry.seg.trimOut, until: totalDuration)
        } else {
            // 全セグメント再生終了
            resetToStart(firstSeg: first)
        }
    }

    private func startTimer() {
        stopTimer()
        playheadTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.timerTick += 1
            }
        }
    }

    func stopTimer() {
        playheadTimer?.invalidate()
        playheadTimer = nil
    }

    /// Timer が発火するたびにインクリメント。View の onChange で tick() を呼ぶ。
    @Published var timerTick: Int = 0
}

// MARK: - PreviewView

struct PreviewView: View {
    let sessionID: String
    let videos: [String: URL]
    /// ライブラリから渡されるタイトル（nil = 直接起動時）
    var sessionTitle: String = "UNTITLED"
    /// タイトル変更をライブラリに通知するコールバック
    var onRename: ((String) -> Void)? = nil
    /// 編集状態の保存をライブラリに通知するコールバック
    var onSaveEditState: ((_ segments: [String: [ClipSegment]], _ lockedDevices: Set<String>, _ audioDevice: String?, _ videoFilter: String?, _ pitchCents: Float, _ kaleidoscope: String?, _ kaleidoscopeSize: Float, _ kaleidoscopeCenterX: Float, _ kaleidoscopeCenterY: Float, _ tileHeight: Float, _ playbackSpeed: Float, _ segmentFilterSettings: [UUID: SegmentFilterSettings]) -> Void)? = nil
    /// 保存済みの編集状態（起動時に復元に使う）
    var savedEditState: [String: [SegmentState]] = [:]
    /// 保存済みのロック状態（起動時に復元に使う）
    var savedLockedDevices: [String] = []
    /// 保存済みの音声デバイス（起動時に復元に使う）
    var savedAudioDevice: String? = nil
    /// 保存済みの映像フィルタ（起動時に復元に使う）
    var savedVideoFilter: String? = nil
    /// 保存済みのピッチシフト値
    var savedPitchCents: Float = 0
    /// 保存済みの万華鏡設定
    var savedKaleidoscope: String? = nil
    var savedKaleidoscopeSize: Float = 200
    var savedKaleidoscopeCenterX: Float = 0.5
    var savedKaleidoscopeCenterY: Float = 0.5
    /// 保存済みのTILE縦幅
    var savedTileHeight: Float = 200
    /// 保存済みの再生スピード
    var savedPlaybackSpeed: Float = 1.0
    /// セッション削除コールバック（nil = 削除ボタン非表示）
    var onDeleteSession: (() -> Void)? = nil
    /// 撮影時の向き設定（クロップ・エクスポートに使用）
    var desiredOrientation: VideoOrientation = .cinema

    @Environment(\.dismiss) private var dismiss

    @StateObject private var timeline = ExclusiveEditTimeline()
    @StateObject private var exportEngine = ExportEngine()
    @StateObject private var playback = PlaybackController()
    @ObservedObject private var purchaseManager = PurchaseManager.shared

    @State private var selectedDevice: String = ""
    /// デバイスごとの編集モード状態（長押しで true になる）
    @State private var editingDevices: Set<String> = []
    /// デバイスごとの「編集中セグメントID」（ハンドル表示対象：最後に操作した1つ）
    @State private var editingSegmentIDs: [String: UUID] = [:]
    /// 前回選択されていたデバイス（行き来確定に使う）
    @State private var previousSelectedDevice: String = ""
    @State private var thumbnails: [String: [UIImage]] = [:]
    @State private var previewAspectRatio: CGFloat = 16.0 / 9.0
    /// setupAll 完了フラグ（false の間はローディング表示）
    @State private var isReady: Bool = false

    @State private var timelineWidth: CGFloat = 1  // 後方互換のため残す（未使用）
    @State private var isPlayheadDragging: Bool = false
    @State private var showExportResult = false
    @State private var showExportError = false
    @State private var showDeleteSessionConfirm = false
    @State private var exportedURL: URL? = nil
    /// 表示中のタイトル（タップ編集）
    @State private var currentTitle: String = ""
    /// タイトル編集モード中フラグ
    @State private var isEditingTitle: Bool = false
    /// 編集中の一時テキスト
    @State private var titleDraft: String = ""
    /// TextField のフォーカス制御
    @FocusState private var titleFieldFocused: Bool

    // MARK: - Audio Source
    /// 音声ソース: nil = 編集に従う（カット毎に切替）、"デバイス名" = そのデバイスの音を常に使用
    @State private var audioSource: String? = nil
    /// 音声設定シート表示フラグ（SOURCE / PITCH 統合）
    @State private var showAudioSheet: Bool = false
    /// 音声設定シートのタブ（0=SOURCE, 1=PITCH）
    @State private var audioSheetTab: Int = 0

    // MARK: - Device Lock
    /// ロックパネル表示中のデバイス名（nil = 非表示）
    @State private var lockPopoverDevice: String? = nil

    // MARK: - Video Filter
    @State private var selectedFilter: String? = nil
    @State private var showFilterSheet: Bool = false
    @State private var filterSheetTab: Int = 0
    @State private var selectedKaleidoscope: String? = nil
    @State private var kaleidoscopeSize: Float = 200
    /// 万華鏡中心位置（0.0〜1.0 正規化、0.5 = 中央）
    @State private var kaleidoscopeCenterX: Float = 0.5
    @State private var kaleidoscopeCenterY: Float = 0.5
    /// TILEフィルタ用の縦幅（kaleidoscopeSize が横幅）
    @State private var tileHeight: Float = 200
    /// MIRROR用の反転方向（0=左を反転, 1=右を反転）
    @State private var mirrorDirection: Int = 0
    /// 回転角度（ラジアン）
    @State private var rotationAngle: Float = 0
    /// AUTO回転ON/OFF
    @State private var isAutoRotating: Bool = false
    /// AUTO回転速度（rad/sec）
    @State private var autoRotateSpeed: Float = 1.0
    /// セグメント単位のフィルタ設定
    @State private var segmentFilterSettings: [UUID: SegmentFilterSettings] = [:]
    /// フィルタ編集対象セグメント（nil = グローバル/ALL）
    @State private var filterEditingSegmentID: UUID? = nil

    // MARK: - Playback Speed
    /// 再生スピード倍率（1.0 = 通常）
    @State private var playbackSpeed: Float = 1.0

    /// スピードプリセット定義
    private static let speedPresets: [(label: String, icon: String, rate: Float)] = [
        ("0.25x  SUPER SLOW",  "tortoise.fill",          0.25),
        ("0.5x   SLOW",        "tortoise",               0.5),
        ("0.75x  SLOW",        "gauge.with.dots.needle.0percent", 0.75),
        ("1.0x   NORMAL",      "gauge.with.dots.needle.50percent", 1.0),
        ("1.25x  FAST",        "gauge.with.dots.needle.67percent", 1.25),
        ("1.5x   FAST",        "hare",                   1.5),
        ("2.0x   DOUBLE",      "hare.fill",              2.0),
        ("3.0x   TRIPLE",      "forward.fill",           3.0),
    ]

    /// フィルタ定義（表示名, CIFilter名 or nil）
    private static let videoFilters: [(label: String, icon: String, ciName: String?)] = [
        ("NONE",      "video",                    nil),
        ("MONO",      "circle.lefthalf.filled",   "CIPhotoEffectMono"),
        ("NOIR",      "circle.fill",              "CIPhotoEffectNoir"),
        ("CHROME",    "sparkles",                 "CIPhotoEffectChrome"),
        ("FADE",      "sun.haze",                 "CIPhotoEffectFade"),
        ("SEPIA",     "paintpalette",             "CISepiaTone"),
        ("VIVID",     "paintbrush.pointed.fill",  "custom_vivid"),
        ("INVERT",    "arrow.triangle.swap",      "CIColorInvert"),
        ("COMIC",     "book.fill",                "custom_comic"),
        ("THERMAL",   "thermometer.sun.fill",     "CIFalseColor"),
        ("POSTERIZE", "square.stack.3d.up.fill",  "custom_posterize"),
        ("BLOOM",     "light.max",                "CIBloom"),
        ("INSTANT",   "camera.fill",              "CIPhotoEffectInstant"),
        ("PROCESS",   "gearshape",                "CIPhotoEffectProcess"),
        ("TRANSFER",  "arrow.right.arrow.left",   "CIPhotoEffectTransfer"),
        ("TONAL",     "circle.bottomhalf.filled", "CIPhotoEffectTonal"),
    ]

    /// 万華鏡フィルタ定義（表示名, アイコン, CIFilter名 or nil）
    private static let kaleidoscopeFilters: [(label: String, icon: String, ciName: String?)] = [
        ("NONE",       "video",              nil),
        ("MIRROR",     "arrow.left.and.right.text.vertical", "custom_mirror"),
        ("PRISM",      "sparkles",           "custom_prism"),
        ("TRIANGLE",   "triangle",           "CITriangleKaleidoscope"),
        ("KALEIDOSCOPE","star.fill",         "CIKaleidoscope"),
        ("TILE",       "square.grid.2x2",    "CIFourfoldReflectedTile"),
        ("6-FOLD",     "hexagon.fill",       "CISixfoldReflectedTile"),
        ("8-FOLD",     "octagon.fill",       "CIEightfoldReflectedTile"),
    ]

    // MARK: - Pitch Shift
    /// ピッチシフト値（セント単位: 0 = 変更なし, 1200 = +1オクターブ, -1200 = -1オクターブ）
    @State private var pitchShiftCents: Float = 0
    

    /// ピッチプリセット定義（表示名, セント値）
    private static let pitchPresets: [(label: String, cents: Float)] = [
        ("+2 OCT",  +2400),
        ("+1 OCT",  +1200),
        ("+5 st",    +500),
        ("NORMAL",       0),
        ("−5 st",    -500),
        ("−1 OCT",  -1200),
        ("−2 OCT",  -2400),
    ]

    // MARK: - Timeline Zoom
    /// タイムラインのズーム倍率（1.0 = 全体表示、最大 8.0）
    @State private var zoomScale: CGFloat = 1.0
    /// ピンチ開始時の倍率スナップショット
    @State private var zoomScaleAtGestureStart: CGFloat = 1.0
    /// ScrollView レイアウトに反映済みのズーム倍率
    /// ピンチ中は更新せず、ピンチ終了時にまとめて反映（左上起点ジャンプ防止）
    @State private var committedZoomScale: CGFloat = 1.0
    /// ScrollView のスクロールオフセット（ズーム時に中心を保つ）
    @State private var scrollOffset: CGFloat = 0
    /// タイムライン表示領域の実幅（ズーム前・ラベル除く）
    @State private var baseTrackWidth: CGFloat = 1
    /// zoomBar のドラッグで要求されたスクロール先（anchorID + 毎回ユニークなシリアル）
    private struct ScrollRequest: Equatable {
        let anchorID: Int
        let serial: UInt64
    }
    @State private var zoomBarScrollRequest: ScrollRequest? = nil
    @State private var scrollRequestSerial: UInt64 = 0
    /// ScrollView のコンテンツオフセット（プレイヘッド端追従用）
    @State private var scrollContentOffset: CGFloat = 0

    /// タイムラインの ScrollViewProxy（ピンチジェスチャーから直接スクロール制御するため）
    @State private var timelineScrollProxy: ScrollViewProxy? = nil

    private var sortedDevices: [String] { videos.keys.sorted() }
    private var totalDuration: Double { timeline.totalDuration }

    #if DEBUG
    /// Canvas Preview 用のダミー動画URL生成
    static func dummyVideos(devices: [String]) -> [String: URL] {
        var result: [String: URL] = [:]
        for device in devices {
            // 存在しないURLだがDictが空でなければレイアウトは確認可能
            result[device] = URL(fileURLWithPath: "/dev/null")
        }
        return result
    }
    #endif

    // 全セグメントを trimIn 順に並べた再生リスト
    private func allSegmentsSorted() -> [(device: String, seg: ClipSegment)] {
        sortedDevices.flatMap { device in
            timeline.segments(for: device)
                .filter { $0.isValid }
                .map { (device: device, seg: $0) }
        }
        .sorted { $0.seg.trimIn < $1.seg.trimIn }
    }

    var body: some View {
        Group {
            if videos.isEmpty {
                emptyState
            } else {
                GeometryReader { geo in
                    // .ignoresSafeArea(.top) により geo.size.height = 画面全高
                    let _ = geo.size  // GeometryReader のサイズ取得を維持
                    let safeTop = windowSafeAreaTop

                    VStack(spacing: 0) {
                        // ステータスバー領域（背景黒 + 高さ確保）
                        Color.clear
                            .frame(height: safeTop)

                        headerBar
                            .frame(height: 44)

                        // プレビュー = 残りスペースを全て使う（下セクションは固有サイズ）
                        previewArea
                            .frame(maxHeight: .infinity)

                        // 下セクション: タイムライン + コントロール（固有サイズで詰める）
                        VStack(spacing: 0) {
                            timelineSection
                            playbackControls
                        }
                    }
                }
                .ignoresSafeArea(edges: .top)
            }
        }
        .overlay {
            if !isReady && !videos.isEmpty {
                ZStack {
                    Color.black.opacity(0.6)
                    DancingLoaderView(size: 80)
                }
                .ignoresSafeArea()
                .allowsHitTesting(true) // 下のUIへのタッチをブロック
            }
        }
        .background(Color.black.ignoresSafeArea())
        .overlay {
            // ピッチ音声準備中フルスクリーンオーバーレイ
            if playback.isExtractingAudio {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
                VStack(spacing: 16) {
                    DancingLoaderView(size: 100)
                    Text("Preparing audio...")
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.9))
                }
            }
        }
        .task {
            currentTitle = sessionTitle
            try? await Task.sleep(nanoseconds: 400_000_000)
            await setupAll()
        }
        .onDisappear {
            // 閉じる方法に関わらず編集状態を自動保存
            // （×ボタン、マスターからの強制クローズ等すべてのケース）
            onSaveEditState?(timeline.segmentsByDevice, timeline.lockedDevices, audioSource, selectedFilter, pitchShiftCents, selectedKaleidoscope, kaleidoscopeSize, kaleidoscopeCenterX, kaleidoscopeCenterY, tileHeight, playbackSpeed, segmentFilterSettings)
            playback.teardown()
            playback.cleanupExtractedAudio()
        }
        // タイトル編集：キーボードが上がっても入力欄が見えるよう専用シートで表示
        .sheet(isPresented: $isEditingTitle) {
            titleEditSheet
        }
        // デバイスロックパネル
        .sheet(isPresented: Binding(
            get: { lockPopoverDevice != nil },
            set: { if !$0 { lockPopoverDevice = nil } }
        )) {
            if let device = lockPopoverDevice {
                deviceLockSheet(device: device)
            }
        }
        // タイトル編集シート表示中はタイマーを止めて入力レスポンスを確保する
        .onChange(of: isEditingTitle) { editing in
            if editing {
                // シートを開くときは再生停止＋タイマー停止
                if playback.isPlaying {
                    playback.togglePlayback(allSegments: allSegmentsSorted(), totalDuration: totalDuration)
                }
                playback.stopTimer()
            } else {
                // シートを閉じても自動再生はしない（ユーザーが再度 Play を押す）
            }
        }
        // Timer パルスを受けて毎フレーム tick を実行（タイトル編集シート表示中はスキップ）
        .onChange(of: playback.timerTick) { _ in
            guard !isEditingTitle else { return }
            playback.tick(allSegments: allSegmentsSorted(), totalDuration: totalDuration)
            // 音声ソースデバイスを再生位置に同期（再生中・停止中ともに）
            playback.syncAudioSource(playheadTime: playback.playheadTime)
        }
        // デバイス切替時にピッチエンジンを再起動（「編集に従う」モードのみ）
        .onChange(of: playback.activePreviewDevice) { device in
            // Metal レンダラーはデバイス切替を自動検知するため追加処理不要
            guard pitchShiftCents != 0, audioSource == nil, playback.isPlaying, !device.isEmpty else { return }
            startPitchEngineIfNeeded()
        }
        .onChange(of: exportEngine.state) { state in
            if case .done(let url) = state {
                exportedURL = url
                showExportResult = true
            }
            if case .failed = state {
                showExportError = true
            }
        }
        .alert("Saved to Camera Roll", isPresented: $showExportResult) {
            Button("OK") {
                showExportResult = false
                exportedURL = nil
                exportEngine.state = .idle
            }
        }        .overlay {
            if case .exporting(let progress) = exportEngine.state {
                exportingOverlay(progress: progress)
            }
        }
        .alert("Export Failed", isPresented: $showExportError) {
            Button("OK") {
                showExportError = false
                exportEngine.state = .idle
            }
        } message: {
            if case .failed(let msg) = exportEngine.state { Text(msg) }
        }
        .alert("Delete this session?", isPresented: $showDeleteSessionConfirm) {
            Button("Delete", role: .destructive) {
                onDeleteSession?()
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: - Preview Area

    private var previewArea: some View {
        Color.black.overlay {
            GeometryReader { geo in
                let boxW = min(geo.size.height * previewAspectRatio, geo.size.width)
                let boxH = min(geo.size.width / previewAspectRatio,  geo.size.height)

                ZStack {
                    MetalPreviewView(renderer: playback.metalRenderer)
                        .frame(width: boxW, height: boxH)
                        .clipped()

                    // 万華鏡オーバーレイ（フィルタシート表示中 + 万華鏡選択時のみ）
                    if showFilterSheet, effectiveKaleidoscope != nil {
                        kaleidoscopeOverlay(boxSize: CGSize(width: boxW, height: boxH))
                    }

                    // リアルタイムフィルタステータス（右下）
                    filterStatusOverlay
                }
                .frame(width: boxW, height: boxH)
                .clipped()
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    // MARK: - Filter Status Overlay

    /// ciName → 表示用ラベルのルックアップ
    private func filterDisplayName(_ ciName: String?) -> String? {
        guard let ciName else { return nil }
        if let match = Self.videoFilters.first(where: { $0.ciName == ciName }) {
            return match.label
        }
        return nil
    }

    private func mirrorDisplayName(_ ciName: String?) -> String? {
        guard let ciName else { return nil }
        if let match = Self.kaleidoscopeFilters.first(where: { $0.ciName == ciName }) {
            return match.label
        }
        return nil
    }

    /// 再生ヘッド位置のセグメントに実際に適用されているフィルタ設定を返す
    private var playheadFilterSettings: SegmentFilterSettings {
        if let segID = currentPlayingSegmentID(),
           let settings = segmentFilterSettings[segID] {
            return settings
        }
        // セグメント固有設定がなければグローバル設定
        return SegmentFilterSettings(
            videoFilter: selectedFilter,
            kaleidoscopeType: selectedKaleidoscope,
            kaleidoscopeSize: kaleidoscopeSize,
            kaleidoscopeCenterX: kaleidoscopeCenterX,
            kaleidoscopeCenterY: kaleidoscopeCenterY,
            tileHeight: tileHeight,
            mirrorDirection: mirrorDirection,
            rotationAngle: rotationAngle,
            autoRotateSpeed: isAutoRotating ? autoRotateSpeed : 0,
            speedRate: playbackSpeed
        )
    }

    /// プレビュー右下のリアルタイムフィルタステータス表示
    @ViewBuilder
    private var filterStatusOverlay: some View {
        let s = playheadFilterSettings
        let hasFilter = s.videoFilter != nil
        let hasMirror = s.kaleidoscopeType != nil
        let hasSpeed = s.speedRate != 1.0
        let hasAutoRotate = s.autoRotateSpeed != 0

        if hasFilter || hasMirror || hasSpeed {
            VStack(alignment: .trailing, spacing: 1) {
                if let name = filterDisplayName(s.videoFilter) {
                    Text("FILTER:\(name)")
                }
                if let name = mirrorDisplayName(s.kaleidoscopeType) {
                    Text("MIRROR:\(name)")
                }
                if hasSpeed {
                    Text("SPEED:\(String(format: "%.2f", s.speedRate))x")
                }
            }
            .font(.system(size: 7, weight: .semibold, design: .monospaced))
            .foregroundColor(.white.opacity(0.6))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.35))
            .cornerRadius(3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(6)
            .allowsHitTesting(false)
        }
    }

    /// MIRRORフィルタの種類に応じたオーバーレイ形状
    private enum OverlayShape {
        case circle    // KALEIDOSCOPE, PRISM
        case tile      // TILE — グリッド表示
        case triangle  // TRIANGLE, 6-FOLD, 8-FOLD
        case mirror    // MIRROR — 中央の縦線
    }

    /// 現在のMIRRORフィルタに対応するオーバーレイ形状を返す
    private var currentOverlayShape: OverlayShape {
        switch effectiveKaleidoscope {
        case "CIFourfoldReflectedTile":
            return .tile
        case "custom_mirror":
            return .mirror
        case "CITriangleKaleidoscope", "CISixfoldReflectedTile", "CIEightfoldReflectedTile":
            return .triangle
        case "custom_prism", "CIKaleidoscope":
            return .circle
        default:
            return .circle
        }
    }

    /// 映像ピクセル座標の kaleidoscopeSize をスクリーン座標に変換する係数を計算
    /// MetalPreviewView は aspect-fill で映像を表示するため、
    /// 映像の短辺がbox全体にフィットし、長辺ははみ出してクリップされる
    private func videoToScreenScale(boxSize: CGSize) -> CGFloat {
        // 映像解像度を推定（アスペクト比から逆算）
        // 一般的な iPhone 映像は 1920x1080 (横) / 1080x1920 (縦)
        // resizeAspectFill: 映像がboxを完全に覆うようにスケール
        let videoW: CGFloat = 1920
        let videoH: CGFloat = 1080
        let scaleX = boxSize.width / videoW
        let scaleY = boxSize.height / videoH
        // AspectFill = 大きい方のスケールを採用
        return max(scaleX, scaleY)
    }

    /// MIRRORの中心とサイズを操作するオーバーレイ
    /// フィルタ種類に応じて形状が変わる: ◯ / グリッド / △
    /// - 1本指タップ/ドラッグ: 中心位置を変更
    /// - ピンチイン/アウト: サイズを変更
    private func kaleidoscopeOverlay(boxSize: CGSize) -> some View {
        let cx = CGFloat(effectiveCenterX) * boxSize.width
        let cy = CGFloat(1.0 - effectiveCenterY) * boxSize.height  // CIImage の Y 軸反転に対応
        let scale = videoToScreenScale(boxSize: boxSize)
        // kaleidoscopeSize は映像ピクセル単位 → スクリーン座標に変換
        let screenSize = CGFloat(effectiveKaleidoscopeSize) * scale
        let screenHeight = CGFloat(effectiveTileHeight) * scale  // TILE用の縦幅
        let radius = screenSize / 2
        let shape = currentOverlayShape

        return ZStack {
            // 背景: 1本指タップ/ドラッグで中心移動 + ピンチでサイズ変更
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let newX = Float(value.location.x / boxSize.width)
                            let newY = Float(1.0 - value.location.y / boxSize.height)
                            applyFilterChange(centerX: newX.clamped(to: 0...1), centerY: newY.clamped(to: 0...1))
                        }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { magnification in
                            if kaleidoscopePinchStartSize == nil {
                                kaleidoscopePinchStartSize = effectiveKaleidoscopeSize
                                kaleidoscopePinchStartTileH = effectiveTileHeight
                            }
                            let startSize = kaleidoscopePinchStartSize ?? effectiveKaleidoscopeSize
                            let mag = Float(magnification)
                            let newSize = (startSize * mag).clamped(to: 30...1000)
                            if shape == .tile {
                                let startH = kaleidoscopePinchStartTileH ?? effectiveTileHeight
                                let newH = (startH * mag).clamped(to: 30...1000)
                                applyFilterChange(kaleidoscopeSize: newSize, tileHeight: newH)
                            } else {
                                applyFilterChange(kaleidoscopeSize: newSize)
                            }
                        }
                        .onEnded { _ in
                            kaleidoscopePinchStartSize = nil
                            kaleidoscopePinchStartTileH = nil
                        }
                )
                .onTapGesture { location in
                    let newX = Float(location.x / boxSize.width)
                    let newY = Float(1.0 - location.y / boxSize.height)
                    applyFilterChange(centerX: newX.clamped(to: 0...1), centerY: newY.clamped(to: 0...1))
                }

            // 形状に応じた表示（ヒットテスト無効、表示のみ）
            switch shape {
            case .circle:
                Circle()
                    .stroke(Color.yellow, lineWidth: 2)
                    .frame(width: radius * 2, height: radius * 2)
                    .rotationEffect(.radians(Double(-(isAutoRotating ? playback.liveRotationAngle : effectiveRotationAngle))))
                    .position(x: cx, y: cy)
                    .allowsHitTesting(false)

            case .triangle:
                TriangleShape()
                    .stroke(Color.yellow, lineWidth: 2)
                    .frame(width: radius * 2, height: radius * 2 * 0.87)
                    .rotationEffect(.radians(Double(-(isAutoRotating ? playback.liveRotationAngle : effectiveRotationAngle))))
                    .position(x: cx, y: cy)
                    .allowsHitTesting(false)

            case .tile:
                tileGridOverlay(cx: cx, cy: cy, tileW: screenSize, tileH: screenHeight, boxSize: boxSize)
                    .allowsHitTesting(false)

            case .mirror:
                // 境界の縦線（centerX で位置を制御）
                let lineX = cx
                Path { path in
                    path.move(to: CGPoint(x: lineX, y: 0))
                    path.addLine(to: CGPoint(x: lineX, y: boxSize.height))
                }
                .stroke(Color.yellow, lineWidth: 0.5)
                .allowsHitTesting(false)

                // ドラッグで境界線を左右に移動
                Rectangle()
                    .fill(Color.yellow.opacity(0.01)) // 完全透明だとヒットテスト失敗する場合があるため微小不透明度
                    .frame(width: 44, height: boxSize.height)
                    .contentShape(Rectangle())
                    .position(x: lineX, y: boxSize.height / 2)
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let newX = Float(value.location.x / boxSize.width).clamped(to: 0.05...0.95)
                                applyFilterChange(centerX: newX)
                            }
                    )
            }

            // 中心のクロスヘア（MIRRORでは非表示）
            if shape != .mirror {
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 8, height: 8)
                    .position(x: cx, y: cy)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: boxSize.width, height: boxSize.height)
    }

    /// ピンチ開始時のサイズ保存用
    @State private var kaleidoscopePinchStartSize: Float? = nil
    @State private var kaleidoscopePinchStartTileH: Float? = nil

    /// TILE用: 中心の長方形から画面全体にグリッドを敷くオーバーレイ
    private func tileGridOverlay(cx: CGFloat, cy: CGFloat, tileW: CGFloat, tileH: CGFloat, boxSize: CGSize) -> some View {
        Canvas { context, size in
            guard tileW > 2, tileH > 2 else { return }

            let halfW = tileW / 2
            let halfH = tileH / 2

            // 中心から各方向にいくつタイルが必要か
            let tilesLeft = Int(ceil((cx + halfW) / tileW))
            let tilesUp = Int(ceil((cy + halfH) / tileH))
            let tilesRight = Int(ceil((size.width - cx + halfW) / tileW))
            let tilesDown = Int(ceil((size.height - cy + halfH) / tileH))

            // 薄いグリッド線を描画
            for col in -tilesLeft...tilesRight {
                for row in -tilesUp...tilesDown {
                    let tileX = cx + CGFloat(col) * tileW - halfW
                    let tileY = cy + CGFloat(row) * tileH - halfH
                    let rect = CGRect(x: tileX, y: tileY, width: tileW, height: tileH)
                    if rect.maxX >= 0 && rect.minX <= size.width &&
                       rect.maxY >= 0 && rect.minY <= size.height {
                        context.stroke(
                            Path(rect),
                            with: .color(.yellow.opacity(0.25)),
                            lineWidth: 0.5
                        )
                    }
                }
            }

            // 中心の長方形を強調表示
            let centerRect = CGRect(x: cx - halfW, y: cy - halfH,
                                    width: tileW, height: tileH)
            context.stroke(
                Path(centerRect),
                with: .color(.yellow),
                lineWidth: 2
            )
        }
    }

    /// 正三角形（重心が rect の中心に来る）
    private struct TriangleShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let w = rect.width
            let h = rect.height
            // 正三角形の重心 = 3頂点の平均 = (top + bottomL + bottomR) / 3
            // centroid.y = (topY + bottomY + bottomY) / 3 = midY
            // → topY = midY - 2h/3,  bottomY = midY + h/3
            let topY = rect.midY - h * 2 / 3
            let bottomY = rect.midY + h / 3
            path.move(to: CGPoint(x: rect.midX, y: topY))
            path.addLine(to: CGPoint(x: rect.midX + w / 2, y: bottomY))
            path.addLine(to: CGPoint(x: rect.midX - w / 2, y: bottomY))
            path.closeSubpath()
            return path
        }
    }

    /// 点から図形の辺までの最短距離を返す
    private func distanceToShapeEdge(point: CGPoint, center: CGPoint, radius: CGFloat, shape: OverlayShape) -> CGFloat {
        switch shape {
        case .circle:
            let dist = hypot(point.x - center.x, point.y - center.y)
            return abs(dist - radius)
        case .tile:
            // 長方形の辺までの距離
            // radius = 横幅の半分、縦幅は effectiveTileHeight / effectiveKaleidoscopeSize 比率で推定
            let aspectRatio = CGFloat(effectiveTileHeight / max(effectiveKaleidoscopeSize, 1))
            let halfW = radius
            let halfH = radius * aspectRatio
            let dx = abs(point.x - center.x)
            let dy = abs(point.y - center.y)
            let distToVertEdge = abs(dx - halfW)
            let distToHorzEdge = abs(dy - halfH)
            if dx <= halfW && dy <= halfH {
                return min(distToVertEdge, distToHorzEdge)
            } else if dx <= halfW {
                return distToHorzEdge
            } else if dy <= halfH {
                return distToVertEdge
            } else {
                return hypot(dx - halfW, dy - halfH)
            }
        case .triangle:
            // 三角形の辺までの距離（重心が center に来る正三角形）
            let triH = radius * 2 * 0.87  // 三角形の高さ（= frame height）
            let triW = radius             // 三角形の底辺の半幅（= frame width / 2）
            // 重心が center → topY = center.y - 2h/3, bottomY = center.y + h/3
            let topY = center.y - triH * 2 / 3
            let bottomY = center.y + triH / 3
            let top = CGPoint(x: center.x, y: topY)
            let bottomRight = CGPoint(x: center.x + triW, y: bottomY)
            let bottomLeft = CGPoint(x: center.x - triW, y: bottomY)
            let d1 = distanceToLineSegment(point: point, a: top, b: bottomRight)
            let d2 = distanceToLineSegment(point: point, a: bottomRight, b: bottomLeft)
            let d3 = distanceToLineSegment(point: point, a: bottomLeft, b: top)
            return min(d1, min(d2, d3))
        case .mirror:
            // MIRRORでは辺ドラッグ不要なので常に大きな値を返す
            return 1000
        }
    }

    /// 点から線分までの最短距離
    private func distanceToLineSegment(point: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lenSq))
        let projX = a.x + t * dx
        let projY = a.y + t * dy
        return hypot(point.x - projX, point.y - projY)
    }
    /// 表示すべきデバイス。
    /// - 再生中 → activePreviewDevice（再生エンジンが管理）
    /// - 停止中 → 再生ヘッド位置にセグメントがあるデバイス。なければ selectedDevice
    private var visibleDevice: String {
        if playback.isPlaying {
            return playback.activePreviewDevice  // "" のとき全プレイヤーが opacity 0 → 黒画面
        } else {
            // 再生ヘッド位置にセグメントがあるデバイスを優先表示
            if let activeDevice = timeline.activeDevice(at: playback.playheadTime) {
                return activeDevice
            }
            return selectedDevice
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            // ── 左：閉じるボタン ──
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.title3)
                    .foregroundColor(.white)
            }

            Spacer()

            // ── 中央：タイトル（表示のみ。編集はペンボタンから） ──
            Text(currentTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(minWidth: 80)

            Spacer()

            // ── 右：ペン（タイトル編集）+ ライブラリ + 書き出しボタン ──
            HStack(spacing: 10) {
                // タイトル編集ボタン（ペンアイコン）
                Button {
                    titleDraft = currentTitle == "UNTITLED" ? "" : currentTitle
                    isEditingTitle = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.15))
                        .clipShape(Circle())
                }

                // セッション削除ボタン（onDeleteSession が設定されているときのみ表示）
                if onDeleteSession != nil {
                    Button(action: { showDeleteSessionConfirm = true }) {
                        Image(systemName: "trash")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.15))
                            .clipShape(Circle())
                    }
                }

                // 書き出しボタン
                Button {
                    Task { await exportEngine.export(timeline: timeline, videos: videos, orientation: desiredOrientation, audioSource: audioSource, videoFilter: selectedFilter, showWatermark: true, pitchCents: pitchShiftCents, kaleidoscopeType: selectedKaleidoscope, kaleidoscopeSize: kaleidoscopeSize, kaleidoscopeCenterX: kaleidoscopeCenterX, kaleidoscopeCenterY: kaleidoscopeCenterY, tileHeight: tileHeight, rotationAngle: rotationAngle, segmentFilterSettings: segmentFilterSettings, speedRate: playbackSpeed) }  // TestFlight: 常に透かし表示（課金実装時に !purchaseManager.isPremium に戻す）
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(width: 36, height: 36)
                        .background(Color.white)
                        .clipShape(Circle())
                }
                .disabled({
                    if case .exporting = exportEngine.state { return true }
                    return false
                }())
            }
        }
        .padding(.horizontal, 20)
    }

    /// UIWindow から直接取得した top safe area inset（fullScreenCover 内でも確実）
    private var windowSafeAreaTop: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .keyWindow?.safeAreaInsets.top ?? 0
    }

    private func commitRename() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespaces)
        currentTitle = trimmed.isEmpty ? "UNTITLED" : trimmed
        onRename?(currentTitle)
        // タイトル保存と同時に現在の編集状態（セグメント）も保存
        onSaveEditState?(timeline.segmentsByDevice, timeline.lockedDevices, audioSource, selectedFilter, pitchShiftCents, selectedKaleidoscope, kaleidoscopeSize, kaleidoscopeCenterX, kaleidoscopeCenterY, tileHeight, playbackSpeed, segmentFilterSettings)
        isEditingTitle = false
    }

    // MARK: - Title Edit Sheet

    private var titleEditSheet: some View {
        VStack(spacing: 0) {
            // ── ドラッグハンドル ──
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color.white.opacity(0.3))
                .frame(width: 36, height: 5)
                .padding(.top, 12)
                .padding(.bottom, 20)

            // ── 入力フィールド ──
            VStack(alignment: .leading, spacing: 8) {
                Text("TITLE")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.horizontal, 4)

                TextField("Name this movie...", text: $titleDraft)
                    .foregroundColor(.white)
                    .font(.system(size: 20, weight: .semibold))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .focused($titleFieldFocused)
                    .onSubmit { commitRename() }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 24)

            // ── ボタン行 ──
            HStack(spacing: 12) {
                Button("Cancel") {
                    isEditingTitle = false
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.1))
                .foregroundColor(.white.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Button("Save") {
                    commitRename()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.white)
                .foregroundColor(.black)
                .fontWeight(.semibold)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.1).ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled()
        .onAppear {
            titleDraft = currentTitle == "UNTITLED" ? "" : currentTitle
            // シートの表示アニメーション完了後にキーボードを表示
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                titleFieldFocused = true
            }
        }
    }

    // MARK: - Device Lock Sheet

    private func deviceLockSheet(device: String) -> some View {
        let isLocked = timeline.lockedDevices.contains(device)
        return VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color.white.opacity(0.3))
                .frame(width: 36, height: 5)
                .padding(.top, 12)
                .padding(.bottom, 20)

            HStack(spacing: 8) {
                Image(systemName: isLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 18))
                    .foregroundColor(isLocked ? .orange : .white.opacity(0.5))
                Text(device)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(.bottom, 20)

            Button {
                timeline.toggleLock(for: device)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                lockPopoverDevice = nil
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isLocked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 20))
                        .foregroundColor(isLocked ? .orange : .white.opacity(0.5))
                    Text("Lock Timeline")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.1).ignoresSafeArea())
        .presentationDetents([.height(180)])
        .presentationDragIndicator(.hidden)
    }

    // MARK: - Export Overlay

    private func exportingOverlay(progress: Float) -> some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 20) {
                // 円形プログレス
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 6)
                        .frame(width: 80, height: 80)
                    Circle()
                        .trim(from: 0, to: CGFloat(progress))
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(width: 80, height: 80)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.1), value: progress)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }

                Text("Exporting...")
                    .font(.headline)
                    .foregroundColor(.white)

                Button("Cancel") {
                    exportEngine.cancel()
                }
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.6))
            }
        }
    }

    // MARK: - Timeline Section

    /// ラベル列の固定幅（左パディング込み）
    private let fixedLabelWidth: CGFloat = 52
    private let fixedLabelLeading: CGFloat = 12
    private let fixedDividerWidth: CGFloat = 1
    /// トラック内の左パディング
    private let trackInnerPad: CGFloat = 8
    /// 再生ヘッド●の直径
    private let knobDiameter: CGFloat = 24

    /// ScrollView のビューポート幅（ラベル列除く・ズーム倍率非依存の固定幅）
    /// zoomScale=1.0 のときにタイムライン全体がぴったり収まる幅
    private var trackViewportWidth: CGFloat {
        max(baseTrackWidth, 1)
    }

    /// ズーム済みのトラック幅（ScrollView コンテンツ幅）
    /// ピンチ中はcommittedZoomScaleベース、ピンチ外はzoomScaleベース
    private var scaledTrackWidth: CGFloat { max(trackViewportWidth * committedZoomScale, 1) }

    /// スクロール専用ストリップの高さ
    private let scrollStripH: CGFloat = 16

    /// TimelineRow を生成するヘルパー（型チェッカー負荷軽減のため分離）
    @ViewBuilder
    private func makeTimelineRow(device: String) -> some View {
        TimelineRow(
            deviceName: device,
            thumbnails: thumbnails[device] ?? [],
            isSelected: selectedDevice == device,
            isEditing: editingDevices.contains(device),
            segments: timeline.segments(for: device),
            totalDuration: totalDuration,
            videoStart:    timeline.videoRangeByDevice[device]?.start    ?? 0,
            videoEnd:      timeline.videoRangeByDevice[device]?.end      ?? totalDuration,
            videoDuration: timeline.videoRangeByDevice[device]?.duration ?? totalDuration,
            editingSegmentID: editingSegmentIDs[device],
            zoomScale: zoomScale,
            inverseScaleX: isPinching && committedZoomScale > 0.01
                ? committedZoomScale / zoomScale : 1.0,
            isLocked: timeline.lockedDevices.contains(device),
            showLabel: false,
            onTrimIn: { segID, newSec in
                editingSegmentIDs[device] = segID
                playback.isTrimming = true
                timeline.moveTrimIn(segmentID: segID, device: device, newTrimIn: newSec)
                let actual = timeline.segments(for: device).first(where: { $0.id == segID })?.trimIn ?? newSec
                playback.playheadTime = actual
                playback.throttledSeekForTrim(to: actual, timeline: timeline, selectedDevice: device)
            },
            onTrimOut: { segID, newSec in
                editingSegmentIDs[device] = segID
                playback.isTrimming = true
                timeline.moveTrimOut(segmentID: segID, device: device, newTrimOut: newSec)
                let actual = timeline.segments(for: device).first(where: { $0.id == segID })?.trimOut ?? newSec
                // 終端ちょうどだと真っ暗になるため、1フレーム(1/30s)手前をプレビュー
                let previewTime = max(actual - 1.0 / 30.0, 0)
                playback.playheadTime = previewTime
                playback.throttledSeekForTrim(to: previewTime, timeline: timeline, selectedDevice: device)
            },
            onCommitSelection: { trimIn, trimOut in
                timeline.applySelection(trimIn: trimIn, trimOut: trimOut, for: device)
                editingDevices.remove(device)
                editingSegmentIDs.removeValue(forKey: device)
            },
            onAddSegment: { seconds, trackWidth in
                timeline.addSegment(around: seconds, for: device, trackWidth: trackWidth)
                if let newSeg = timeline.segments(for: device).last {
                    editingSegmentIDs[device] = newSeg.id
                }
                playback.playheadTime = seconds
                playback.seekPreview(to: seconds, timeline: timeline, selectedDevice: device)
                editingDevices.insert(device)
            },
            onTap: { handleDeviceTap(device) },
            onSegmentTap: { segID in
                print("[PARENT] onSegmentTap device=\(device) seg=\(segID) editing=\(editingDevices) current=\(selectedDevice)")
                handleDeviceTap(device)
                editingSegmentIDs[device] = segID
                editingDevices.insert(device)
                timeline.commitAllSegments(for: device)
                if let seg = timeline.segments(for: device).first(where: { $0.id == segID }) {
                    playback.playheadTime = seg.trimIn
                    playback.seekPreview(to: seg.trimIn, timeline: timeline, selectedDevice: device)
                }
            },
            onTrimEnd: {
                playback.isTrimming = false
                playback.seekPreview(to: playback.playheadTime, timeline: timeline, selectedDevice: selectedDevice)
            }
        )
    }

    private var timelineSection: some View {
        let rowH: CGFloat = 56
        let rowCount = sortedDevices.count
        // トラック行の総高さ（行間スペース3pt × (rowCount-1) + 上下パディング各4pt = 8pt）
        let trackAreaH: CGFloat = CGFloat(rowCount) * rowH + 3 * CGFloat(max(rowCount - 1, 0)) + 8
        let knobOverhang: CGFloat = knobDiameter + 4           // 4089比率維持のためのスペース確保


        return HStack(spacing: 0) {
                // ① 固定ラベル列（3行超はオフセットでスクロール）
                VStack(spacing: 3) {
                    ForEach(sortedDevices, id: \.self) { device in
                        let isLocked = timeline.lockedDevices.contains(device)
                        VStack(spacing: 3) {
                            Image(systemName: isLocked ? "lock.fill" : "video.fill")
                                .font(.system(size: 10))
                                .foregroundColor(isLocked ? .orange : .white.opacity(0.5))
                            Text(device)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white.opacity(0.7))
                                .lineLimit(1).truncationMode(.tail)
                                .frame(width: fixedLabelWidth - 8)
                        }
                        .frame(width: fixedLabelWidth, height: rowH)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onTapGesture { lockPopoverDevice = device }
                    }
                }
                .padding(.leading, fixedLabelLeading)
                .padding(.bottom, 8)
                .frame(height: trackAreaH + knobOverhang + scrollStripH, alignment: .top)

                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: fixedDividerWidth, height: trackAreaH + knobOverhang + scrollStripH)

                // ② スクロール可能なトラック列
                GeometryReader { scrollGeo in
                    // ビューポート幅を取得（zoomScale 非依存）
                    let viewportW = scrollGeo.size.width
                    let _ = DispatchQueue.main.async {
                        // ビューポート幅 = zoomScale=1.0 のときのトラック全体幅
                        if abs(baseTrackWidth - viewportW) > 1 {
                            baseTrackWidth = viewportW
                        }
                    }

                    ScrollViewReader { scrollProxy in
                        let _ = DispatchQueue.main.async {
                            if timelineScrollProxy == nil { timelineScrollProxy = scrollProxy }
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            ZStack(alignment: .topLeading) {
                                // トラック行（縦スクロール対応）— ノブ上配置分だけ下にオフセット
                                VStack(spacing: 3) {
                                    ForEach(sortedDevices, id: \.self) { device in
                                        makeTimelineRow(device: device)
                                    }
                                }
                                .padding(.leading, trackInnerPad)
                                .padding(.trailing, 12)
                                .padding(.vertical, 4)

                                // スクロール用ストリップ（帯の下の黒い領域）
                                Rectangle()
                                    .fill(Color.white.opacity(0.03))
                                    .frame(height: scrollStripH)

                                // スクロール位置アンカー（101分割）：再生追従に使用
                                // ★ committedZoomScale ベースでレイアウト（ピンチ中は固定）
                                HStack(spacing: 0) {
                                    ForEach(0...100, id: \.self) { i in
                                        Color.clear
                                            .frame(width: max(viewportW * committedZoomScale, viewportW) / 101, height: 1)
                                            .id("scroll-anchor-\(i)")
                                    }
                                }
                                .frame(height: 0)

                                // 再生ヘッド：最前面に配置
                                playheadOverlay(trackHeight: trackAreaH)
                                    .zIndex(999)
                            }
                            // ★ レイアウト幅は committedZoomScale（ピンチ中は固定）
                            .frame(width: max(viewportW * committedZoomScale, viewportW))
                            // ★ ピンチ中の視覚的ズームは scaleEffect で処理
                            //   アンカーをプレイヘッド位置に設定 → 左上起点問題を解消
                            .scaleEffect(
                                x: isPinching ? zoomScale / committedZoomScale : 1.0,
                                y: 1.0,
                                anchor: UnitPoint(
                                    x: totalDuration > 0 ? CGFloat(playback.playheadTime / totalDuration) : 0.5,
                                    y: 0.5
                                )
                            )
                            .onChange(of: committedZoomScale) { _ in
                                // ピンチ終了後にcommit → レイアウト幅が変わった後にスクロール補正
                                let ratio = totalDuration > 0
                                    ? CGFloat(playback.playheadTime / totalDuration) : 0
                                let anchorID = Int((ratio * 100).rounded()).clamped(to: 0...100)
                                scrollProxy.scrollTo("scroll-anchor-\(anchorID)", anchor: .center)
                                DispatchQueue.main.async {
                                    scrollProxy.scrollTo("scroll-anchor-\(anchorID)", anchor: .center)
                                }
                            }
                            .onChange(of: zoomScale) { newScale in
                                // 非ピンチ時のみ処理（ズームバータップリセット等）
                                guard !isPinching else { return }
                                if newScale > 1.0 {
                                    let ratio = totalDuration > 0
                                        ? CGFloat(playback.playheadTime / totalDuration) : 0
                                    let anchorID = Int((ratio * 100).rounded()).clamped(to: 0...100)
                                    scrollProxy.scrollTo("scroll-anchor-\(anchorID)", anchor: .center)
                                }
                            }
                            // ズーム時、再生中にプレイヘッドがビューポート端に近づいたらゆっくりスクロール
                            .background(
                                GeometryReader { contentGeo in
                                    Color.clear.preference(
                                        key: ScrollOffsetKey.self,
                                        value: contentGeo.frame(in: .named("timelineScroll")).minX
                                    )
                                }
                            )
                            .onPreferenceChange(ScrollOffsetKey.self) { offset in
                                scrollContentOffset = -offset  // 左にスクロールするとminXが負になる
                            }
                            .onChange(of: playback.playheadTime) { _ in
                                guard committedZoomScale > 1.0 else { return }
                                guard totalDuration > 0 else { return }
                                // ズームバードラッグ中は自動スクロールしない（ドラッグ側が制御する）
                                guard zoomBarDragRatio == nil else { return }
                                
                                let contentWidth = viewportW * committedZoomScale
                                let playheadX = CGFloat(playback.playheadTime / totalDuration) * contentWidth
                                
                                // ビューポート内でのプレイヘッド位置
                                let localX = playheadX - scrollContentOffset
                                let edgeMargin = viewportW * 0.15
                                
                                // 右端に近づいた or 左端に近づいた → スクロール
                                if localX > viewportW - edgeMargin || localX < edgeMargin {
                                    let ratio = CGFloat(playback.playheadTime / totalDuration)
                                    let anchorID = Int((ratio * 100).rounded()).clamped(to: 0...100)
                                    withAnimation(.linear(duration: 0.3)) {
                                        scrollProxy.scrollTo("scroll-anchor-\(anchorID)", anchor: .center)
                                    }
                                }
                            }
                            .onChange(of: zoomBarScrollRequest) { request in
                                guard let req = request else { return }
                                scrollProxy.scrollTo("scroll-anchor-\(req.anchorID)", anchor: .center)
                            }
                        }
                        .scrollDisabled(true)
                        .coordinateSpace(name: "timelineScroll")
                    }
                }
                // ピンチズームはタイムライン列全体で受け取る
                // 縮小方向は0.5まで追従し、指を離すと1.0にスナップバック
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            isPinching = true
                            let raw = (zoomScaleAtGestureStart * value).clamped(to: 0.5...8.0)
                            zoomScale = raw
                            // faceSpread: 拡大→正（外へ）、縮小→負（内へ寄る＝顔）
                            faceSpread = ((raw - 1.0) * 6).clamped(to: -16...6)
                            // ★ ピンチ中はレイアウト幅を変えず scaleEffect のみ → 左上起点問題を解消
                        }
                        .onEnded { _ in
                            if zoomScale < 1.0 {
                                // スナップバック: zoomScaleは1.0に戻すが、faceSpreadは独立してアニメ
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                                    zoomScale = 1.0
                                }
                                // 顔のスプレッドは少し遅れて戻す（顔が見える時間を確保）
                                withAnimation(.spring(response: 0.5, dampingFraction: 0.5)) {
                                    faceSpread = 0
                                }
                                // スナップバック時は committedZoomScale も 1.0 に戻す
                                committedZoomScale = 1.0
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    isPinching = false
                                }
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                    faceSpread = 0
                                }
                                // ★ ピンチ終了: レイアウト幅を確定 → onChange(committedZoomScale) でスクロール補正
                                committedZoomScale = zoomScale
                                isPinching = false
                            }
                            zoomScaleAtGestureStart = max(zoomScale, 1.0)
                        }
                )
            }
            .frame(height: trackAreaH + knobOverhang + scrollStripH)
            .background(Color.white.opacity(0.04))

    }

    /// ピンチ中にプレイヘッド位置へ即座にスクロール
    /// （onChange(of: zoomScale) ではレイアウト後に発火するため1フレーム遅延する。
    ///   ジェスチャー onChanged 内で呼ぶことで同一フレームでスクロールが完了する）
    private func scrollToPlayhead() {
        guard let proxy = timelineScrollProxy else { return }
        let ratio = totalDuration > 0
            ? CGFloat(playback.playheadTime / totalDuration) : 0
        let anchorID = Int((ratio * 100).rounded()).clamped(to: 0...100)
        // アニメーション無しで即座にスクロール
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            proxy.scrollTo("scroll-anchor-\(anchorID)", anchor: .center)
        }
    }

    /// デバイスラベルタップ時の共通処理
    private func handleDeviceTap(_ device: String) {
        let prev = selectedDevice
        if device != prev && editingDevices.contains(prev) {
            // 前のデバイスの編集状態をクリア（排他制約は enforceExclusivity が管理）
            editingDevices.remove(prev)
            editingSegmentIDs.removeValue(forKey: prev)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        previousSelectedDevice = prev
        selectedDevice = device
        if device != prev {
            playback.activePreviewDevice = device
            playback.seekPreview(to: playback.playheadTime, timeline: timeline, selectedDevice: device)
        }
        // desiredOrientation に応じてアスペクト比を設定
        previewAspectRatio = desiredOrientation.aspectRatio
    }

    // MARK: - Playhead Overlay（ライン + ●ドラッグハンドル）

    /// ScrollView 内でのトラック先頭オフセット
    private var scrollLeftPad: CGFloat { trackInnerPad }
    /// トラック右パディング（TimelineRow の trailing padding と一致させる）
    private let trackTrailingPad: CGFloat = 12

    /// TimelineRow 内の GeometryReader 幅と一致する有効トラック幅
    private var effectiveTrackWidth: CGFloat {
        max(scaledTrackWidth - trackInnerPad - trackTrailingPad, 1)
    }

    private func playheadOverlay(trackHeight: CGFloat) -> some View {
        let ratio = totalDuration > 0 ? CGFloat(playback.playheadTime / totalDuration) : 0
        let lineX = scrollLeftPad + ratio * effectiveTrackWidth
        let knobBase = knobDiameter
        // ★ ドラッグ中は赤丸を2.0倍に拡大（24pt → 48pt）＋ 上に浮かせる
        let knob: CGFloat = isPlayheadDragging ? knobBase * 2.0 : knobBase
        let knobLift: CGFloat = isPlayheadDragging ? 20.0 : 0  // ドラッグ中だけ20pt上にひょいっと

        // ★ 親の scaleEffect(x:) の影響で赤丸・縦ラインが横に引き伸ばされるのを防ぐ逆スケール
        let currentScaleX: CGFloat = isPinching ? zoomScale / committedZoomScale : 1.0
        let inverseX: CGFloat = currentScaleX > 0.01 ? 1.0 / currentScaleX : 1.0
        
        return ZStack(alignment: .topLeading) {
            // ── 縦ライン（トラック上端からトラック下端まで）──
            Rectangle()
                .fill(Color.red)
                .frame(width: isPlayheadDragging ? 3 : 2, height: trackHeight)
                .scaleEffect(x: inverseX, y: 1.0)
                .offset(x: lineX - 1, y: 0)
                .allowsHitTesting(false)
                .id("playhead-anchor")

            // ── ●ドラッグハンドル ──
            // 通常: ノブ上端 = トラック下端（トラック直下にぶら下がる）
            // ドラッグ中: 2倍拡大 + 上に浮かせる
            Circle()
                .fill(Color.red)
                .frame(width: knob, height: knob)
                .scaleEffect(x: inverseX, y: 1.0)
                .shadow(color: isPlayheadDragging ? Color.red.opacity(0.5) : .clear, radius: 6)
                .offset(x: lineX - knob / 2, y: trackHeight - knobLift)
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isPlayheadDragging)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let startRatio = max(0, min(1,
                                (v.startLocation.x - scrollLeftPad) / effectiveTrackWidth))
                            let deltaRatio = v.translation.width / effectiveTrackWidth
                            let r = max(0, min(1, CGFloat(startRatio) + deltaRatio))
                            let sec = Double(r) * totalDuration
                            if !isPlayheadDragging {
                                isPlayheadDragging = true
                            }
                            playback.playheadTime = sec
                            playback.seekPreview(to: sec, timeline: timeline, selectedDevice: selectedDevice)
                        }
                        .onEnded { _ in
                            let sec = playback.playheadTime
                            isPlayheadDragging = false
                            playback.seekPreview(to: sec, timeline: timeline, selectedDevice: selectedDevice)
                        }
                )
        }
        // ZStack のフレーム = トラック高さ + ノブがはみ出る分
        .frame(height: trackHeight + knobBase + 4, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Playback Controls

    private var playbackControls: some View {
        VStack(spacing: 20) {
            // ── ズームバー ──────────────────────────────────────
            zoomBar

            // ── 再生ボタン（中央固定）+ 左右均等配置 ──────────────
            HStack(spacing: 0) {
                // 左グループ：音声設定（ソース + ピッチ統合）
                HStack(spacing: 20) {
                    Button {
                        // 再生中なら停止してからシートを開く
                        if playback.isPlaying {
                            playback.togglePlayback(allSegments: allSegmentsSorted(), totalDuration: totalDuration)
                            playback.pauseAudioSource()
                            playback.pitchEnginePause()
                        }
                        showAudioSheet = true
                    } label: {
                        Image(systemName: "headphones")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor((audioSource != nil || pitchShiftCents != 0) ? .cyan : .white.opacity(0.6))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                // 再生ボタン（常に中央）
                Button(action: {
                    if !playback.isPlaying {
                        editingDevices.removeAll()
                        editingSegmentIDs.removeAll()
                    }
                    playback.togglePlayback(allSegments: allSegmentsSorted(), totalDuration: totalDuration)
                    if playback.isPlaying {
                        playback.startAudioSource(playheadTime: playback.playheadTime)
                        startPitchEngineIfNeeded()
                    } else {
                        playback.pauseAudioSource()
                        playback.pitchEnginePause()
                    }
                }) {
                    Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64)).foregroundColor(.white)
                }
                .padding(.horizontal, 24)

                // 右グループ：フィルタ（左グループと同幅にして中央を維持）
                HStack(spacing: 20) {
                    Button {
                        // トリム選択中のセグメントがあれば自動的にそのセグメントを編集対象に
                        if let editingID = editingSegmentIDs[selectedDevice] {
                            filterEditingSegmentID = editingID
                        } else {
                            filterEditingSegmentID = nil
                        }
                        showFilterSheet = true
                    } label: {
                        Image(systemName: "camera.filters")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(hasAnyFilterApplied ? .cyan : .white.opacity(0.6))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .sheet(isPresented: $showAudioSheet) {
                audioSheet
            }
            .sheet(isPresented: $showFilterSheet) {
                videoFilterSheet
            }
        }
        .padding(.bottom, 16)
        .padding(.top, 4)
    }

    // MARK: - Audio Sheet (SOURCE + PITCH 統合)

    private var audioSheet: some View {
        NavigationView {
            VStack(spacing: 0) {
                // タブ切り替え
                Picker("", selection: $audioSheetTab) {
                    Text("SOURCE").tag(0)
                    Text("PITCH").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

                if audioSheetTab == 0 {
                    // ── SOURCE タブ ──
                    List {
                        Button {
                            audioSource = nil
                            applyAudioSource()
                        } label: {
                            HStack {
                                Image(systemName: "film")
                                    .foregroundColor(.white)
                                    .frame(width: 28)
                                Text("FOLLOW EDIT")
                                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white)
                                Spacer()
                                if audioSource == nil {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.cyan)
                                }
                            }
                        }
                        .listRowBackground(Color.white.opacity(0.08))

                        ForEach(sortedDevices, id: \.self) { device in
                            Button {
                                audioSource = device
                                applyAudioSource()
                            } label: {
                                HStack {
                                    Image(systemName: "mic.fill")
                                        .foregroundColor(.white)
                                        .frame(width: 28)
                                    Text(device)
                                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                                        .foregroundColor(.white)
                                    Spacer()
                                    if audioSource == device {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.cyan)
                                    }
                                }
                            }
                            .listRowBackground(Color.white.opacity(0.08))
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                } else {
                    // ── PITCH タブ ──
                    List {
                        ForEach(Self.pitchPresets, id: \.cents) { preset in
                            Button {
                                pitchShiftCents = preset.cents
                                applyPitchShift()
                                if preset.cents != 0 {
                                    // シートを閉じてからオーバーレイを表示
                                    showAudioSheet = false
                                    for (device, url) in videos {
                                        playback.extractAudioIfNeeded(device: device, videoURL: url) { _ in }
                                    }
                                }
                            } label: {
                                HStack {
                                    Image(systemName: preset.cents > 0 ? "arrow.up" : preset.cents < 0 ? "arrow.down" : "equal")
                                        .foregroundColor(.white)
                                        .frame(width: 28)
                                    Text(preset.label)
                                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                                        .foregroundColor(.white)
                                    Spacer()
                                    if pitchShiftCents == preset.cents {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.cyan)
                                    }
                                }
                            }
                            .listRowBackground(Color.white.opacity(0.08))
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("AUDIO")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("DONE") { showAudioSheet = false }
                        .foregroundColor(.cyan)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Video Filter Sheet (FILTER + KALEIDOSCOPE 統合, セグメント単位対応)

    /// 現在の編集スコープに応じた有効フィルタ名
    /// フィルターシートのスコープセレクターに表示するセグメント
    /// トリム選択中のセグメント + エフェクト適用済みセグメントのみ
    private func filterScopeSegments() -> [(device: String, seg: ClipSegment, label: String, hasEffect: Bool)] {
        let allSegs = allSegmentsSorted()
        // デバイスごとのセグメント番号を計算
        var deviceSegCount: [String: Int] = [:]

        // 表示対象のセグメントIDを収集（トリム選択中 + エフェクト適用済み）
        var visibleIDs = Set<UUID>()
        // トリム選択中のセグメント
        for (_, segID) in editingSegmentIDs {
            visibleIDs.insert(segID)
        }
        // エフェクト適用済みのセグメント
        for segID in segmentFilterSettings.keys {
            if let settings = segmentFilterSettings[segID], !settings.isDefault {
                visibleIDs.insert(segID)
            }
        }
        // filterEditingSegmentID が設定されていればそれも含む
        if let currentID = filterEditingSegmentID {
            visibleIDs.insert(currentID)
        }

        var result: [(device: String, seg: ClipSegment, label: String, hasEffect: Bool)] = []
        for entry in allSegs {
            let count = (deviceSegCount[entry.device] ?? 0) + 1
            deviceSegCount[entry.device] = count

            if visibleIDs.contains(entry.seg.id) {
                let hasEffect = segmentFilterSettings[entry.seg.id].map { !$0.isDefault } ?? false
                result.append((
                    device: entry.device,
                    seg: entry.seg,
                    label: "\(entry.device) #\(count)",
                    hasEffect: hasEffect
                ))
            }
        }
        return result
    }

    /// フィルタアイコン色判定: グローバルまたはセグメント単位でフィルタが適用されているか
    private var hasAnyFilterApplied: Bool {
        if selectedFilter != nil || selectedKaleidoscope != nil { return true }
        return segmentFilterSettings.values.contains { !$0.isDefault }
    }

    private var effectiveFilter: String? {
        if let segID = filterEditingSegmentID {
            return segmentFilterSettings[segID]?.videoFilter ?? selectedFilter
        }
        return selectedFilter
    }

    /// 現在の編集スコープに応じた有効万華鏡タイプ
    private var effectiveKaleidoscope: String? {
        if let segID = filterEditingSegmentID {
            return segmentFilterSettings[segID]?.kaleidoscopeType ?? selectedKaleidoscope
        }
        return selectedKaleidoscope
    }

    /// 現在の編集スコープに応じた有効万華鏡サイズ
    private var effectiveKaleidoscopeSize: Float {
        if let segID = filterEditingSegmentID {
            return segmentFilterSettings[segID]?.kaleidoscopeSize ?? kaleidoscopeSize
        }
        return kaleidoscopeSize
    }

    /// 現在の編集スコープに応じた有効TILE縦幅
    private var effectiveTileHeight: Float {
        if let segID = filterEditingSegmentID {
            return segmentFilterSettings[segID]?.tileHeight ?? tileHeight
        }
        return tileHeight
    }

    /// 現在の編集スコープに応じた有効MIRROR方向
    private var effectiveMirrorDirection: Int {
        if let segID = filterEditingSegmentID {
            return segmentFilterSettings[segID]?.mirrorDirection ?? mirrorDirection
        }
        return mirrorDirection
    }

    /// 現在の編集スコープに応じた有効回転角度
    private var effectiveRotationAngle: Float {
        if let segID = filterEditingSegmentID {
            return segmentFilterSettings[segID]?.rotationAngle ?? rotationAngle
        }
        return rotationAngle
    }

    /// 現在の編集スコープに応じた有効AUTO回転速度
    private var effectiveAutoRotateSpeed: Float {
        if let segID = filterEditingSegmentID {
            return segmentFilterSettings[segID]?.autoRotateSpeed ?? autoRotateSpeed
        }
        return autoRotateSpeed
    }

    /// 現在の編集スコープに応じた有効万華鏡中心X
    private var effectiveCenterX: Float {
        if let segID = filterEditingSegmentID {
            return segmentFilterSettings[segID]?.kaleidoscopeCenterX ?? kaleidoscopeCenterX
        }
        return kaleidoscopeCenterX
    }

    /// 現在の編集スコープに応じた有効万華鏡中心Y
    private var effectiveCenterY: Float {
        if let segID = filterEditingSegmentID {
            return segmentFilterSettings[segID]?.kaleidoscopeCenterY ?? kaleidoscopeCenterY
        }
        return kaleidoscopeCenterY
    }

    /// 現在の編集スコープに応じた有効スピード
    private var effectiveSpeed: Float {
        if let segID = filterEditingSegmentID {
            return segmentFilterSettings[segID]?.speedRate ?? playbackSpeed
        }
        return playbackSpeed
    }

    /// スピード変更をスコープに応じて適用する
    private func applySpeedChange(rate: Float) {
        if let segID = filterEditingSegmentID {
            // セグメント単位
            var settings = segmentFilterSettings[segID] ?? SegmentFilterSettings(
                videoFilter: selectedFilter,
                kaleidoscopeType: selectedKaleidoscope,
                kaleidoscopeSize: self.kaleidoscopeSize,
                kaleidoscopeCenterX: self.kaleidoscopeCenterX,
                kaleidoscopeCenterY: self.kaleidoscopeCenterY,
                speedRate: playbackSpeed
            )
            settings.speedRate = rate
            segmentFilterSettings[segID] = settings
            playback.segmentFilterSettings = segmentFilterSettings
        } else {
            // グローバル
            playbackSpeed = rate
        }
        applyPlaybackSpeed()
    }

    /// フィルタ変更をスコープに応じて適用する
    private func applyFilterChange(videoFilter: String?? = nil, kaleidoscopeType: String?? = nil, kaleidoscopeSize: Float? = nil, centerX: Float? = nil, centerY: Float? = nil, tileHeight: Float? = nil, mirrorDirection: Int? = nil, rotationAngle: Float? = nil, autoRotateSpeed: Float? = nil) {
        if let segID = filterEditingSegmentID {
            // セグメント単位: 辞書を更新
            var settings = segmentFilterSettings[segID] ?? SegmentFilterSettings(
                videoFilter: selectedFilter,
                kaleidoscopeType: selectedKaleidoscope,
                kaleidoscopeSize: self.kaleidoscopeSize,
                kaleidoscopeCenterX: self.kaleidoscopeCenterX,
                kaleidoscopeCenterY: self.kaleidoscopeCenterY,
                tileHeight: self.tileHeight,
                mirrorDirection: self.mirrorDirection,
                rotationAngle: self.rotationAngle,
                autoRotateSpeed: isAutoRotating ? self.autoRotateSpeed : 0
            )
            if let vf = videoFilter { settings.videoFilter = vf }
            if let kt = kaleidoscopeType { settings.kaleidoscopeType = kt }
            if let ks = kaleidoscopeSize { settings.kaleidoscopeSize = ks }
            if let cx = centerX { settings.kaleidoscopeCenterX = cx }
            if let cy = centerY { settings.kaleidoscopeCenterY = cy }
            if let th = tileHeight { settings.tileHeight = th }
            if let md = mirrorDirection { settings.mirrorDirection = md }
            if let ra = rotationAngle { settings.rotationAngle = ra }
            if let ars = autoRotateSpeed { settings.autoRotateSpeed = ars }
            segmentFilterSettings[segID] = settings
            // PlaybackController に同期
            playback.segmentFilterSettings = segmentFilterSettings
            playback.invalidateFilterCache()
            // 全プレイヤーに直接適用（applyFilterForSegment のキャッシュ問題を回避）
            playback.applyVideoFilter(
                filterName: settings.videoFilter,
                kaleidoscopeType: settings.kaleidoscopeType,
                kaleidoscopeSize: settings.kaleidoscopeSize,
                centerX: settings.kaleidoscopeCenterX,
                centerY: settings.kaleidoscopeCenterY,
                tileHeight: settings.tileHeight,
                mirrorDirection: settings.mirrorDirection,
                rotationAngle: settings.rotationAngle
            )
        } else {
            // グローバル: 既存の State 変数を更新
            if let vf = videoFilter { selectedFilter = vf }
            if let kt = kaleidoscopeType { selectedKaleidoscope = kt }
            if let ks = kaleidoscopeSize { self.kaleidoscopeSize = ks }
            if let cx = centerX { self.kaleidoscopeCenterX = cx }
            if let cy = centerY { self.kaleidoscopeCenterY = cy }
            if let th = tileHeight { self.tileHeight = th }
            if let md = mirrorDirection { self.mirrorDirection = md }
            if let ra = rotationAngle { self.rotationAngle = ra }
            if let ars = autoRotateSpeed { self.autoRotateSpeed = ars }
            // グローバル設定を PlaybackController に同期
            playback.globalFilterSettings = SegmentFilterSettings(
                videoFilter: selectedFilter,
                kaleidoscopeType: selectedKaleidoscope,
                kaleidoscopeSize: self.kaleidoscopeSize,
                kaleidoscopeCenterX: self.kaleidoscopeCenterX,
                kaleidoscopeCenterY: self.kaleidoscopeCenterY,
                tileHeight: self.tileHeight,
                mirrorDirection: self.mirrorDirection,
                rotationAngle: self.rotationAngle,
                autoRotateSpeed: isAutoRotating ? self.autoRotateSpeed : 0
            )
            playback.invalidateFilterCache()
            playback.applyVideoFilter(filterName: selectedFilter, kaleidoscopeType: selectedKaleidoscope, kaleidoscopeSize: self.kaleidoscopeSize, centerX: self.kaleidoscopeCenterX, centerY: self.kaleidoscopeCenterY, tileHeight: self.tileHeight, mirrorDirection: self.mirrorDirection, rotationAngle: self.rotationAngle)
        }
    }

    private var videoFilterSheet: some View {
        NavigationView {
            VStack(spacing: 0) {
                // ── セグメントスコープセレクター ──
                // ALL + トリム選択中セグメント + エフェクト適用済みセグメントのみ表示
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // ALL（グローバル）
                        Button {
                            filterEditingSegmentID = nil
                        } label: {
                            Text("ALL")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(filterEditingSegmentID == nil ? Color.cyan : Color.white.opacity(0.15))
                                .foregroundColor(filterEditingSegmentID == nil ? .black : .white.opacity(0.7))
                                .clipShape(Capsule())
                        }

                        // エフェクト適用済み + 現在トリム選択中のセグメントだけ表示
                        ForEach(filterScopeSegments(), id: \.seg.id) { entry in
                            let segID = entry.seg.id
                            Button {
                                filterEditingSegmentID = segID
                                playback.seekPreview(to: entry.seg.trimIn, timeline: timeline, selectedDevice: selectedDevice)
                            } label: {
                                HStack(spacing: 4) {
                                    Text(entry.label)
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    if entry.hasEffect {
                                        Circle().fill(Color.cyan).frame(width: 6, height: 6)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(filterEditingSegmentID == segID ? Color.cyan : Color.white.opacity(0.15))
                                .foregroundColor(filterEditingSegmentID == segID ? .black : .white.opacity(0.7))
                                .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

                // ── タブ切り替え ──
                Picker("", selection: $filterSheetTab) {
                    Text("FILTER").tag(0)
                    Text("MIRROR").tag(1)
                    Text("SPEED").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)

                if filterSheetTab == 0 {
                    // ── FILTER タブ ──
                    List {
                        ForEach(Self.videoFilters, id: \.label) { filter in
                            Button {
                                applyFilterChange(videoFilter: .some(filter.ciName))
                            } label: {
                                HStack {
                                    Image(systemName: filter.icon)
                                        .foregroundColor(.white)
                                        .frame(width: 28)
                                    Text(filter.label)
                                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                                        .foregroundColor(.white)
                                    Spacer()
                                    if effectiveFilter == filter.ciName {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.cyan)
                                    }
                                }
                            }
                            .listRowBackground(Color.white.opacity(0.08))
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                } else if filterSheetTab == 1 {
                    // ── MIRROR タブ ──
                    List {
                        ForEach(Self.kaleidoscopeFilters, id: \.label) { kfilter in
                            Button {
                                applyFilterChange(kaleidoscopeType: .some(kfilter.ciName))
                            } label: {
                                HStack {
                                    Image(systemName: kfilter.icon)
                                        .foregroundColor(.white)
                                        .frame(width: 28)
                                    Text(kfilter.label)
                                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                                        .foregroundColor(.white)
                                    Spacer()
                                    if effectiveKaleidoscope == kfilter.ciName {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.cyan)
                                    }
                                }
                            }
                            .listRowBackground(Color.white.opacity(0.08))

                            // 選択中のフィルタの直後にコントロールを表示（NONE時は非表示）
                            if effectiveKaleidoscope == kfilter.ciName, kfilter.ciName != nil {
                                if currentOverlayShape == .mirror {
                                    // MIRROR: L/R 切り替えボタン
                                    HStack(spacing: 12) {
                                        Text("FLIP")
                                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                                            .foregroundColor(.yellow)
                                        Spacer()
                                        Button {
                                            applyFilterChange(mirrorDirection: 0)
                                        } label: {
                                            Text("L")
                                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                                .frame(width: 40, height: 32)
                                                .background(effectiveMirrorDirection == 0 ? Color.yellow : Color.white.opacity(0.15))
                                                .foregroundColor(effectiveMirrorDirection == 0 ? .black : .white.opacity(0.7))
                                                .clipShape(Capsule())
                                        }
                                        .buttonStyle(.borderless)
                                        Button {
                                            applyFilterChange(mirrorDirection: 1)
                                        } label: {
                                            Text("R")
                                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                                .frame(width: 40, height: 32)
                                                .background(effectiveMirrorDirection == 1 ? Color.yellow : Color.white.opacity(0.15))
                                                .foregroundColor(effectiveMirrorDirection == 1 ? .black : .white.opacity(0.7))
                                                .clipShape(Capsule())
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                    .listRowBackground(Color.white.opacity(0.08))
                                } else if currentOverlayShape == .tile {
                                    // TILE: 横幅・縦幅の独立スライダー
                                    VStack(spacing: 8) {
                                        HStack(spacing: 8) {
                                            Text("W")
                                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                                .foregroundColor(.yellow)
                                                .frame(width: 16)
                                            Slider(value: Binding(
                                                get: { effectiveKaleidoscopeSize },
                                                set: { applyFilterChange(kaleidoscopeSize: $0) }
                                            ), in: 30...1000)
                                            .tint(.yellow)
                                            Text("\(Int(effectiveKaleidoscopeSize))")
                                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                                .foregroundColor(.white.opacity(0.5))
                                                .frame(width: 36, alignment: .trailing)
                                        }
                                        HStack(spacing: 8) {
                                            Text("H")
                                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                                .foregroundColor(.yellow)
                                                .frame(width: 16)
                                            Slider(value: Binding(
                                                get: { effectiveTileHeight },
                                                set: { applyFilterChange(tileHeight: $0) }
                                            ), in: 30...1000)
                                            .tint(.yellow)
                                            Text("\(Int(effectiveTileHeight))")
                                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                                .foregroundColor(.white.opacity(0.5))
                                                .frame(width: 36, alignment: .trailing)
                                        }
                                    }
                                    .listRowBackground(Color.white.opacity(0.08))
                                } else {
                                    // CIRCLE / TRIANGLE 等: 単一のSIZEスライダー
                                    HStack(spacing: 8) {
                                        Text("SIZE")
                                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                                            .foregroundColor(.yellow)
                                            .frame(width: 36)
                                        Slider(value: Binding(
                                            get: { effectiveKaleidoscopeSize },
                                            set: { applyFilterChange(kaleidoscopeSize: $0) }
                                        ), in: 30...1000)
                                        .tint(.yellow)
                                        Text("\(Int(effectiveKaleidoscopeSize))")
                                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.5))
                                            .frame(width: 36, alignment: .trailing)
                                    }
                                    .listRowBackground(Color.white.opacity(0.08))
                                    // ROTATE スライダー（AUTO OFF時のみ手動操作）
                                    HStack(spacing: 8) {
                                        Text("ROT")
                                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                                            .foregroundColor(.yellow)
                                            .frame(width: 36)
                                        Slider(value: Binding(
                                            get: { effectiveRotationAngle },
                                            set: { applyFilterChange(rotationAngle: $0) }
                                        ), in: 0...Float.pi * 2)
                                        .tint(.yellow)
                                        .disabled(isAutoRotating)
                                        .opacity(isAutoRotating ? 0.4 : 1.0)
                                        Text(String(format: "%.1f°", effectiveRotationAngle * 180 / .pi))
                                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.5))
                                            .frame(width: 42, alignment: .trailing)
                                    }
                                    .listRowBackground(Color.white.opacity(0.08))
                                    // AUTO回転トグル + SPEED スライダー
                                    VStack(spacing: 8) {
                                        HStack(spacing: 12) {
                                            Text("AUTO")
                                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                                .foregroundColor(.yellow)
                                            Spacer()
                                            Button {
                                                isAutoRotating.toggle()
                                                if isAutoRotating {
                                                    playback.startAutoRotation(speed: autoRotateSpeed)
                                                    // エクスポート用に autoRotateSpeed を設定に保存
                                                    applyFilterChange(autoRotateSpeed: autoRotateSpeed)
                                                } else {
                                                    playback.stopAutoRotation()
                                                    // 停止時の現在角度を State に同期
                                                    let currentAngle = playback.filterParamsHolder.currentRotationAngle()
                                                    rotationAngle = currentAngle
                                                    // エクスポート用に autoRotateSpeed を 0 に
                                                    applyFilterChange(rotationAngle: currentAngle, autoRotateSpeed: 0)
                                                }
                                            } label: {
                                                Text(isAutoRotating ? "ON" : "OFF")
                                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                                    .frame(width: 50, height: 32)
                                                    .background(isAutoRotating ? Color.yellow : Color.white.opacity(0.15))
                                                    .foregroundColor(isAutoRotating ? .black : .white.opacity(0.7))
                                                    .clipShape(Capsule())
                                            }
                                            .buttonStyle(.borderless)
                                        }
                                        if isAutoRotating {
                                            HStack(spacing: 8) {
                                                Text("SPD")
                                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                                    .foregroundColor(.yellow)
                                                    .frame(width: 36)
                                                Slider(value: Binding(
                                                    get: { autoRotateSpeed },
                                                    set: { newSpeed in
                                                        autoRotateSpeed = newSpeed
                                                        playback.startAutoRotation(speed: newSpeed)
                                                        applyFilterChange(autoRotateSpeed: newSpeed)
                                                    }
                                                ), in: 0.1...2.0)
                                                .tint(.yellow)
                                                Text(String(format: "%.1f", autoRotateSpeed))
                                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                                    .foregroundColor(.white.opacity(0.5))
                                                    .frame(width: 30, alignment: .trailing)
                                            }
                                        }
                                    }
                                    .listRowBackground(Color.white.opacity(0.08))
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                } else {
                    // ── SPEED タブ ──
                    List {
                        ForEach(Self.speedPresets, id: \.label) { preset in
                            Button {
                                applySpeedChange(rate: preset.rate)
                            } label: {
                                HStack {
                                    Image(systemName: preset.icon)
                                        .foregroundColor(.white)
                                        .frame(width: 28)
                                    Text(preset.label)
                                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                                        .foregroundColor(.white)
                                    Spacer()
                                    if effectiveSpeed == preset.rate {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.cyan)
                                    }
                                }
                            }
                            .listRowBackground(Color.white.opacity(0.08))
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("VIDEO EFFECT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("DONE") { showFilterSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .interactiveDismissDisabled(effectiveKaleidoscope != nil)
    }

    /// 音声ソース変更をプレイヤーのボリュームに反映する
    /// 再生スピードを PlaybackController に同期し、再生中なら即座に反映
    private func applyPlaybackSpeed() {
        // 現在再生中のセグメントの速度を優先
        let currentRate: Float
        if let segID = currentPlayingSegmentID(),
           let segSpeed = segmentFilterSettings[segID]?.speedRate,
           segSpeed != 1.0 {
            currentRate = segSpeed
        } else {
            currentRate = playbackSpeed
        }
        playback.playbackRate = currentRate
        // 再生中なら全アクティブプレイヤーのレートを即座に更新
        if playback.isPlaying {
            for (_, player) in playback.players where player.rate != 0 {
                player.rate = currentRate
            }
        }
    }

    /// 現在再生中のセグメントIDを返す
    private func currentPlayingSegmentID() -> UUID? {
        let pt = playback.playheadTime
        for device in sortedDevices {
            if let seg = timeline.segments(for: device)
                .first(where: { $0.trimIn <= pt && pt < $0.trimOut }) {
                return seg.id
            }
        }
        return nil
    }

    private func applyAudioSource() {
        // PlaybackController に音声ソースを伝える
        playback.audioSourceDevice = audioSource
        // videoStart マップを更新
        var starts: [String: Double] = [:]
        for device in sortedDevices {
            starts[device] = timeline.videoRangeByDevice[device]?.start ?? 0
        }
        playback.videoStartByDevice = starts

        // ピッチシフト有効時は AVPlayer を常にミュート（音声はエンジン経由）
        if pitchShiftCents != 0 {
            for (_, player) in playback.players {
                player.volume = 0
            }
            // 音声ソースが変更されたらピッチエンジンを再起動
            if playback.isPlaying {
                playback.pitchEnginePause()
                startPitchEngineIfNeeded()
            }
            return
        }

        if let source = audioSource {
            // 特定デバイスの音声のみ再生
            for (device, player) in playback.players {
                player.volume = (device == source) ? 1.0 : 0.0
            }
            // 即座に音声ソースを同期
            playback.syncAudioSource(playheadTime: playback.playheadTime)
        } else {
            // 編集に従う = 全プレイヤーの音量を戻す（activePreviewDevice のみ再生されるので問題なし）
            for (_, player) in playback.players {
                player.volume = 1.0
            }
            // 音声ソース用に再生中だったプレイヤーを停止
            playback.pauseAudioSource()
        }
    }

    // MARK: - Pitch Shift Control

    /// ピッチシフトの設定を PlaybackController に反映し、AVPlayer のボリュームを制御する
    private func applyPitchShift() {
        playback.pitchCents = pitchShiftCents
        if pitchShiftCents != 0 {
            // ピッチエンジン使用時: AVPlayer の全プレイヤーをミュート
            for (_, player) in playback.players {
                player.volume = 0
            }
            // 音声抽出は再生開始時に行う（ここでは設定だけ保存）
        } else {
            // ピッチなし: エンジン停止し、AVPlayer のボリュームを元に戻す
            playback.pitchEnginePause()
            playback.stopPitchEngine()
            applyAudioSource()  // audioSource の設定に従ってボリュームを復元
        }
    }

    /// 音声ソースの設定に従ってピッチエンジンで再生開始する
    /// - audioSource が設定されている場合はそのデバイスの音声を使用
    /// - nil（編集に従う）の場合は activePreviewDevice の音声を使用
    private func startPitchEngineIfNeeded() {
        guard pitchShiftCents != 0 else { return }
        // 音声ソースデバイスの決定
        let audioDevice = audioSource ?? playback.activePreviewDevice
        guard !audioDevice.isEmpty, let videoURL = videos[audioDevice] else {
            print("[PITCH] startPitchEngineIfNeeded: no device or URL (audio='\(audioSource ?? "nil")', active='\(playback.activePreviewDevice)')")
            return
        }
        let videoStart = timeline.videoRangeByDevice[audioDevice]?.start ?? 0
        let sourceTime = playback.playheadTime - videoStart
        guard sourceTime >= 0 else {
            print("[PITCH] startPitchEngineIfNeeded: sourceTime < 0")
            return
        }
        print("[PITCH] startPitchEngineIfNeeded: device=\(audioDevice) sourceTime=\(sourceTime)")
        // 音声を非同期で抽出し、完了後にエンジンで再生開始
        playback.extractAudioIfNeeded(device: audioDevice, videoURL: videoURL) { [weak playback] audioURL in
            guard let playback else {
                print("[PITCH] callback: playback is nil")
                return
            }
            guard let audioURL else {
                print("[PITCH] callback: audioURL is nil")
                return
            }
            guard playback.isPlaying else {
                print("[PITCH] callback: not playing, skipping")
                return
            }
            playback.pitchEnginePlay(from: sourceTime, audioURL: audioURL, device: audioDevice)
        }
    }

    // MARK: - Zoom Bar（スクロール位置インジケーター兼ズームコントロール）

    /// バーの表示幅（固定）
    private let zoomBarBaseWidth: CGFloat = 200
    /// スクロールバー操作中フラグ（ピンチ・ドラッグのいずれかが true のとき拡大表示）
    @State private var isZoomBarActive: Bool = false
    /// ピンチジェスチャー中フラグ（丸のビヨーンアニメ用）
    @State private var isPinching: Bool = false
    /// 顔アニメーション用の独立したスプレッド値（スナップバック時にzoomScaleと独立して動く）
    @State private var faceSpread: CGFloat = 0
    /// ドラッグ中のバー上ratio（0〜1）。nil＝ドラッグ中でない → scrollContentOffset 由来を使う
    @State private var zoomBarDragRatio: CGFloat? = nil
    /// 左●タップフィードバック
    @State private var leftCircleTapped: Bool = false
    /// 右●タップフィードバック
    @State private var rightCircleTapped: Bool = false

    /// mm:ss 形式にフォーマット
    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private var zoomBar: some View {
        // ズーム中はビューポートがタイムライン全体の 1/zoomScale を表示している
        let viewRatio: CGFloat = zoomScale > 1 ? 1.0 / zoomScale : 1.0

        // サムの左端位置を算出
        let visibleLeft: CGFloat = {
            if let dragR = zoomBarDragRatio {
                // ドラッグ中: 指の位置をサムの中心にマッピング
                return (dragR - viewRatio / 2).clamped(to: 0...(1 - viewRatio))
            }
            // 通常時: scrollContentOffset と playhead 位置のハイブリッド
            let contentWidth = max(baseTrackWidth * zoomScale, baseTrackWidth)
            let scrollRatio: CGFloat = contentWidth > baseTrackWidth
                ? scrollContentOffset / (contentWidth - baseTrackWidth)
                : 0
            let fromScroll = (scrollRatio * (1 - viewRatio)).clamped(to: 0...(1 - viewRatio))

            // playhead の位置からも算出（表示窓の中心が playhead に来るように）
            if zoomScale > 1.0 && totalDuration > 0 {
                let playRatio = CGFloat(playback.playheadTime / totalDuration)
                let fromPlayhead = (playRatio - viewRatio / 2).clamped(to: 0...(1 - viewRatio))
                let drift = abs(fromScroll - fromPlayhead)
                if drift > viewRatio * 0.5 {
                    return fromPlayhead
                }
            }
            return fromScroll
        }()
        let thumbX = visibleLeft * zoomBarBaseWidth
        let thumbW = max(viewRatio * zoomBarBaseWidth, 12)

        // アクティブ時はバーを太く・サム（つまみ）も太く
        let trackH: CGFloat = isZoomBarActive ? 6 : 3
        let thumbH: CGFloat = isZoomBarActive ? 10 : 5

        // ●のサイズ（タップフィードバック時は大きく白く）
        // ★ コンテナからはみ出さないよう小さめに設定
        let leftActive = isZoomBarActive || leftCircleTapped
        let rightActive = isZoomBarActive || rightCircleTapped
        let leftSize: CGFloat = leftCircleTapped ? 36 : (isZoomBarActive ? 32 : 22)
        let rightSize: CGFloat = rightCircleTapped ? 36 : (isZoomBarActive ? 32 : 22)

        // 顔モード: 縮小ピンチで丸が接近して顔になる
        let isFaceMode = faceSpread < -4

        return VStack(spacing: 6) {
            // ── ピンチ操作エリア ──────────────────────────────────
            HStack(spacing: isFaceMode ? 0 : 10) {
                // 左の丸（目）— ピンチ時に左へ広がる or 縮小時に中央へ寄る
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(leftActive ? 0.90 : 0.30))
                        .frame(width: leftSize, height: leftSize)
                    // 顔モード時に目を表示
                    if isFaceMode {
                        Circle()
                            .fill(Color.black)
                            .frame(width: leftSize * 0.28, height: leftSize * 0.28)
                            .offset(x: leftSize * 0.06, y: -leftSize * 0.06)
                    }
                }
                .frame(width: 36, height: 36) // 固定フレームでサイズ変化が親レイアウトに伝播しない
                .offset(x: -faceSpread)
                .animation(.spring(response: 0.3, dampingFraction: 0.55), value: faceSpread)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: leftCircleTapped)
                // タップ → 始端へ移動 + タイムラインスクロール
                .onTapGesture {
                    leftCircleTapped = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { leftCircleTapped = false }

                    playback.jumpToStart(allSegments: allSegmentsSorted())
                    if zoomScale > 1.0 {
                        scrollRequestSerial &+= 1
                        zoomBarScrollRequest = ScrollRequest(anchorID: 0, serial: scrollRequestSerial)
                    }
                }

                // 顔モード: 丸の間に口を表示 / 通常時: スクロールバー
                if isFaceMode {
                    // 口（ ‿ カーブ）
                    Text("‿")
                        .font(.system(size: leftSize * 0.7, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .offset(y: leftSize * 0.10)
                        .transition(.opacity)
                } else {
                    // スクロール位置インジケーターバー
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(isZoomBarActive ? 0.18 : 0.10))
                            .frame(width: zoomBarBaseWidth, height: trackH)

                        Capsule()
                            .fill(Color.white.opacity(isZoomBarActive ? 0.85 : 0.50))
                            .frame(width: thumbW, height: thumbH)
                            .offset(x: thumbX, y: 0)
                            .animation(.easeOut(duration: 0.08), value: thumbX)
                            .shadow(color: isZoomBarActive ? .white.opacity(0.4) : .clear, radius: 4)
                    }
                    .frame(width: zoomBarBaseWidth)
                    .onTapGesture {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            zoomScale = 1.0
                            committedZoomScale = 1.0
                            zoomScaleAtGestureStart = 1.0
                        }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                }

                // 右の丸（目）— ピンチ時に右へ広がる or 縮小時に中央へ寄る
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(rightActive ? 0.90 : 0.30))
                        .frame(width: rightSize, height: rightSize)
                    // 顔モード時に目を表示
                    if isFaceMode {
                        Circle()
                            .fill(Color.black)
                            .frame(width: rightSize * 0.28, height: rightSize * 0.28)
                            .offset(x: -rightSize * 0.06, y: -rightSize * 0.06)
                    }
                }
                .frame(width: 36, height: 36) // 固定フレームでサイズ変化が親レイアウトに伝播しない
                .offset(x: faceSpread)
                .animation(.spring(response: 0.3, dampingFraction: 0.55), value: faceSpread)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: rightCircleTapped)
                // タップ → 終端へ移動 + タイムラインスクロール
                .onTapGesture {
                    rightCircleTapped = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { rightCircleTapped = false }

                    playback.jumpToEnd(allSegments: allSegmentsSorted(), totalDuration: totalDuration)
                    if zoomScale > 1.0 {
                        let anchorID = Int((CGFloat(0.95) * 100).rounded()).clamped(to: 0...100)
                        scrollRequestSerial &+= 1
                        zoomBarScrollRequest = ScrollRequest(anchorID: anchorID, serial: scrollRequestSerial)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                // GeometryReader でバー全体の実幅を取得（ドラッグ座標のマッピング用）
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(isZoomBarActive ? 0.10 : 0.05))
                        .animation(.easeOut(duration: 0.2), value: isZoomBarActive)
                        .preference(key: ZoomBarWidthKey.self, value: geo.size.width)
                }
            )
            .onPreferenceChange(ZoomBarWidthKey.self) { width in
                zoomBarActualWidth = width
            }
            .contentShape(Rectangle())
            // バー全体でドラッグ → タイムラインをスクロール＋再生ヘッドも追従
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { v in
                        isZoomBarActive = true
                        // 実際のフレーム幅を使って中心基準で ratio を算出
                        let ratio = max(0, min(1, v.location.x / zoomBarActualWidth))
                        zoomBarDragRatio = ratio
                        let anchorID = Int((ratio * 100).rounded()).clamped(to: 0...100)
                        scrollRequestSerial &+= 1
                        zoomBarScrollRequest = ScrollRequest(anchorID: anchorID, serial: scrollRequestSerial)
                        if totalDuration > 0 {
                            let t = Double(ratio) * totalDuration
                            playback.playheadTime = t
                            playback.seekPreview(to: t, timeline: timeline, selectedDevice: selectedDevice)
                        }
                    }
                    .onEnded { _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            zoomBarDragRatio = nil
                        }
                        withAnimation(.easeOut(duration: 0.35)) { isZoomBarActive = false }
                        zoomBarScrollRequest = nil
                    }
            )
            // ピンチでズーム倍率を変える
            // 縮小方向は0.5まで追従し、指を離すと1.0にスナップバック（カートゥーン的挙動）
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        isZoomBarActive = true
                        isPinching = true
                        let raw = (zoomScaleAtGestureStart * value).clamped(to: 0.5...8.0)
                        zoomScale = raw
                        faceSpread = ((raw - 1.0) * 6).clamped(to: -16...6)
                    }
                    .onEnded { _ in
                        if zoomScale < 1.0 {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                                zoomScale = 1.0
                            }
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.5)) {
                                faceSpread = 0
                            }
                            committedZoomScale = 1.0
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                isPinching = false
                            }
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                faceSpread = 0
                            }
                            committedZoomScale = zoomScale
                            isPinching = false
                        }
                        zoomScaleAtGestureStart = max(zoomScale, 1.0)
                        withAnimation(.easeOut(duration: 0.35)) { isZoomBarActive = false }
                    }
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isZoomBarActive)

            // 時間表示：現在位置 / 総尺
            HStack(spacing: 0) {
                Text(formatTime(playback.playheadTime))
                    .foregroundColor(.white.opacity(0.8))
                Text(" / ")
                    .foregroundColor(.white.opacity(0.35))
                Text(formatTime(totalDuration))
                    .foregroundColor(.white.opacity(0.4))
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
    }

    /// ズームバー全体の実際の幅（GeometryReader で取得）
    @State private var zoomBarActualWidth: CGFloat = 350

    private var emptyState: some View {
        VStack(spacing: 20) {
            // 脱出用の閉じるボタン（常に表示）
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.title3)
                        .foregroundColor(.white)
                        .padding(12)
                }
                Spacer()
            }
            .padding(.horizontal, 8)

            Spacer()
            Image(systemName: "video.slash").font(.system(size: 60)).foregroundColor(.white.opacity(0.4))
            Text("No Videos").foregroundColor(.white.opacity(0.6))
            Text("Video files not found")
                .font(.caption)
                .foregroundColor(.white.opacity(0.3))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }

    // MARK: - Setup

    private func setupAll() async {
        // プレイヤー初期化（PlaybackController に委譲）
        await MainActor.run { playback.setup(videos: videos) }

        // duration + preferredTransform 並列取得
        var durations: [String: Double] = [:]
        var transforms: [String: CGAffineTransform] = [:]
        await withTaskGroup(of: (String, Double, CGAffineTransform).self) { group in
            for (device, url) in videos {
                group.addTask {
                    let asset = AVURLAsset(url: url)
                    let dur = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
                    // 動画トラックの preferredTransform を取得（天地回転の検出用）
                    var transform = CGAffineTransform.identity
                    if let track = try? await asset.loadTracks(withMediaType: .video).first {
                        transform = (try? await track.load(.preferredTransform)) ?? .identity
                    }
                    return (device, dur, transform)
                }
            }
            for await (device, dur, transform) in group {
                durations[device] = dur
                transforms[device] = transform
            }
        }

        // preferredTransform を MetalPreviewRenderer に渡す（天地回転対応）
        await MainActor.run { playback.metalRenderer.videoTransforms = transforms }

        // タイムライン初期化
        await MainActor.run {
            timeline.setup(durations: durations, orderedDevices: sortedDevices)
            // 保存済みの編集状態があれば復元する
            if !savedEditState.isEmpty {
                timeline.restoreEditState(savedEditState)
            }
            // ロック状態を復元
            if !savedLockedDevices.isEmpty {
                timeline.lockedDevices = Set(savedLockedDevices)
            }
            // 音声デバイス・フィルタ・万華鏡・速度・ピッチを復元
            audioSource = savedAudioDevice
            selectedFilter = savedVideoFilter
            pitchShiftCents = savedPitchCents
            selectedKaleidoscope = savedKaleidoscope
            kaleidoscopeSize = savedKaleidoscopeSize
            kaleidoscopeCenterX = savedKaleidoscopeCenterX
            kaleidoscopeCenterY = savedKaleidoscopeCenterY
            tileHeight = savedTileHeight
            playbackSpeed = savedPlaybackSpeed
            playback.playbackRate = savedPlaybackSpeed
            // セグメント単位のフィルタ設定を復元
            var restoredSegFilters: [UUID: SegmentFilterSettings] = [:]
            for (_, states) in savedEditState {
                for state in states {
                    if let saved = state.filterSettings {
                        restoredSegFilters[state.id] = saved.toSegmentFilterSettings()
                    }
                }
            }
            if !restoredSegFilters.isEmpty {
                segmentFilterSettings = restoredSegFilters
                playback.segmentFilterSettings = restoredSegFilters
            }
            // グローバルフィルタ設定を PlaybackController に同期
            playback.globalFilterSettings = SegmentFilterSettings(
                videoFilter: selectedFilter,
                kaleidoscopeType: selectedKaleidoscope,
                kaleidoscopeSize: kaleidoscopeSize,
                kaleidoscopeCenterX: kaleidoscopeCenterX,
                kaleidoscopeCenterY: kaleidoscopeCenterY,
                rotationAngle: rotationAngle,
                autoRotateSpeed: isAutoRotating ? autoRotateSpeed : 0,
                speedRate: playbackSpeed
            )
            // 保存済みフィルタがあればプレビューに適用
            if selectedFilter != nil || selectedKaleidoscope != nil {
                playback.applyVideoFilter(filterName: selectedFilter, kaleidoscopeType: selectedKaleidoscope, kaleidoscopeSize: kaleidoscopeSize, centerX: kaleidoscopeCenterX, centerY: kaleidoscopeCenterY, tileHeight: tileHeight, mirrorDirection: mirrorDirection, rotationAngle: rotationAngle)
            }
            playback.totalDuration = timeline.totalDuration
            // 音声同期用に各デバイスの映像開始時刻を渡す
            var starts: [String: Double] = [:]
            for device in sortedDevices {
                starts[device] = timeline.videoRangeByDevice[device]?.start ?? 0
            }
            playback.videoStartByDevice = starts
            if let longest = durations.max(by: { $0.value < $1.value })?.key {
                selectedDevice = longest
                playback.activePreviewDevice = longest
            } else if let first = sortedDevices.first {
                selectedDevice = first
                playback.activePreviewDevice = first
            }
            // 音声ソースを PlaybackController に反映（ボリューム設定）
            applyAudioSource()
        }

        // アスペクト比はすぐ設定（サムネイルより先にレイアウトを確定）
        await MainActor.run { previewAspectRatio = desiredOrientation.aspectRatio }

        // サムネイル取得（完了まで Loading 表示を維持）
        await generateAllThumbnails()

        // サムネイル完了 → Loading 解除
        await MainActor.run { isReady = true }
    }

    // MARK: - Playback Logic（seekPreview / toggle / seekToSegment は PlaybackController へ移譲済み）

    // MARK: - Thumbnail / AspectRatio

    private func generateAllThumbnails() async {
        await withTaskGroup(of: (String, [UIImage]).self) { group in
            for (device, url) in videos {
                group.addTask { (device, await generateThumbnails(for: url, count: 8)) }
            }
            var result: [String: [UIImage]] = [:]
            for await (device, imgs) in group { result[device] = imgs }
            await MainActor.run { thumbnails = result }
        }
    }

    private func generateThumbnails(for url: URL, count: Int) async -> [UIImage] {
        let asset = AVURLAsset(url: url)
        guard let dur = try? await asset.load(.duration) else { return [] }
        let total = CMTimeGetSeconds(dur)
        guard total > 0 else { return [] }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 200, height: 200)
        var images: [UIImage] = []
        for i in 0..<count {
            let t = CMTimeMakeWithSeconds(total * Double(i) / Double(max(count - 1, 1)),
                                          preferredTimescale: 600)
            if let cg = try? await gen.image(at: t).image {
                images.append(Self.centerCropToSquare(cgImage: cg))
            }
        }
        return images
    }

    /// CGImage をセンタークロップで正方形に切り抜く
    private static func centerCropToSquare(cgImage: CGImage) -> UIImage {
        let w = cgImage.width
        let h = cgImage.height
        let side = min(w, h)
        let x = (w - side) / 2
        let y = (h - side) / 2
        let cropRect = CGRect(x: x, y: y, width: side, height: side)
        if let cropped = cgImage.cropping(to: cropRect) {
            return UIImage(cgImage: cropped)
        }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - TimelineRow

private struct TimelineRow: View {
    let deviceName: String
    let thumbnails: [UIImage]
    let isSelected: Bool
    let isEditing: Bool
    let segments: [ClipSegment]
    let totalDuration: Double
    let videoStart: Double
    let videoEnd: Double
    let videoDuration: Double
    /// 編集ハンドルを表示する対象セグメントID（最後に追加/操作したもの1つだけ）
    let editingSegmentID: UUID?
    /// 親から渡されるズーム倍率（ロングプレスの trackWidth 計算に使う）
    let zoomScale: CGFloat
    /// ピンチ中の scaleEffect を打ち消す逆スケール値（ハンドル幅の伸び防止）
    var inverseScaleX: CGFloat = 1.0
    /// デバイスがロックされているか
    var isLocked: Bool = false
    /// false のときラベル列を非表示にする（ラベルを ScrollView 外に固定するため）
    var showLabel: Bool = true

    let onTrimIn:          (UUID, Double) -> Void
    let onTrimOut:         (UUID, Double) -> Void
    let onCommitSelection: (Double, Double) -> Void
    let onAddSegment:      (_ seconds: Double, _ trackWidth: CGFloat) -> Void
    let onTap: () -> Void
    /// セグメントの青枠をタップしたときに、そのセグメントIDを通知する
    var onSegmentTap: ((UUID) -> Void)? = nil

    /// トリムドラッグ終了時のコールバック
    var onTrimEnd: (() -> Void)? = nil

    @State private var draggingID: UUID? = nil
    @State private var dragStartX: CGFloat = 0
    @State private var longPressLocation: CGFloat = 0

    private let labelWidth:  CGFloat = 52
    private let thumbHeight: CGFloat = 52
    private let handleWidth: CGFloat = 16

    /// セグメントの枠色（ロック時は濃いめのグレー）
    private var segmentColor: Color { isLocked ? Color(white: 0.35) : trimHandleColor }
    /// トリムハンドル用の色（Photos風イエロー）
    private let trimHandleColor: Color = Color(red: 1.0, green: 0.82, blue: 0.0)

    var body: some View {
        HStack(spacing: 0) {
            // デバイスラベル（showLabel=false のとき非表示）
            if showLabel {
                VStack(spacing: 3) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                    Text(deviceName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: labelWidth - 8)
                }
                .frame(width: labelWidth, height: thumbHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1).padding(.vertical, 4)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // ① ベース：サムネイル表示（暗め）+ 長押しでセグメント追加
                    //    LongPressGesture を使うことで、タップやドラッグは上のレイヤーに通す
                    thumbnailStrip(width: geo.size.width, dimmed: true)
                        .contentShape(Rectangle())
                        .onLongPressGesture(minimumDuration: 0.4) {
                            guard !isLocked else { return }
                            let capturedWidth = geo.size.width
                            guard totalDuration > 0, capturedWidth > 0 else { return }
                            let ratio = max(0, min(1, longPressLocation / capturedWidth))
                            let seconds = Double(ratio) * totalDuration
                            print("[TIMELINE] longPress ADD segment device=\(deviceName) sec=\(seconds)")
                            onAddSegment(seconds, capturedWidth)
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            onTap()
                        } onPressingChanged: { pressing in
                            if !pressing {
                                longPressLocation = 0
                            }
                        }
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    longPressLocation = v.location.x
                                }
                        )
                    // ② 使用範囲ごとにサムネイルを明るくくり抜く＋常に青枠
                    ForEach(segments) { seg in
                        activeThumbnailClip(
                            seg: seg,
                            width: geo.size.width,
                            showBlueBorder: true
                        )
                    }
                    // ③ トリムハンドル：編集モード かつ 対象セグメントのみ表示（ロック時は非表示）
                    if isEditing && !isLocked {
                        ForEach(segments) { seg in
                            if seg.id == editingSegmentID {
                                trimHandles(seg: seg, width: geo.size.width)
                            }
                        }
                    }
                }
            }
            .frame(height: thumbHeight)
        }
        .frame(height: thumbHeight)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: showLabel ? 8 : 4))
        .overlay(
            RoundedRectangle(cornerRadius: showLabel ? 8 : 4)
                .stroke(
                    isEditing
                        ? Color.white.opacity(0.5)
                        : Color.white.opacity(0.08),
                    lineWidth: isEditing ? 1.5 : 0.5
                )
        )
    }

    // MARK: ① 暗めのベースサムネイル（未使用感を演出）

    @ViewBuilder
    private func thumbnailStrip(width: CGFloat, dimmed: Bool) -> some View {
        if totalDuration > 0 {
            // segments.first ではなく固定値を使う（segments が空でも消えない）
            let vStartX = totalDuration > 0 ? CGFloat(videoStart / totalDuration) * width : 0
            let vEndX   = totalDuration > 0 ? CGFloat(videoEnd   / totalDuration) * width : width
            let vWidth  = max(vEndX - vStartX, 0)

            ZStack(alignment: .leading) {
                // 映像のない左側（斜線パターン）
                if vStartX > 0 {
                    hatchPattern().frame(width: vStartX, height: thumbHeight)
                }

                // サムネイルストリップ
                thumbnailContent(width: vWidth)
                    .frame(width: vWidth, height: thumbHeight)
                    .clipShape(Rectangle())
                    .offset(x: vStartX)
                    .overlay(dimmed ? Color.black.opacity(0.45) : Color.clear)
            }
        } else {
            Rectangle().fill(Color.white.opacity(0.05)).frame(width: width, height: thumbHeight)
        }
    }

    // MARK: ② 使用範囲だけ明るくくり抜く
    // SwiftUI の offset + clip で表示。UIGraphicsImageRenderer を使わないため軽量。

    @ViewBuilder
    private func activeThumbnailClip(
        seg: ClipSegment,
        width: CGFloat,
        showBlueBorder: Bool = false
    ) -> some View {
        if totalDuration > 0, width > 0 {
            let vStartX = CGFloat(videoStart / totalDuration) * width
            let vWidth  = max(CGFloat((videoEnd - videoStart) / totalDuration) * width, 1)
            let inX     = seg.trimInRatio(total: totalDuration)  * width
            let outX    = seg.trimOutRatio(total: totalDuration) * width
            let clipW   = max(outX - inX, 0)

            HStack(spacing: 0) {
                Color.clear.frame(width: inX, height: thumbHeight)
                ZStack {
                    // サムネイルストリップを offset で配置し、clipW の窓でクリップ
                    thumbnailContent(width: vWidth)
                        .frame(width: vWidth, height: thumbHeight)
                        .offset(x: vStartX - inX)
                        .frame(width: clipW, height: thumbHeight, alignment: .leading)
                        .clipped()

                    // 選択中セグメントに枠を表示（ロック時は深いブルー）
                    if showBlueBorder && clipW > 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(segmentColor, lineWidth: 2)
                            .frame(width: clipW, height: thumbHeight)
                    }
                }
                .frame(width: clipW, height: thumbHeight)
                // 青枠エリアをタップ → このセグメントを編集対象に選択
                .contentShape(Rectangle())
                .onTapGesture {
                    print("[TIMELINE] segmentTap: \(seg.id) device=\(deviceName)")
                    onSegmentTap?(seg.id)
                }
                // 編集中セグメントはトリムハンドルにタッチを譲る
                .allowsHitTesting(seg.id != editingSegmentID)
                Spacer(minLength: 0)
            }
            .frame(width: width, height: thumbHeight)
            .allowsHitTesting(onSegmentTap != nil && !isLocked)
        }
    }

    // MARK: ③ トリムハンドル（両端のみ、固定幅バー）
    //
    // レイアウト方針:
    //   IN ハンドル  : 右端が inX に一致  → offset(x: inX - handleWidth)
    //   OUT ハンドル : 左端が outX に一致 → offset(x: outX)
    //
    // 操作:
    //   ドラッグ    → 範囲をリアルタイムで変更（明暗が動く）
    //   別デバイス選択 → 範囲を確定（他デバイスの重複部分を削除）

    @ViewBuilder
    private func trimHandles(seg: ClipSegment, width: CGFloat) -> some View {
        if totalDuration > 0, width > 0 {
            let inX      = seg.trimInRatio(total: totalDuration)  * width
            let outX     = seg.trimOutRatio(total: totalDuration) * width
            ZStack(alignment: .topLeading) {
                // 上下ボーダー：常時表示（選択中を示す）
                // ボーダーの線幅が scaleEffect で伸びるのを防ぐため、逆スケール補正した lineWidth を使用
                let borderW: CGFloat = 2.5 * inverseScaleX
                Path { path in
                    path.move(to: CGPoint(x: inX, y: 0))
                    path.addLine(to: CGPoint(x: outX, y: 0))
                    path.move(to: CGPoint(x: inX, y: thumbHeight))
                    path.addLine(to: CGPoint(x: outX, y: thumbHeight))
                }
                .stroke(trimHandleColor.opacity(0.9), lineWidth: borderW)
                .allowsHitTesting(false)

                // IN点ハンドル：右端を inX に合わせる
                handleBar(isLeading: true)
                    .frame(width: handleWidth, height: thumbHeight)
                    .scaleEffect(x: inverseScaleX, y: 1.0)
                    .padding(.horizontal, 20)  // タッチ領域拡大
                    .offset(x: inX - handleWidth - 20)
                    .gesture(inHandleGesture(seg: seg, width: width))

                // OUT点ハンドル：左端を outX に合わせる
                handleBar(isLeading: false)
                    .frame(width: handleWidth, height: thumbHeight)
                    .scaleEffect(x: inverseScaleX, y: 1.0)
                    .padding(.horizontal, 20)  // タッチ領域拡大
                    .offset(x: outX - 20)
                    .gesture(outHandleGesture(seg: seg, width: width))



                // IN点の縦線
                Rectangle()
                    .fill(trimHandleColor)
                    .frame(width: 1, height: thumbHeight)
                    .scaleEffect(x: inverseScaleX, y: 1.0)
                    .offset(x: inX)
                    .allowsHitTesting(false)

                // OUT点の縦線
                Rectangle()
                    .fill(trimHandleColor)
                    .frame(width: 1, height: thumbHeight)
                    .scaleEffect(x: inverseScaleX, y: 1.0)
                    .offset(x: outX - 1)
                    .allowsHitTesting(false)
            }
            .frame(width: width, height: thumbHeight)
        }
    }

    /// Photos風ハンドルバー：黄色塗り + シェブロン
    private func handleBar(isLeading: Bool) -> some View {
        let bgColor = trimHandleColor
        let chevronColor: Color = .black.opacity(0.4)
        return RoundedRectangle(cornerRadius: 4)
            .fill(bgColor)
            .overlay(
                Image(systemName: isLeading ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundColor(chevronColor)
            )
            // タッチ領域をハンドル幅の3倍に拡大（ズーム時でも押しやすくする）
            .contentShape(Rectangle().inset(by: -20))
    }

    // MARK: サムネイルコンテンツ共通

    @ViewBuilder
    private func thumbnailContent(width: CGFloat) -> some View {
        let count = max(thumbnails.isEmpty ? 8 : thumbnails.count, 1)
        let tw    = max((width - CGFloat(count - 1)) / CGFloat(count), 1)
        HStack(spacing: 1) {
            if thumbnails.isEmpty {
                ForEach(0..<8, id: \.self) { _ in
                    Rectangle().fill(Color.white.opacity(0.08))
                        .frame(width: tw, height: thumbHeight)
                }
            } else {
                ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, img in
                    Image(uiImage: img).resizable().scaledToFill()
                        .frame(width: tw, height: thumbHeight).clipped()
                }
            }
        }
    }

    // MARK: 斜線パターン（映像データなし領域）

    @ViewBuilder
    private func hatchPattern() -> some View {
        ZStack {
            Color.black.opacity(0.5)
            GeometryReader { g in
                Path { path in
                    let sp: CGFloat = 10
                    var x: CGFloat = -g.size.height
                    while x < g.size.width {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x + g.size.height, y: g.size.height))
                        x += sp
                    }
                }
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
            }
        }
    }

    // MARK: ジェスチャー

    private func inHandleGesture(seg: ClipSegment, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                if draggingID != seg.id {
                    draggingID = seg.id
                    dragStartX = seg.trimInRatio(total: totalDuration) * width
                    print("[TRIM] IN drag START seg=\(seg.id) device=\(deviceName) startX=\(dragStartX)")
                }
                let absX   = dragStartX + v.translation.width
                let ratio  = max(0, min(1, absX / width))
                let newSec = Double(ratio) * totalDuration
                onTrimIn(seg.id, newSec)
            }
            .onEnded { _ in
                print("[TRIM] IN drag END seg=\(draggingID?.uuidString.prefix(8) ?? "nil") device=\(deviceName)")
                draggingID = nil
                dragStartX = 0
                onTrimEnd?()
            }
    }

    private func outHandleGesture(seg: ClipSegment, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                if draggingID != seg.id {
                    draggingID = seg.id
                    dragStartX = seg.trimOutRatio(total: totalDuration) * width
                    print("[TRIM] OUT drag START seg=\(seg.id) device=\(deviceName) startX=\(dragStartX)")
                }
                let absX   = dragStartX + v.translation.width
                let ratio  = max(0, min(1, absX / width))
                let newSec = Double(ratio) * totalDuration
                onTrimOut(seg.id, newSec)
            }
            .onEnded { _ in
                print("[TRIM] OUT drag END seg=\(draggingID?.uuidString.prefix(8) ?? "nil") device=\(deviceName)")
                draggingID = nil
                dragStartX = 0
                onTrimEnd?()
            }
    }


}

// (FillPlayerView / PlayerFillUIView は Metal 移行により削除)

// MARK: - ScrollOffsetKey

/// ScrollView のコンテンツオフセットを PreferenceKey で親に伝えるためのキー
private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - ZoomBarWidthKey

/// ズームバーの実幅を PreferenceKey で取得する
private struct ZoomBarWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 350
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Comparable + clamped

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Canvas Preview

#if DEBUG
#Preview("Cinema 2.39:1 - 2 devices") {
    PreviewView(
        sessionID: "preview-cinema",
        videos: PreviewView.dummyVideos(devices: ["あいぱ", "節子みに"]),
        sessionTitle: "UNTITLED",
        desiredOrientation: .cinema
    )
}

#Preview("TV 16:9 - 3 devices") {
    PreviewView(
        sessionID: "preview-tv",
        videos: PreviewView.dummyVideos(devices: ["iPhone 15", "iPad Pro", "GoPro"]),
        sessionTitle: "TV SHOOT",
        desiredOrientation: .landscape
    )
}

#Preview("Portrait 9:16 - 1 device") {
    PreviewView(
        sessionID: "preview-portrait",
        videos: PreviewView.dummyVideos(devices: ["iPhone 15"]),
        sessionTitle: "VERTICAL",
        desiredOrientation: .portrait
    )
}
#endif

