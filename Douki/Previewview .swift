//
//  PreviewView.swift
//  Douki
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
    private var _displayAspectRatio: CGFloat? = nil
    private var _filterIntensity: Float = 1.0
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
        let displayAspectRatio: CGFloat?
        let filterIntensity: Float
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
        rotationAngle: Float = 0,
        displayAspectRatio: CGFloat? = nil,
        filterIntensity: Float = 1.0
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
        _displayAspectRatio = displayAspectRatio
        _filterIntensity = filterIntensity
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
            displayAspectRatio: _displayAspectRatio,
            filterIntensity: _filterIntensity,
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
    /// グローバル無音フラグ（NO SOUND 選択時 true。onSegmentAudioChange が volume を戻すのを防ぐ）
    var isGlobalNoSound: Bool = false

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
    /// 表示アスペクト比（ミラーフィルタの可視領域計算用）
    var displayAspectRatio: CGFloat? = nil
    /// セグメント切り替え時の pitch / noSound 変更を View 側に通知するコールバック
    /// （PlaybackController は AVAudioEngine を直接持つが、View 側のグローバル pitch との
    ///   調整が必要なため View に委譲する）
    var onSegmentAudioChange: ((_ pitchCents: Float, _ noSound: Bool) -> Void)? = nil

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

            // AVAssetExportSession がオーディオを書き出せるよう、
            // AVAudioSession を一時的に非アクティブ化してから再アクティブ化する
            let audioSession = AVAudioSession.sharedInstance()
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)

            let asset = AVURLAsset(url: videoURL)
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                print("[PITCH] Could not create export session")
                try? audioSession.setActive(true)
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

            // エクスポート完了後にオーディオセッションを再アクティブ化
            try? audioSession.setActive(true)

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
    func applyVideoFilter(filterName: String?, kaleidoscopeType: String?, kaleidoscopeSize: Float, centerX: Float = 0.5, centerY: Float = 0.5, tileHeight: Float = 200, mirrorDirection: Int = 0, rotationAngle: Float = 0, filterIntensity: Float = 1.0) {
        filterParamsHolder.update(
            videoFilter: filterName,
            kaleidoscopeType: kaleidoscopeType,
            kaleidoscopeSize: kaleidoscopeSize,
            centerX: centerX,
            centerY: centerY,
            tileHeight: tileHeight,
            mirrorDirection: mirrorDirection,
            rotationAngle: rotationAngle,
            displayAspectRatio: displayAspectRatio,
            filterIntensity: filterIntensity
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

        // セグメント固有設定とグローバル設定をマージ:
        // セグメント設定がある場合、nil の videoFilter / kaleidoscopeType は
        // グローバル設定にフォールバックする。これにより FILTER と EFFECTER を
        // 別々のスコープで設定した場合でも両方が正しく反映される。
        let settings: SegmentFilterSettings
        if let seg = segmentFilterSettings[segmentID] {
            let g = globalFilterSettings
            // kaleidoscope 設定: セグメントが nil のときはグローバル側の設定を使用
            let effectiveKaleido = seg.kaleidoscopeType ?? g.kaleidoscopeType
            let kaleidoSource = seg.kaleidoscopeType != nil ? seg : g
            settings = SegmentFilterSettings(
                videoFilter: seg.videoFilter ?? g.videoFilter,
                kaleidoscopeType: effectiveKaleido,
                kaleidoscopeSize: kaleidoSource.kaleidoscopeSize,
                kaleidoscopeCenterX: kaleidoSource.kaleidoscopeCenterX,
                kaleidoscopeCenterY: kaleidoSource.kaleidoscopeCenterY,
                tileHeight: kaleidoSource.tileHeight,
                mirrorDirection: kaleidoSource.mirrorDirection,
                rotationAngle: kaleidoSource.rotationAngle,
                autoRotateSpeed: kaleidoSource.autoRotateSpeed,
                speedRate: seg.speedRate != 1.0 ? seg.speedRate : g.speedRate,
                filterIntensity: seg.videoFilter != nil ? seg.filterIntensity : g.filterIntensity,
                pitchCents: seg.pitchCents,
                noSound: seg.noSound
            )
        } else {
            settings = globalFilterSettings
        }

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
            rotationAngle: settings.rotationAngle,
            displayAspectRatio: displayAspectRatio,
            filterIntensity: settings.filterIntensity
        )

        // セグメント単位の pitch / noSound を View に通知（グローバル値との調整は View 側で行う）
        let segPitch = settings.pitchCents
        let segNoSound = settings.noSound
        onSegmentAudioChange?(segPitch, segNoSound)
    }

    /// フィルタ設定変更時に呼ぶ（lastAppliedFilterSegID をリセットして再適用を強制）
    func invalidateFilterCache() {
        lastAppliedFilterSegID = nil
        filterGeneration += 1
    }

    /// CIFilter 適用ヘルパー（プレビュー・エクスポート共通）
    /// centerX/centerY は 0.0〜1.0 の正規化値（0.5 = 映像中央）
    nonisolated static func applyFilters(to image: CIImage, videoFilter: String?, kaleidoscopeType: String?, kaleidoscopeSize: Float, centerX: Float = 0.5, centerY: Float = 0.5, tileHeight: Float = 200, mirrorDirection: Int = 0, rotationAngle: Float = 0, displayAspectRatio: CGFloat? = nil, filterIntensity: Float = 1.0) -> CIImage {
        var result = image
        let extent = image.extent
        let originalBeforeFilter = image  // フィルタ強度ブレンド用に元画像を保持

        // 通常フィルタ
        if let filterName = videoFilter {
            switch filterName {

            // ── 超ビビッド: 彩度+コントラストを大幅に強調 ──
            case "custom_vivid":
                // intensity に応じて彩度・コントラストをスケール（1.0=ベース, 2.0=最大サイケ）
                let vividSat = 1.0 + 2.5 * Double(filterIntensity)   // 3.5 @ intensity=1.0, 6.0 @ intensity=2.0
                let vividCon = 1.0 + 0.4 * Double(filterIntensity)   // 1.4 @ 1.0, 1.8 @ 2.0
                if let satFilter = CIFilter(name: "CIColorControls") {
                    satFilter.setValue(result, forKey: kCIInputImageKey)
                    satFilter.setValue(vividSat, forKey: "inputSaturation")
                    satFilter.setValue(vividCon, forKey: "inputContrast")
                    satFilter.setValue(0.03, forKey: "inputBrightness")
                    if let out = satFilter.outputImage {
                        result = out.cropped(to: extent)
                    }
                }
                // intensity > 0.3 でさらにバイブランスを追加してサイケ感を増強
                if filterIntensity > 0.3, let vib = CIFilter(name: "CIVibrance") {
                    vib.setValue(result, forKey: kCIInputImageKey)
                    vib.setValue(NSNumber(value: Double(filterIntensity) * 1.5), forKey: "inputAmount")
                    if let out = vib.outputImage {
                        result = out.cropped(to: extent)
                    }
                }

            // ── 漫画風: エッジ検出 + ポスタライズの組み合わせ ──
            case "custom_comic":
                // intensity に応じてポスタライズの色数を変化（強いほど少ない色数 = よりポップ）
                let comicLevels = max(2.0, 6.0 - Double(filterIntensity) * 2.5) // 3.5 @ 1.0, 1.0 @ 2.0 → clamped to 2
                // ステップ1: ポスタライズで色数を減らす
                if let poster = CIFilter(name: "CIColorPosterize") {
                    poster.setValue(result, forKey: kCIInputImageKey)
                    poster.setValue(comicLevels, forKey: "inputLevels")
                    if let out = poster.outputImage {
                        result = out.cropped(to: extent)
                    }
                }
                // ステップ2: エッジ検出でアウトラインを生成（intensity に応じてエッジを強調）
                let comicEdgeIntensity = 2.0 + Double(filterIntensity) * 4.0  // 6.0 @ 1.0, 10.0 @ 2.0
                let originalForEdge = result
                if let edges = CIFilter(name: "CIEdges") {
                    edges.setValue(originalForEdge, forKey: kCIInputImageKey)
                    edges.setValue(comicEdgeIntensity, forKey: "inputIntensity")
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
                // intensity が高いほど少ない色数 = よりサイケ・ポップ（最小2色）
                let posterLevels = max(2.0, 4.0 - Double(filterIntensity) * 1.5) // 2.5 @ 1.0, 1.0 @ 2.0 → clamped to 2
                if let poster = CIFilter(name: "CIColorPosterize") {
                    poster.setValue(result, forKey: kCIInputImageKey)
                    poster.setValue(posterLevels, forKey: "inputLevels")
                    if let out = poster.outputImage {
                        result = out.cropped(to: extent)
                    }
                }

            // ── Bloom: 光がにじむ効果（intensity に応じてにじみ半径・強度を増大）──
            case "CIBloom":
                let bloomRadius = 10.0 + Double(filterIntensity) * 30.0  // 40.0 @ 1.0, 70.0 @ 2.0
                let bloomIntensity = 0.8 + Double(filterIntensity) * 0.7 // 1.5 @ 1.0, 2.2 @ 2.0
                if let bloom = CIFilter(name: "CIBloom") {
                    bloom.setValue(result, forKey: kCIInputImageKey)
                    bloom.setValue(bloomRadius, forKey: "inputRadius")
                    bloom.setValue(bloomIntensity, forKey: "inputIntensity")
                    if let out = bloom.outputImage {
                        result = out.cropped(to: extent)
                    }
                }

            // ── サーマル: 赤外線カメラ風の疑似カラー ──
            case "CIFalseColor":
                if let fc = CIFilter(name: "CIFalseColor") {
                    fc.setValue(result, forKey: kCIInputImageKey)
                    fc.setValue(CIColor(red: 0.1, green: 0.0, blue: 0.5), forKey: "inputColor0")  // 暗部: 濃い青紫
                    fc.setValue(CIColor(red: 1.0, green: 0.85, blue: 0.0), forKey: "inputColor1") // 明部: 黄橙
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

            // フィルタ強度ブレンド
            if filterIntensity < 1.0 {
                // intensity < 1.0: 元画像と混合して弱める
                // CIDissolveTransition: inputTime=0 → フィルタ済, inputTime=1 → 元画像
                let blended = result.applyingFilter("CIDissolveTransition", parameters: [
                    "inputTargetImage": originalBeforeFilter,
                    "inputTime": NSNumber(value: Double(1.0 - filterIntensity))
                ])
                result = blended.cropped(to: extent)
            } else if filterIntensity > 1.0 {
                // intensity > 1.0: コントラスト・彩度をブーストして効果を強化
                // VIVID/BLOOM/COMIC/POSTERIZE は既に intensity 直接使用なので標準フィルター向け
                let boost = Double(filterIntensity) - 1.0  // 0.0〜1.0
                if let boost_filter = CIFilter(name: "CIColorControls") {
                    boost_filter.setValue(result, forKey: kCIInputImageKey)
                    boost_filter.setValue(1.0 + boost * 1.5, forKey: "inputSaturation")   // 最大 2.5x
                    boost_filter.setValue(1.0 + boost * 0.5, forKey: "inputContrast")     // 最大 1.5x
                    if let out = boost_filter.outputImage {
                        result = out.cropped(to: extent)
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
                // mirrorDirection: 0=Vertical-L, 1=Vertical-R, 2=Horizon-T, 3=Horizon-B
                let ox = extent.origin.x
                let oy = extent.origin.y
                let ew = extent.width
                let eh = extent.height

                // aspect-fill表示で見えている領域を計算
                // displayAspectRatio が指定されている場合、CIImageのextentとの
                // アスペクト比の差分から可視領域のオフセットとサイズを求める
                let visibleRect: CGRect
                if let dar = displayAspectRatio, ew > 0, eh > 0 {
                    let imageAR = ew / eh
                    if imageAR > dar {
                        // 画像が横に広い → 左右クリップ、上下は全部見える
                        let visW = eh * dar
                        let visX = ox + (ew - visW) / 2
                        visibleRect = CGRect(x: visX, y: oy, width: visW, height: eh)
                    } else if imageAR < dar {
                        // 画像が縦に長い → 上下クリップ、左右は全部見える
                        let visH = ew / dar
                        let visY = oy + (eh - visH) / 2
                        visibleRect = CGRect(x: ox, y: visY, width: ew, height: visH)
                    } else {
                        visibleRect = extent
                    }
                } else {
                    visibleRect = extent
                }

                if mirrorDirection <= 1 {
                    // ── Vertical: 垂直線ミラー（左右反転） ──
                    let splitX = visibleRect.origin.x + visibleRect.width * CGFloat(centerX)

                    if mirrorDirection == 0 {
                        // L: 左側を保持 → 鏡面反転して右側を繰り返し埋める
                        let keepW = splitX - ox
                        guard keepW > 1 else { break }
                        let keepHalf = result.cropped(to: CGRect(x: ox, y: oy, width: keepW, height: eh))
                        let norm = keepHalf.transformed(by: CGAffineTransform(translationX: -ox, y: -oy))
                        let flippedCopy = norm
                            .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                            .transformed(by: CGAffineTransform(translationX: keepW * 2, y: 0))
                        let pair = norm.composited(over: flippedCopy)
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
                        // R: 右側を保持 → 鏡面反転して左側を繰り返し埋める
                        let keepW = extent.maxX - splitX
                        guard keepW > 1 else { break }
                        let keepHalf = result.cropped(to: CGRect(x: splitX, y: oy, width: keepW, height: eh))
                        let norm = keepHalf.transformed(by: CGAffineTransform(translationX: -splitX, y: -oy))
                        let flippedCopy = norm
                            .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                        let pair = norm.composited(over: flippedCopy)
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
                } else {
                    // ── Horizon: 水平線ミラー（上下反転） ──
                    // 水平ミラー(L/R)のコードをY軸に機械的変換。
                    // CIImage Y は画面と反転なので centerY を反転して
                    // CIImage空間での「下側=画面T側」「上側=画面B側」に揃える。
                    let splitY = visibleRect.origin.y + visibleRect.height * CGFloat(centerY)

                    if mirrorDirection == 2 {
                        // T: 画面上側を保持
                        // CIImage空間: splitY は ciY の位置。画面上＝CIImage下側 → oy〜splitY
                        // (水平Lと同じ: origin側を保持)
                        let keepH = splitY - oy
                        guard keepH > 1 else { break }
                        let keepHalf = result.cropped(to: CGRect(x: ox, y: oy, width: ew, height: keepH))
                        let norm = keepHalf.transformed(by: CGAffineTransform(translationX: -ox, y: -oy))
                        let flippedCopy = norm
                            .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
                            .transformed(by: CGAffineTransform(translationX: 0, y: keepH * 2))
                        let pair = norm.composited(over: flippedCopy)
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
                        // B: 画面下側を保持
                        // CIImage空間: 画面下＝CIImage上側（高Y） → splitY〜maxY
                        //
                        // 目標:
                        //   norm（実像）  → 世界座標 splitY〜maxY（CIImage高Y = 画面下側）
                        //   flipped（鏡像）→ 世界座標 splitY-keepH〜splitY（画面上側）
                        //
                        // pair を正の Y 範囲 (0..2keepH) に構成:
                        //   y=0..keepH     → flipped（鏡像: 画面上側に来る）
                        //   y=keepH..2keepH → norm（実像: 画面下側に来る）
                        // tile offset: splitY - keepH
                        //   flipped → splitY-keepH..splitY ✓
                        //   norm   → splitY..splitY+keepH = maxY ✓
                        let keepH = extent.maxY - splitY
                        guard keepH > 1 else { break }
                        let keepHalf = result.cropped(to: CGRect(x: ox, y: splitY, width: ew, height: keepH))
                        // norm を原点へ移動 (y=0..keepH)
                        let norm = keepHalf.transformed(by: CGAffineTransform(translationX: -ox, y: -splitY))
                        // norm を Y 反転して y=keepH..2keepH にシフト → flipped
                        let normShifted = norm.transformed(by: CGAffineTransform(translationX: 0, y: keepH))
                        let flippedCopy = norm
                            .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
                            .transformed(by: CGAffineTransform(translationX: 0, y: keepH))
                        // pair: flipped(0..keepH) + norm(keepH..2keepH)
                        let pair = flippedCopy.composited(over: normShifted)
                        if let tile = CIFilter(name: "CIAffineTile") {
                            tile.setValue(pair, forKey: kCIInputImageKey)
                            tile.setValue(NSValue(cgAffineTransform: .identity), forKey: "inputTransform")
                            if let tiled = tile.outputImage {
                                result = tiled
                                    .transformed(by: CGAffineTransform(translationX: ox, y: splitY - keepH))
                                    .cropped(to: extent)
                            }
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

    /// スクラブ中のスロットル付きシーク（30ms間隔、tolerant seek で軽量化）
    private var lastScrubSeekTime: CFAbsoluteTime = 0
    func throttledSeekForScrub(to seconds: Double, timeline: ExclusiveEditTimeline, selectedDevice: String) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastScrubSeekTime >= 0.03 else { return }
        lastScrubSeekTime = now
        scrubSeek(to: seconds, timeline: timeline, selectedDevice: selectedDevice)
    }

    /// スクラブ専用シーク — tolerant seek で高速（正確なフレームではなく近似位置へ）
    private func scrubSeek(to seconds: Double, timeline: ExclusiveEditTimeline, selectedDevice: String) {
        guard timeline.totalDuration > 0 else { return }
        if let device = timeline.activeDevice(at: seconds),
           let seg = timeline.segments(for: device)
            .filter({ $0.isValid })
            .first(where: { $0.trimIn <= seconds && seconds < $0.trimOut }) {
            let srcTime = seg.sourceInTime + (seconds - seg.trimIn)
            if activePreviewDevice != device {
                pausePlayer(for: activePreviewDevice)
                activePreviewDevice = device
            }
            applyFilterForSegment(segmentID: seg.id, device: device)
            let target = CMTimeMakeWithSeconds(srcTime, preferredTimescale: 600)
            // tolerant seek: iフレームまでの近似シークで高速
            let tolerance = CMTimeMakeWithSeconds(0.2, preferredTimescale: 600)
            players[device]?.seek(
                to: target,
                toleranceBefore: tolerance,
                toleranceAfter: tolerance
            )
        } else {
            pauseAllPlayers()
            activePreviewDevice = ""
        }
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
        // LOOP 先頭に戻る際、先頭セグメントのフィルタ・速度を再適用する
        // （lastAppliedFilterSegID をリセットしてキャッシュを無効化）
        lastAppliedFilterSegID = nil
        applyFilterForSegment(segmentID: first.seg.id, device: first.device)
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
                // 再生開始時にそのセグメントのフィルタ・速度を適用する
                applyFilterForSegment(segmentID: current.seg.id, device: current.device)
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
    var onSaveEditState: ((_ segments: [String: [ClipSegment]], _ lockedDevices: Set<String>, _ audioDevice: String?, _ videoFilter: String?, _ pitchCents: Float, _ kaleidoscope: String?, _ kaleidoscopeSize: Float, _ kaleidoscopeCenterX: Float, _ kaleidoscopeCenterY: Float, _ tileHeight: Float, _ playbackSpeed: Float, _ filterIntensity: Float, _ segmentFilterSettings: [UUID: SegmentFilterSettings]) -> Void)? = nil
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
    /// 保存済みのフィルタ強度
    var savedFilterIntensity: Float = 1.0
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
    /// 各デバイスがオーディオトラックを持つかどうか（SINGLE MODE で片方のみの場合の非活性判定）
    @State private var deviceHasAudio: [String: Bool] = [:]
    @State private var waveformData: [String: [Float]] = [:]
    /// タイムライントラック縦ページ（3台以上時、0-indexed）
    @State private var trackPage: Int = 0

    // MARK: - Device Lock
    /// ロックパネル表示中のデバイス名（nil = 非表示）
    @State private var lockPopoverDevice: String? = nil

    // MARK: - Video Filter
    @State private var selectedFilter: String? = nil
    @State private var filterIntensity: Float = 1.0
    @State private var showFilterSheet: Bool = false
    @State private var filterSheetTab: Int = 0
    @State private var selectedKaleidoscope: String? = nil
    @State private var kaleidoscopeSize: Float = 200
    /// 万華鏡中心位置（0.0〜1.0 正規化、0.5 = 中央）
    @State private var kaleidoscopeCenterX: Float = 0.5
    @State private var kaleidoscopeCenterY: Float = 0.5
    /// TILEフィルタ用の縦幅（kaleidoscopeSize が横幅）
    @State private var tileHeight: Float = 200
    /// MIRROR用の反転方向（0=Vertical-L, 1=Vertical-R, 2=Horizon-T, 3=Horizon-B）
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
        ("SEPIA",     "paintpalette",             "CISepiaTone"),
        ("VIVID",     "paintbrush.pointed.fill",  "custom_vivid"),
        ("INVERT",    "arrow.triangle.swap",      "CIColorInvert"),
        ("COMIC",     "book.fill",                "custom_comic"),
        ("POSTERIZE", "square.stack.3d.up.fill",  "custom_posterize"),
        ("BLOOM",     "light.max",                "CIBloom"),
        ("INSTANT",   "camera.fill",              "CIPhotoEffectInstant"),
        ("PROCESS",   "gearshape",                "CIPhotoEffectProcess"),
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
    /// レイアウトに反映済みのズーム倍率
    /// ピンチ中は更新せず、ピンチ終了時にまとめて反映
    @State private var committedZoomScale: CGFloat = 1.0
    /// タイムライン表示領域の実幅（ズーム前・ラベル除く）
    @State private var baseTrackWidth: CGFloat = 1

    // MARK: - Fixed Playhead / Offset-based Timeline
    /// ユーザーがタイムラインをドラッグ中か
    @State private var isTimelineDragging: Bool = false
    /// ドラッグ開始時の playheadTime スナップショット
    @State private var dragStartPlayheadTime: Double = 0
    /// トリム開始時の playheadTime（トリム中はタイムラインを固定するため）
    @State private var trimAnchorTime: Double = 0
    /// スクラブ中のオフセット直接制御（@Published 経由を回避し、View再構築でジェスチャーが途切れるのを防ぐ）
    @State private var scrubTime: Double? = nil
    /// トリム操作のスロットル制御（セグメントデータ更新 + View再構築の頻度制限）
    @State private var lastTrimUpdateTime: CFAbsoluteTime = 0

    /// ズーム済みのコンテンツ全体幅
    private var contentWidth: CGFloat {
        let w = baseTrackWidth * committedZoomScale
        return max(w, baseTrackWidth, 1) // 0を防ぐ
    }
    /// タイムラインスクロール用のオフセット
    /// 優先順位: scrubTime（スクラブ中）> trimAnchorTime（トリム編集中）> playheadTime（通常）
    private var playheadOffset: CGFloat {
        guard totalDuration > 0 else { return 0 }
        let time: Double
        if let st = scrubTime {
            // スクラブ中: @State で制御（@Published 経由の View 再構築を回避）
            time = st
        } else if playback.isTrimming || !editingDevices.isEmpty {
            // トリム編集中: アンカー位置で固定
            time = trimAnchorTime
        } else {
            // 通常: playheadTime に追従
            time = playback.playheadTime
        }
        // トラック実描画領域はパディング分だけ狭い (leading: trackInnerPad, trailing: 12)
        // コンテンツブロック内でのトラック位置: trackInnerPad + ratio * trackDrawW
        let trackDrawW = contentWidth - trackInnerPad - 12
        return trackInnerPad + CGFloat(time / totalDuration) * trackDrawW
    }

    private var sortedDevices: [String] { videos.keys.sorted() }
    private var totalDuration: Double { timeline.totalDuration }

    /// ズームレベルに応じた時間ルーラーの目盛り間隔
    /// - Returns: (majorInterval: 大目盛りの秒数, minorCount: 大目盛り間の小目盛り数)
    private var rulerTickInterval: (major: Double, minor: Int) {
        guard totalDuration > 0, contentWidth > 0 else { return (1.0, 2) }
        let pxPerSec = contentWidth / totalDuration
        // 大目盛りが画面上で約80px間隔になるよう計算
        let targetSpacingPx: CGFloat = 80
        let rawInterval = Double(targetSpacingPx / pxPerSec)
        let niceIntervals: [(interval: Double, minorCount: Int)] = [
            (0.1,  2), (0.2,  2), (0.5,  5), (1.0,  2), (2.0,  2), (5.0,  5),
            (10.0, 2), (15.0, 3), (30.0, 3), (60.0, 6),
            (120.0, 2), (300.0, 5),
        ]
        for nice in niceIntervals {
            if nice.interval >= rawInterval { return (major: nice.interval, minor: nice.minorCount) }
        }
        let last = niceIntervals.last!
        return (major: last.interval, minor: last.minorCount)
    }

    /// 編集タイムラインに従って合成された最終出力波形
    /// 各時点でアクティブなデバイスの波形データをマッピングして1本の波形にする
    private var compositedWaveform: [Float] {
        let sampleCount = 300
        guard totalDuration > 0 else { return [] }
        // waveformData が空なら空配列を返す
        guard !waveformData.isEmpty else { return [] }
        // NO SOUND 選択時はフラット波形（ゼロ埋め）を返す
        if audioSource == "NO_SOUND" {
            return [Float](repeating: 0, count: sampleCount)
        }

        var result = [Float](repeating: 0, count: sampleCount)
        let allSegs = allSegmentsSorted()
        guard !allSegs.isEmpty else { return [] }

        for i in 0..<sampleCount {
            let timelineSec = totalDuration * Double(i) / Double(sampleCount)
            // この時点でアクティブなセグメントを探す
            guard let entry = allSegs.first(where: { $0.seg.trimIn <= timelineSec && timelineSec < $0.seg.trimOut }),
                  let deviceSamples = waveformData[entry.device],
                  !deviceSamples.isEmpty else {
                continue // セグメント外 = 無音
            }
            // タイムライン時刻 → ソースファイル内時刻 → 波形サンプルインデックス
            let sourceSec = entry.seg.sourceInTime + (timelineSec - entry.seg.trimIn)
            let deviceDuration = timeline.videoRangeByDevice[entry.device]?.duration ?? totalDuration
            guard deviceDuration > 0 else { continue }
            let sampleIndex = Int(sourceSec / deviceDuration * Double(deviceSamples.count))
            let clampedIndex = max(0, min(deviceSamples.count - 1, sampleIndex))
            result[i] = deviceSamples[clampedIndex]
        }
        return result
    }

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

                    let screenH = max(geo.size.height, 1)
                    // 下セクション高さ = 画面の50%（タイムライン操作エリアを広く確保）
                    let bottomH = screenH * 0.50
                    let previewH = max(screenH - safeTop - 44 - bottomH, 1)

                    VStack(spacing: 0) {
                        // ステータスバー領域
                        Color.clear
                            .frame(height: safeTop)

                        headerBar
                            .frame(height: 44)

                        // プレビュー = 残りスペース
                        previewArea
                            .frame(height: previewH)

                        // 下セクション: タイムライン + コントロール = 画面の50%
                        VStack(spacing: 0) {
                            timelineSection
                                .frame(maxHeight: .infinity)
                            playbackControls
                        }
                        .frame(height: bottomH)
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
            onSaveEditState?(timeline.segmentsByDevice, timeline.lockedDevices, audioSource, selectedFilter, pitchShiftCents, selectedKaleidoscope, kaleidoscopeSize, kaleidoscopeCenterX, kaleidoscopeCenterY, tileHeight, playbackSpeed, filterIntensity, segmentFilterSettings)
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
            speedRate: playbackSpeed,
            pitchCents: pitchShiftCents
        )
    }

    /// プレビュー右下のリアルタイムフィルタステータス表示
    @ViewBuilder
    private var filterStatusOverlay: some View {
        let s = playheadFilterSettings
        let hasFilter = s.videoFilter != nil
        let hasMirror = s.kaleidoscopeType != nil
        let hasSpeed = s.speedRate != 1.0
        let hasPitch = s.pitchCents != 0
        let hasNoSound = s.noSound
        if hasFilter || hasMirror || hasSpeed || hasPitch || hasNoSound {
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
                if hasPitch {
                    Text("PITCH:\(s.pitchCents > 0 ? "+" : "")\(Int(s.pitchCents))ct")
                }
                if hasNoSound {
                    Text("NO SOUND")
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
                            if shape == .mirror { return }  // ミラーは専用ドラッグで制御
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
                    if shape == .mirror { return }  // ミラーは専用ドラッグで制御
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
                if effectiveMirrorDirection <= 1 {
                    // 水平ミラー: 境界の縦線（centerX で位置を制御）
                    let lineX = cx
                    Path { path in
                        path.move(to: CGPoint(x: lineX, y: 0))
                        path.addLine(to: CGPoint(x: lineX, y: boxSize.height))
                    }
                    .stroke(Color.yellow, lineWidth: 0.5)
                    .allowsHitTesting(false)

                    // ドラッグで境界線を左右に移動
                    Rectangle()
                        .fill(Color.yellow.opacity(0.01))
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
                } else {
                    // 垂直ミラー: 境界の横線（centerY で位置を制御）
                    let lineY = cy
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: lineY))
                        path.addLine(to: CGPoint(x: boxSize.width, y: lineY))
                    }
                    .stroke(Color.yellow, lineWidth: 0.5)
                    .allowsHitTesting(false)

                    // ドラッグで境界線を上下に移動
                    Rectangle()
                        .fill(Color.yellow.opacity(0.01))
                        .frame(width: boxSize.width, height: 44)
                        .contentShape(Rectangle())
                        .position(x: boxSize.width / 2, y: lineY)
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    let newY = Float(1.0 - value.location.y / boxSize.height).clamped(to: 0.05...0.95)
                                    applyFilterChange(centerY: newY)
                                }
                        )
                }
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
                    let exportAudioSource = audioSource == "NO_SOUND" ? nil : audioSource
                    Task { await exportEngine.export(timeline: timeline, videos: videos, orientation: desiredOrientation, audioSource: exportAudioSource, videoFilter: selectedFilter, showWatermark: !purchaseManager.isPremium, pitchCents: pitchShiftCents, kaleidoscopeType: selectedKaleidoscope, kaleidoscopeSize: kaleidoscopeSize, kaleidoscopeCenterX: kaleidoscopeCenterX, kaleidoscopeCenterY: kaleidoscopeCenterY, tileHeight: tileHeight, mirrorDirection: mirrorDirection, rotationAngle: rotationAngle, filterIntensity: filterIntensity, segmentFilterSettings: segmentFilterSettings, speedRate: playbackSpeed, noSoundExport: audioSource == "NO_SOUND") }
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
        onSaveEditState?(timeline.segmentsByDevice, timeline.lockedDevices, audioSource, selectedFilter, pitchShiftCents, selectedKaleidoscope, kaleidoscopeSize, kaleidoscopeCenterX, kaleidoscopeCenterY, tileHeight, playbackSpeed, filterIntensity, segmentFilterSettings)
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
                if !playback.isTrimming && editingDevices.isEmpty { trimAnchorTime = playback.playheadTime }
                playback.isTrimming = true
                // セグメントデータ更新 + シークをスロットル（View再構築の頻度を抑制）
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastTrimUpdateTime >= 0.05 {
                    lastTrimUpdateTime = now
                    timeline.moveTrimIn(segmentID: segID, device: device, newTrimIn: newSec)
                    let actual = timeline.segments(for: device).first(where: { $0.id == segID })?.trimIn ?? newSec
                    playback.playheadTime = actual
                    playback.seekPreview(to: actual, timeline: timeline, selectedDevice: device)
                }
            },
            onTrimOut: { segID, newSec in
                editingSegmentIDs[device] = segID
                if !playback.isTrimming && editingDevices.isEmpty { trimAnchorTime = playback.playheadTime }
                playback.isTrimming = true
                // セグメントデータ更新 + シークをスロットル（View再構築の頻度を抑制）
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastTrimUpdateTime >= 0.05 {
                    lastTrimUpdateTime = now
                    timeline.moveTrimOut(segmentID: segID, device: device, newTrimOut: newSec)
                    let actual = timeline.segments(for: device).first(where: { $0.id == segID })?.trimOut ?? newSec
                    let previewTime = max(actual - 1.0 / 30.0, 0)
                    playback.playheadTime = previewTime
                    playback.seekPreview(to: previewTime, timeline: timeline, selectedDevice: device)
                }
            },
            onCommitSelection: { trimIn, trimOut in
                print("[GESTURE] commitSelection device=\(device) in=\(String(format: "%.2f", trimIn)) out=\(String(format: "%.2f", trimOut))")
                timeline.applySelection(trimIn: trimIn, trimOut: trimOut, for: device)
                editingDevices.remove(device)
                editingSegmentIDs.removeValue(forKey: device)
            },
            onAddSegment: { seconds, trackWidth in
                print("[GESTURE] addSegment device=\(device) sec=\(String(format: "%.2f", seconds)) trackW=\(String(format: "%.0f", trackWidth)) editing=\(editingDevices)")
                // ── @State の更新を先にまとめる（@Published 発火前にレイアウトを確定） ──
                let prev = selectedDevice
                if device != prev && editingDevices.contains(prev) {
                    editingDevices.remove(prev)
                    editingSegmentIDs.removeValue(forKey: prev)
                }
                previousSelectedDevice = prev
                selectedDevice = device
                playback.activePreviewDevice = device
                trimAnchorTime = playback.playheadTime
                editingDevices.insert(device)
                playback.playheadTime = seconds

                // ── @Published segmentsByDevice の変更は最後（View再描画トリガー） ──
                timeline.addSegment(around: seconds, for: device, trackWidth: trackWidth)
                if let newSeg = timeline.segments(for: device).last {
                    editingSegmentIDs[device] = newSeg.id
                }
                playback.seekPreview(to: seconds, timeline: timeline, selectedDevice: device)
            },
            onTap: {
                print("[GESTURE] tap device=\(device)")
                handleDeviceTap(device)
            },
            onSegmentTap: { segID in
                print("[GESTURE] segmentTap device=\(device) seg=\(segID.uuidString.prefix(8)) editing=\(editingDevices) selected=\(selectedDevice)")
                trimAnchorTime = playback.playheadTime
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
                print("[GESTURE] trimEND device=\(device) isTrimming=\(playback.isTrimming) playhead=\(String(format: "%.2f", playback.playheadTime))")
                // スロットルをリセット（直前の onTrimIn/onTrimOut で最終値が確実に反映されるように）
                lastTrimUpdateTime = 0
                playback.isTrimming = false
                playback.seekPreview(to: playback.playheadTime, timeline: timeline, selectedDevice: selectedDevice)
            }
        )
    }

    private var timelineSection: some View {
        let rowH: CGFloat = 56
        let rulerH: CGFloat = 20
        let waveformH: CGFloat = 20
        let rowCount = sortedDevices.count
        let hasWaveform = !compositedWaveform.isEmpty
        // トラック行の総高さ（行間スペース3pt × (rowCount-1) + 上下パディング各4pt = 8pt + 波形高さ）
        let waveformTotalH: CGFloat = hasWaveform ? waveformH : 0
        let maxVisibleRows = 2
        let needsPaging = rowCount > maxVisibleRows
        // ページングで表示するデバイス（3台以上時のみ）
        let maxPage = needsPaging ? max(rowCount - maxVisibleRows, 0) : 0
        let safePage = min(trackPage, maxPage)
        let visibleDevices: [String] = needsPaging
            ? Array(sortedDevices[safePage..<min(safePage + maxVisibleRows, rowCount)])
            : sortedDevices
        let visibleRowCount = visibleDevices.count
        let visibleTrackAreaH: CGFloat = CGFloat(visibleRowCount) * rowH + waveformTotalH + 3 * CGFloat(max(visibleRowCount - 1, 0)) + 8
        let triangleH: CGFloat = 8  // 固定再生ヘッド三角の高さ

        return HStack(spacing: 0) {
                // ① 固定ラベル列
                VStack(spacing: 0) {
                    // ルーラー分のスペーサー
                    Spacer().frame(height: rulerH)
                    // ページインジケーター（3台以上時）
                    if needsPaging {
                        HStack(spacing: 3) {
                            ForEach(0...maxPage, id: \.self) { p in
                                Circle()
                                    .fill(p == safePage ? Color.white.opacity(0.7) : Color.white.opacity(0.2))
                                    .frame(width: 4, height: 4)
                            }
                        }
                        .frame(height: 8)
                    }
                    VStack(spacing: 3) {
                        // 合成波形ラベル
                        if !compositedWaveform.isEmpty {
                            Image(systemName: "waveform")
                                .font(.system(size: 9))
                                .foregroundColor(.cyan.opacity(0.6))
                                .frame(width: fixedLabelWidth, height: waveformH)
                        }
                        // デバイスラベル（ページに応じて表示）
                        ForEach(visibleDevices, id: \.self) { device in
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
                }
                .padding(.leading, fixedLabelLeading)
                .padding(.bottom, 8)
                .frame(maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .gesture(
                    needsPaging
                    ? DragGesture(minimumDistance: 15)
                        .onEnded { v in
                            let dy = v.translation.height
                            withAnimation(.easeInOut(duration: 0.25)) {
                                if dy < -15 {
                                    trackPage = min(trackPage + 1, maxPage)
                                } else if dy > 15 {
                                    trackPage = max(trackPage - 1, 0)
                                }
                            }
                        }
                    : nil
                )

                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: fixedDividerWidth)
                    .frame(maxHeight: .infinity)

                // ② offset ベースのトラック列（固定再生ヘッド方式）
                GeometryReader { scrollGeo in
                    let viewportW = max(scrollGeo.size.width, 1)
                    // コンテンツの X オフセット: 再生ヘッド位置がビューポート中央に来るようにする
                    // ZStack は水平中央揃え → content の自然な中心は viewportW/2。
                    // .offset(x:) はその中心位置からの相対移動なので、
                    // contentWidth/2 - playheadOffset で再生ヘッド位置がビューポート中央に来る。
                    let offsetX = contentWidth / 2 - playheadOffset

                    // 高さが無効な場合はvisibleTrackAreaHをフォールバックとして使用
                    let fullH = max(scrollGeo.size.height, visibleTrackAreaH + rulerH)
                    // 操作エリア（黒スペース）の高さ
                    let controlAreaH = max(fullH - visibleTrackAreaH - rulerH, 1)

                    VStack(spacing: 0) {
                        // ── タイムルーラー（時間ラベル + 目盛り） ──
                        timeRuler(contentWidth: contentWidth, offsetX: offsetX, viewportW: viewportW,
                                  segments: allSegmentsSorted(), segSettings: segmentFilterSettings)

                        // ── 上部: サムネイル帯（トリム操作専用・スクラブなし） ──
                        ZStack(alignment: .top) {
                            VStack(spacing: 3) {
                                // 最終出力オーディオ波形（編集結果に基づく合成波形）
                                if !compositedWaveform.isEmpty {
                                    WaveformBar(samples: compositedWaveform)
                                        .frame(height: waveformH)
                                }
                                // デバイストラック行（ページに応じて表示）
                                ForEach(visibleDevices, id: \.self) { device in
                                    makeTimelineRow(device: device)
                                }
                            }
                            .padding(.leading, trackInnerPad)
                            .padding(.trailing, 12)
                            .padding(.vertical, 4)
                            .frame(width: contentWidth)
                            .scaleEffect(
                                x: isPinching ? zoomScale / committedZoomScale : 1.0,
                                y: 1.0,
                                anchor: UnitPoint(x: 0.5, y: 0.5)
                            )
                            .offset(x: offsetX)

                            // 再生ヘッド（サムネイル帯部分）
                            fixedPlayheadLine(trackHeight: visibleTrackAreaH)
                                .zIndex(999)
                        }
                        .frame(width: viewportW, height: visibleTrackAreaH)
                        .clipped()

                        // ── 下部: 操作エリア（スクラブ＋ピンチ専用） ──
                        ZStack {
                            // 再生ヘッド線を下まで延長
                            Rectangle()
                                .fill(Color.red)
                                .frame(width: 2, height: controlAreaH)
                                .allowsHitTesting(false)
                        }
                        .frame(width: viewportW, height: controlAreaH)
                        .contentShape(Rectangle())
                        // ── スクラブ（操作エリアのみ） ──
                        .gesture(
                            DragGesture(minimumDistance: 4)
                                .onChanged { v in
                                    // フェイルセーフ: isTrimming 残留リセット
                                    if playback.isTrimming {
                                        playback.isTrimming = false
                                    }
                                    if !isTimelineDragging {
                                        isTimelineDragging = true
                                        dragStartPlayheadTime = playback.playheadTime
                                        // トリム編集状態をクリア — スクラブ開始 = 編集完了
                                        if !editingDevices.isEmpty {
                                            editingDevices.removeAll()
                                            editingSegmentIDs.removeAll()
                                        }
                                        print("[GESTURE] scrub START at=\(String(format: "%.2f", playback.playheadTime))s")
                                    }
                                    let cw = isPinching
                                        ? max(baseTrackWidth * zoomScale - trackInnerPad - 12, 1)
                                        : max(contentWidth - trackInnerPad - 12, 1)
                                    let deltaTime = -Double(v.translation.width / cw) * totalDuration
                                    let newTime = max(0, min(totalDuration, dragStartPlayheadTime + deltaTime))

                                    // @State scrubTime を更新（@Published を経由しないので View 再構築が軽量）
                                    scrubTime = newTime
                                    // AVPlayer seek はスロットル付き tolerant seek
                                    playback.throttledSeekForScrub(to: newTime, timeline: timeline, selectedDevice: selectedDevice)
                                }
                                .onEnded { v in
                                    let cw = isPinching
                                        ? max(baseTrackWidth * zoomScale - trackInnerPad - 12, 1)
                                        : max(contentWidth - trackInnerPad - 12, 1)
                                    let finalTime: Double
                                    if cw > 0 {
                                        let deltaTime = -Double(v.translation.width / cw) * totalDuration
                                        finalTime = max(0, min(totalDuration, dragStartPlayheadTime + deltaTime))
                                    } else {
                                        finalTime = scrubTime ?? playback.playheadTime
                                    }
                                    // scrubTime をクリアし、playheadTime を確定
                                    scrubTime = nil
                                    isTimelineDragging = false
                                    playback.playheadTime = finalTime
                                    print("[GESTURE] scrub END at=\(String(format: "%.2f", finalTime))s")
                                    // ドラッグ終了時に正確な位置へ最終シーク
                                    playback.seekPreview(to: finalTime, timeline: timeline, selectedDevice: selectedDevice)
                                }
                        )
                        // ── ピンチズーム（操作エリアのみ） ──
                        .simultaneousGesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    if !isPinching {
                                        print("[GESTURE] pinch START scale=\(String(format: "%.2f", committedZoomScale))")
                                    }
                                    isPinching = true
                                    let raw = (zoomScaleAtGestureStart * value).clamped(to: 0.5...8.0)
                                    zoomScale = raw
                                    faceSpread = ((raw - 1.0) * 6).clamped(to: -16...6)
                                }
                                .onEnded { _ in
                                    print("[GESTURE] pinch END scale=\(String(format: "%.2f", zoomScale))")
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
                                }
                        )
                    }
                }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { newWidth in
                    if newWidth > 0, abs(baseTrackWidth - newWidth) > 1 {
                        baseTrackWidth = newWidth
                    }
                }
            }
            .frame(minHeight: visibleTrackAreaH + rulerH + triangleH + scrollStripH)
            .background(Color.white.opacity(0.04))
            .contentShape(Rectangle())

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
        playback.displayAspectRatio = desiredOrientation.aspectRatio
    }

    // MARK: - Time Ruler（タイムコードラベル + 目盛り）

    /// 時間ルーラー: コンテンツと同じ offsetX でスクロールし、可視範囲のみ描画
    /// タイムライン秒 t → 実効時間マッピング情報を構築
    /// （SPEED考慮: speed=2x なら 2秒のタイムライン = 1秒の実効時間）
    private func buildEffectiveTimeMap(
        segments: [(device: String, seg: ClipSegment)],
        segSettings: [UUID: SegmentFilterSettings]
    ) -> [(trimIn: Double, trimOut: Double, speed: Double, effectiveStart: Double)] {
        var result: [(trimIn: Double, trimOut: Double, speed: Double, effectiveStart: Double)] = []
        var effectiveCursor: Double = 0
        var lastTrimOut: Double = 0
        for entry in segments {
            let seg = entry.seg
            if seg.trimIn > lastTrimOut { effectiveCursor += (seg.trimIn - lastTrimOut) }
            let speed = Double(segSettings[seg.id]?.speedRate ?? playbackSpeed)
            let effectiveSpeed = speed > 0 ? speed : 1.0
            result.append((trimIn: seg.trimIn, trimOut: seg.trimOut, speed: effectiveSpeed, effectiveStart: effectiveCursor))
            effectiveCursor += seg.trimmedDuration / effectiveSpeed
            lastTrimOut = seg.trimOut
        }
        return result
    }

    private func timeRuler(
        contentWidth: CGFloat,
        offsetX: CGFloat,
        viewportW: CGFloat,
        segments: [(device: String, seg: ClipSegment)] = [],
        segSettings: [UUID: SegmentFilterSettings] = [:]
    ) -> some View {
        let rulerH: CGFloat = 20
        let (majorInterval, minorCount) = rulerTickInterval
        let padL = trackInnerPad  // 8pt
        let padR: CGFloat = 12
        let trackDrawW = contentWidth - padL - padR

        // 実効時間マップを事前計算
        let effMap = buildEffectiveTimeMap(segments: segments, segSettings: segSettings)

        return Canvas { context, size in
            guard totalDuration > 0, trackDrawW > 0 else { return }
            let pxPerSec = trackDrawW / totalDuration
            let contentLeftEdge = viewportW / 2 - contentWidth / 2 + offsetX
            let trackOriginX = contentLeftEdge + padL

            // 可視範囲を算出（カリング用）
            let visibleStartSec = max(0, Double(-trackOriginX / pxPerSec))
            let visibleEndSec = min(totalDuration, Double((-trackOriginX + viewportW) / pxPerSec))
            let firstMajor = floor(visibleStartSec / majorInterval) * majorInterval

            // 大目盛り + ラベル描画
            var t = firstMajor
            while t <= visibleEndSec + majorInterval {
                let x = CGFloat(t) * pxPerSec + trackOriginX

                // 大目盛り線（6pt）
                let tickPath = Path { p in
                    p.move(to: CGPoint(x: x, y: size.height - 6))
                    p.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(tickPath, with: .color(.white.opacity(0.4)), lineWidth: 1)

                // 時間ラベル: speed を考慮した実効時間で表示
                if t >= 0 {
                    let effT: Double
                    if let info = effMap.first(where: { $0.trimIn <= t && t <= $0.trimOut }) {
                        effT = info.effectiveStart + (t - info.trimIn) / info.speed
                    } else if let last = effMap.last(where: { $0.trimOut <= t }) {
                        effT = last.effectiveStart + (last.trimOut - last.trimIn) / last.speed + (t - last.trimOut)
                    } else {
                        effT = t
                    }
                    let label = formatTime(effT, showMillis: majorInterval < 1.0)
                    let text = context.resolve(Text(label)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5)))
                    context.draw(text, at: CGPoint(x: x, y: size.height - 10), anchor: .bottom)
                }

                // 小目盛り
                if minorCount > 1 {
                    let minorInterval = majorInterval / Double(minorCount)
                    for mi in 1..<minorCount {
                        let mt = t + Double(mi) * minorInterval
                        guard mt <= totalDuration else { break }
                        let mx = CGFloat(mt) * pxPerSec + trackOriginX
                        let minorPath = Path { p in
                            p.move(to: CGPoint(x: mx, y: size.height - 3))
                            p.addLine(to: CGPoint(x: mx, y: size.height))
                        }
                        context.stroke(minorPath, with: .color(.white.opacity(0.2)), lineWidth: 0.5)
                    }
                }
                t += majorInterval
            }
        }
        .frame(width: viewportW, height: rulerH)
        .allowsHitTesting(false)
    }

    // MARK: - Fixed Playhead Line（画面中央固定の赤い縦線）

    /// 固定再生ヘッド: ビューポート中央に赤い縦線 + 上部三角インジケータ
    private func fixedPlayheadLine(trackHeight: CGFloat) -> some View {
        let lineW: CGFloat = 2
        let triangleH: CGFloat = 8
        let safeHeight = max(trackHeight, 1) // 0以下を防ぐ（Invalid frame dimension 対策）
        return VStack(spacing: 0) {
            // ── 上部三角インジケータ ──
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 10, y: 0))
                path.addLine(to: CGPoint(x: 5, y: triangleH))
                path.closeSubpath()
            }
            .fill(Color.red)
            .frame(width: 10, height: triangleH)

            // ── 縦ライン ──
            Rectangle()
                .fill(Color.red)
                .frame(width: lineW, height: safeHeight)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Playback Controls

    private var playbackControls: some View {
        VStack(spacing: 20) {
            // ── 時間表示: 経過時間（赤）| 最終出力時間（グレー）──
            let effMap = buildEffectiveTimeMap(segments: allSegmentsSorted(), segSettings: segmentFilterSettings)
            let currentEffTime: Double = {
                let t = scrubTime ?? playback.playheadTime
                if let info = effMap.first(where: { $0.trimIn <= t && t <= $0.trimOut }) {
                    return info.effectiveStart + (t - info.trimIn) / info.speed
                }
                if let last = effMap.last(where: { $0.trimOut <= t }) {
                    return last.effectiveStart + (last.trimOut - last.trimIn) / last.speed + (t - last.trimOut)
                }
                return t
            }()
            let totalEffTime: Double = {
                guard let last = effMap.last else { return totalDuration }
                return last.effectiveStart + (last.trimOut - last.trimIn) / last.speed
            }()
            HStack(spacing: 4) {
                Text(formatTime(currentEffTime, showMillis: false))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.red)
                Text("|")
                    .font(.system(size: 11, weight: .light, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                Text(formatTime(totalEffTime, showMillis: false))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(.top, 2)

            // ── 再生ボタン（中央固定）+ 左右均等配置 ──────────────
            HStack(spacing: 0) {
                // 🎧 音声設定（ソース + ピッチ統合）
                Button {
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
                        .frame(maxWidth: .infinity)
                }

                // |← 先頭に戻る
                Button {
                    editingDevices.removeAll()
                    editingSegmentIDs.removeAll()
                    playback.playheadTime = 0
                    playback.seekPreview(to: 0, timeline: timeline, selectedDevice: selectedDevice)
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                }

                // ▶ 再生/一時停止（中央）
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
                        .font(.system(size: 56)).foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                }

                // →| 末尾付近（95%）に飛ぶ
                Button {
                    editingDevices.removeAll()
                    editingSegmentIDs.removeAll()
                    let target = totalDuration * 0.95
                    playback.playheadTime = target
                    playback.seekPreview(to: target, timeline: timeline, selectedDevice: selectedDevice)
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                }

                // 🎨 フィルタ
                Button {
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
                        .frame(maxWidth: .infinity)
                }
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
                            let hasAudio = deviceHasAudio[device] ?? true
                            Button {
                                audioSource = device
                                applyAudioSource()
                            } label: {
                                HStack {
                                    Image(systemName: hasAudio ? "mic.fill" : "mic.slash.fill")
                                        .foregroundColor(hasAudio ? .white : .white.opacity(0.3))
                                        .frame(width: 28)
                                    Text(device)
                                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                                        .foregroundColor(hasAudio ? .white : .white.opacity(0.3))
                                    Spacer()
                                    if !hasAudio {
                                        Text("NO AUDIO")
                                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.3))
                                    } else if audioSource == device {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.cyan)
                                    }
                                }
                            }
                            .disabled(!hasAudio)
                            .listRowBackground(Color.white.opacity(0.08))
                        }

                        Button {
                            audioSource = "NO_SOUND"
                            applyAudioSource()
                        } label: {
                            HStack {
                                Image(systemName: "speaker.slash.fill")
                                    .foregroundColor(.white)
                                    .frame(width: 28)
                                Text("NO SOUND")
                                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white)
                                Spacer()
                                if audioSource == "NO_SOUND" {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.cyan)
                                }
                            }
                        }
                        .listRowBackground(Color.white.opacity(0.08))
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

    /// 現在の編集スコープに応じた有効フィルタ強度
    private var effectiveFilterIntensity: Float {
        if let segID = filterEditingSegmentID {
            return segmentFilterSettings[segID]?.filterIntensity ?? filterIntensity
        }
        return filterIntensity
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

    /// 現在の編集スコープで有効なピッチ（セント）
    private var effectivePitch: Float {
        if let segID = filterEditingSegmentID {
            return segmentFilterSettings[segID]?.pitchCents ?? pitchShiftCents
        }
        return pitchShiftCents
    }

    /// ピッチ変更をスコープに応じて適用する
    private func applyPitchChange(cents: Float) {
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
            settings.pitchCents = cents
            segmentFilterSettings[segID] = settings
            playback.segmentFilterSettings = segmentFilterSettings
            playback.invalidateFilterCache()
            // 現在そのセグメントが再生中（または停止中にそのセグメント位置）なら即座に反映
            if currentPlayingSegmentID() == segID {
                applySegmentPitchToEngine(cents: cents)
            }
        } else {
            // グローバル
            pitchShiftCents = cents
            applyPitchShift()
        }
    }

    /// セグメント単位のピッチをエンジンに即反映する
    private func applySegmentPitchToEngine(cents: Float) {
        if cents != 0 {
            playback.pitchCents = cents
            for (_, player) in playback.players { player.volume = 0 }
            if playback.isPlaying {
                playback.pitchEnginePause()
                startPitchEngineIfNeeded()
            }
        } else {
            // ピッチOFF → グローバル設定に戻す
            playback.pitchCents = pitchShiftCents
            if pitchShiftCents == 0 {
                playback.stopPitchEngine()
                applyAudioSource()
            }
        }
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
    private func applyFilterChange(videoFilter: String?? = nil, kaleidoscopeType: String?? = nil, kaleidoscopeSize: Float? = nil, centerX: Float? = nil, centerY: Float? = nil, tileHeight: Float? = nil, mirrorDirection: Int? = nil, rotationAngle: Float? = nil, autoRotateSpeed: Float? = nil, filterIntensity: Float? = nil) {
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
                autoRotateSpeed: isAutoRotating ? self.autoRotateSpeed : 0,
                filterIntensity: self.filterIntensity
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
            if let fi = filterIntensity { settings.filterIntensity = fi }
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
                rotationAngle: settings.rotationAngle,
                filterIntensity: settings.filterIntensity
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
            if let fi = filterIntensity { self.filterIntensity = fi }
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
                autoRotateSpeed: isAutoRotating ? self.autoRotateSpeed : 0,
                filterIntensity: self.filterIntensity
            )
            playback.invalidateFilterCache()
            playback.applyVideoFilter(filterName: selectedFilter, kaleidoscopeType: selectedKaleidoscope, kaleidoscopeSize: self.kaleidoscopeSize, centerX: self.kaleidoscopeCenterX, centerY: self.kaleidoscopeCenterY, tileHeight: self.tileHeight, mirrorDirection: self.mirrorDirection, rotationAngle: self.rotationAngle, filterIntensity: self.filterIntensity)
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
                    Text("PITCH").tag(3)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)

                if filterSheetTab == 0 {
                    // ── FILTER タブ ──
                    List {
                        ForEach(Self.videoFilters, id: \.label) { filter in
                            Button {
                                // フィルタ切り替え時は強度を 100% にリセット
                                if filter.ciName != effectiveFilter {
                                    applyFilterChange(videoFilter: .some(filter.ciName), filterIntensity: 1.0)
                                } else {
                                    applyFilterChange(videoFilter: .some(filter.ciName))
                                }
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
                            // ── INTENSITY スライダー（選択中フィルタの直下に表示）──
                            if effectiveFilter == filter.ciName, filter.ciName != nil {
                                HStack(spacing: 12) {
                                    Text("INTENSITY")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundColor(.gray)
                                    Slider(
                                        value: Binding(
                                            get: { effectiveFilterIntensity },
                                            set: { applyFilterChange(filterIntensity: $0) }
                                        ),
                                        in: 0.0...2.0,
                                        step: 0.05
                                    )
                                    .tint(effectiveFilterIntensity > 1.0 ? .orange : .cyan)
                                    Text(effectiveFilterIntensity > 1.0
                                         ? String(format: "×%.1f", effectiveFilterIntensity)
                                         : "\(Int(effectiveFilterIntensity * 100))%")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundColor(effectiveFilterIntensity > 1.0 ? .orange : .white)
                                        .frame(width: 40, alignment: .trailing)
                                }
                                .padding(.vertical, 4)
                                .listRowBackground(Color.white.opacity(0.04))
                            }
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
                                    // MIRROR: 軸選択（Vertical=垂直線で左右反転 / Horizon=水平線で上下反転）
                                    HStack(spacing: 12) {
                                        Text("AXIS")
                                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                                            .foregroundColor(.yellow)
                                        Spacer()
                                        Button {
                                            // 垂直鏡面線（左右反転）: direction 0 or 1
                                            if effectiveMirrorDirection >= 2 {
                                                applyFilterChange(mirrorDirection: 0)
                                            }
                                        } label: {
                                            Text("Vertical")
                                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                                .frame(width: 72, height: 32)
                                                .background(effectiveMirrorDirection <= 1 ? Color.yellow : Color.white.opacity(0.15))
                                                .foregroundColor(effectiveMirrorDirection <= 1 ? .black : .white.opacity(0.7))
                                                .clipShape(Capsule())
                                        }
                                        .buttonStyle(.borderless)
                                        Button {
                                            // 水平鏡面線（上下反転）: direction 2 or 3
                                            if effectiveMirrorDirection <= 1 {
                                                applyFilterChange(mirrorDirection: 2)
                                            }
                                        } label: {
                                            Text("Horizon")
                                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                                .frame(width: 72, height: 32)
                                                .background(effectiveMirrorDirection >= 2 ? Color.yellow : Color.white.opacity(0.15))
                                                .foregroundColor(effectiveMirrorDirection >= 2 ? .black : .white.opacity(0.7))
                                                .clipShape(Capsule())
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                    .listRowBackground(Color.white.opacity(0.08))

                                    // MIRROR: FLIP 切り替えボタン（軸に応じて L/R or T/B）
                                    HStack(spacing: 12) {
                                        Text("FLIP")
                                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                                            .foregroundColor(.yellow)
                                        Spacer()
                                        if effectiveMirrorDirection <= 1 {
                                            // 水平: L / R
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
                                        } else {
                                            // 垂直: T / B
                                            Button {
                                                applyFilterChange(mirrorDirection: 2)
                                            } label: {
                                                Text("T")
                                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                                    .frame(width: 40, height: 32)
                                                    .background(effectiveMirrorDirection == 2 ? Color.yellow : Color.white.opacity(0.15))
                                                    .foregroundColor(effectiveMirrorDirection == 2 ? .black : .white.opacity(0.7))
                                                    .clipShape(Capsule())
                                            }
                                            .buttonStyle(.borderless)
                                            Button {
                                                applyFilterChange(mirrorDirection: 3)
                                            } label: {
                                                Text("B")
                                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                                    .frame(width: 40, height: 32)
                                                    .background(effectiveMirrorDirection == 3 ? Color.yellow : Color.white.opacity(0.15))
                                                    .foregroundColor(effectiveMirrorDirection == 3 ? .black : .white.opacity(0.7))
                                                    .clipShape(Capsule())
                                            }
                                            .buttonStyle(.borderless)
                                        }
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
                } else if filterSheetTab == 2 {
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
                } else {
                    // ── PITCH タブ ──
                    List {
                        ForEach(Self.pitchPresets, id: \.cents) { preset in
                            Button {
                                applyPitchChange(cents: preset.cents)
                            } label: {
                                HStack {
                                    Image(systemName: preset.cents > 0 ? "arrow.up" : preset.cents < 0 ? "arrow.down" : "equal")
                                        .foregroundColor(.white)
                                        .frame(width: 28)
                                    Text(preset.label)
                                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                                        .foregroundColor(.white)
                                    Spacer()
                                    if effectivePitch == preset.cents {
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
        // NO_SOUND の場合は全ミュート
        if audioSource == "NO_SOUND" {
            playback.isGlobalNoSound = true
            playback.audioSourceDevice = nil
            for (_, player) in playback.players {
                player.volume = 0.0
            }
            playback.pauseAudioSource()
            return
        }
        // NO_SOUND 以外に切り替わった場合はフラグを解除
        playback.isGlobalNoSound = false

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

    /// ピンチジェスチャー中フラグ
    @State private var isPinching: Bool = false
    /// 顔アニメーション用の独立したスプレッド値（スナップバック時にzoomScaleと独立して動く）
    @State private var faceSpread: CGFloat = 0

    /// mm:ss 形式にフォーマット
    private func formatTime(_ seconds: Double, showMillis: Bool = false) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        if showMillis {
            let ms = Int((seconds - Double(total)) * 10)  // 0.1秒単位
            return String(format: "%d:%02d.%d", m, s, ms)
        }
        return String(format: "%d:%02d", m, s)
    }

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
        // 撮影後のオーディオセッションを再生用に切り替え（録画中は .playAndRecord になっている）
        // AVAudioSession の同期呼び出しはメインスレッドをブロックするため、バックグラウンドで実行
        await Task.detached(priority: .userInitiated) {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default)
                try session.setActive(true)
            } catch {
                print("[AUDIO] Failed to configure audio session: \(error)")
            }
        }.value

        // プレイヤー初期化（PlaybackController に委譲）
        await MainActor.run { playback.setup(videos: videos) }

        // duration + preferredTransform 並列取得
        var durations: [String: Double] = [:]
        var transforms: [String: CGAffineTransform] = [:]
        var audioFlags: [String: Bool] = [:]
        await withTaskGroup(of: (String, Double, CGAffineTransform, Bool).self) { group in
            for (device, url) in videos {
                group.addTask {
                    let asset = AVURLAsset(url: url)
                    let dur = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
                    // 動画トラックの preferredTransform を取得（天地回転の検出用）
                    var transform = CGAffineTransform.identity
                    if let track = try? await asset.loadTracks(withMediaType: .video).first {
                        transform = (try? await track.load(.preferredTransform)) ?? .identity
                    }
                    // オーディオトラックの有無を検出（SINGLE MODE でFRONT/BACKどちらにオーディオがあるか判定）
                    let hasAudio = ((try? await asset.loadTracks(withMediaType: .audio))?.isEmpty == false)
                    return (device, dur, transform, hasAudio)
                }
            }
            for await (device, dur, transform, hasAudio) in group {
                durations[device] = dur
                transforms[device] = transform
                audioFlags[device] = hasAudio
            }
        }

        // preferredTransform を MetalPreviewRenderer に渡す（天地回転対応）
        await MainActor.run {
            playback.metalRenderer.videoTransforms = transforms
            deviceHasAudio = audioFlags
        }

        // タイムライン初期化 + 編集状態復元
        await MainActor.run {
            timeline.setup(durations: durations, orderedDevices: sortedDevices)
            if !savedEditState.isEmpty {
                timeline.restoreEditState(savedEditState)
            }
            if !savedLockedDevices.isEmpty {
                timeline.lockedDevices = Set(savedLockedDevices)
            }
        }

        await Task.yield()

        // 保存済み設定の復元（フィルタ・万華鏡・速度・ピッチ等）
        await MainActor.run {
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
            filterIntensity = savedFilterIntensity
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
        }

        await Task.yield()

        // グローバルフィルタ同期 + プレビュー適用 + 音声ソース設定
        await MainActor.run {
            playback.globalFilterSettings = SegmentFilterSettings(
                videoFilter: selectedFilter,
                kaleidoscopeType: selectedKaleidoscope,
                kaleidoscopeSize: kaleidoscopeSize,
                kaleidoscopeCenterX: kaleidoscopeCenterX,
                kaleidoscopeCenterY: kaleidoscopeCenterY,
                rotationAngle: rotationAngle,
                autoRotateSpeed: isAutoRotating ? autoRotateSpeed : 0,
                speedRate: playbackSpeed,
                filterIntensity: filterIntensity
            )
            if selectedFilter != nil || selectedKaleidoscope != nil {
                playback.applyVideoFilter(filterName: selectedFilter, kaleidoscopeType: selectedKaleidoscope, kaleidoscopeSize: kaleidoscopeSize, centerX: kaleidoscopeCenterX, centerY: kaleidoscopeCenterY, tileHeight: tileHeight, mirrorDirection: mirrorDirection, rotationAngle: rotationAngle, filterIntensity: filterIntensity)
            }
            playback.totalDuration = timeline.totalDuration
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
            // セグメント切り替え時の pitch / noSound を View 側で処理するコールバックを登録
            playback.onSegmentAudioChange = { [weak playback] segPitch, segNoSound in
                Task { @MainActor [weak playback] in
                    guard let playback else { return }
                    // グローバル NO_SOUND フラグ、またはセグメント固有 noSound なら常にミュート維持
                    if playback.isGlobalNoSound || segNoSound {
                        for (_, p) in playback.players { p.volume = 0 }
                        playback.pitchEnginePause()
                    } else if segPitch != 0 {
                        // セグメント固有 pitch: エンジンに反映
                        playback.pitchCents = segPitch
                        for (_, p) in playback.players { p.volume = 0 }
                    } else {
                        // pitch なし: グローバル pitchShiftCents に戻す
                        // （グローバル設定は applyPitchShift/applyAudioSource で管理済みのため
                        //   ここでは音量のみ復元する）
                        playback.pitchCents = 0
                        playback.stopPitchEngine()
                        for (_, p) in playback.players { p.volume = 1.0 }
                    }
                }
            }
            applyAudioSource()
            previewAspectRatio = desiredOrientation.aspectRatio
            playback.displayAspectRatio = desiredOrientation.aspectRatio
        }

        // サムネイル取得（完了まで Loading 表示を維持）
        await generateAllThumbnails()

        // Metal CIFilter パイプラインの事前ウォームアップ
        // 初回フレーム描画時の "building pipeline" による数秒フリーズを防ぐため、
        // isReady = true の前に実行する（DancingLoaderView が表示されている間に完了させる）
        await playback.metalRenderer.warmUpPipeline()

        // ウォームアップ完了 → Loading 解除
        await MainActor.run { isReady = true }

        // 波形データはUIが表示された後にバックグラウンドで取得
        Task { await generateAllWaveforms() }
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

    private nonisolated func generateThumbnails(for url: URL, count: Int) async -> [UIImage] {
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
    private nonisolated static func centerCropToSquare(cgImage: CGImage) -> UIImage {
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

    // MARK: - Waveform Generation

    /// 全デバイスのオーディオ波形データを並列に抽出する
    private func generateAllWaveforms() async {
        await withTaskGroup(of: (String, [Float]).self) { group in
            for (device, url) in videos {
                guard deviceHasAudio[device] == true else { continue }
                group.addTask {
                    (device, await Self.extractWaveformData(from: url, sampleCount: 300))
                }
            }
            var result: [String: [Float]] = [:]
            for await (device, data) in group {
                result[device] = data
            }
            await MainActor.run { waveformData = result }
        }
    }

    /// 動画ファイルのオーディオトラックからRMS振幅データを抽出する
    /// ストリーミング方式でメモリ効率良くビン単位でRMS計算
    private nonisolated static func extractWaveformData(from url: URL, sampleCount: Int) async -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            return []
        }

        guard let reader = try? AVAssetReader(asset: asset) else { return [] }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)

        guard reader.startReading() else { return [] }

        // サンプルレートからビンサイズを推定
        let format = await (try? audioTrack.load(.formatDescriptions))?.first
        let sampleRate: Double
        if let fmt = format,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) {
            sampleRate = asbd.pointee.mSampleRate
        } else {
            sampleRate = 44100
        }
        let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
        guard duration > 0 else { return [] }
        let totalSamplesEstimate = Int(sampleRate * duration)
        let binSize = max(totalSamplesEstimate / sampleCount, 1)

        // ストリーミングRMS計算（全サンプルをメモリに溜めない）
        var rmsValues: [Float] = []
        var sumOfSquares: Float = 0
        var samplesInBin: Int = 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            let int16Count = length / MemoryLayout<Int16>.size
            guard int16Count > 0 else { continue }

            var data = Data(count: length)
            data.withUnsafeMutableBytes { rawBuf in
                if let ptr = rawBuf.baseAddress {
                    CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: ptr)
                }
            }

            data.withUnsafeBytes { rawBuf in
                let buffer = rawBuf.bindMemory(to: Int16.self)
                for i in 0..<int16Count {
                    let sample = Float(buffer[i]) / Float(Int16.max)
                    sumOfSquares += sample * sample
                    samplesInBin += 1

                    if samplesInBin >= binSize {
                        let rms = sqrt(sumOfSquares / Float(samplesInBin))
                        rmsValues.append(rms)
                        sumOfSquares = 0
                        samplesInBin = 0
                        if rmsValues.count >= sampleCount { break }
                    }
                }
            }
            if rmsValues.count >= sampleCount { break }
        }

        // 残りのサンプルがあればビンに追加
        if samplesInBin > 0, rmsValues.count < sampleCount {
            let rms = sqrt(sumOfSquares / Float(samplesInBin))
            rmsValues.append(rms)
        }

        // 最大値で正規化 (0.0-1.0)
        let maxRMS = rmsValues.max() ?? 1.0
        guard maxRMS > 0 else { return rmsValues }
        return rmsValues.map { $0 / maxRMS }
    }
}

// MARK: - WaveformBar

/// オーディオ波形の Canvas 描画ビュー
private struct WaveformBar: View {
    let samples: [Float]

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }
            let barWidth = size.width / CGFloat(samples.count)
            let count = CGFloat(samples.count)

            for (index, amplitude) in samples.enumerated() {
                let x = CGFloat(index) * barWidth
                let barH = max(CGFloat(amplitude) * size.height, 0.5)
                let y = (size.height - barH) / 2
                let rect = CGRect(x: x, y: y, width: max(barWidth - 0.3, 0.3), height: barH)

                // 左→右 シアン → ブルー グラデーション（位置に応じて色補間）
                let t = CGFloat(index) / max(count - 1, 1)
                let color = Color(
                    red: 0.0 + 0.1 * t,
                    green: 0.85 - 0.45 * t,
                    blue: 1.0
                ).opacity(0.7)
                context.fill(Path(rect), with: .color(color))
            }
        }
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
    /// GestureState: ドラッグ中は true、ジェスチャーがキャンセルされても自動で false に戻る
    @GestureState private var isTrimDragActive: Bool = false

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
        // フェイルセーフ: GestureState が false に戻った（ジェスチャー終了 or キャンセル）
        // のに .onEnded が呼ばれなかった場合、ここで確実にリセットする
        .onChange(of: isTrimDragActive) { active in
            if !active && draggingID != nil {
                print("[TRIM] FAILSAFE reset — gesture cancelled without .onEnded device=\(deviceName)")
                draggingID = nil
                dragStartX = 0
                onTrimEnd?()
            }
        }
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
            .allowsHitTesting(onSegmentTap != nil)
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
            .updating($isTrimDragActive) { _, state, _ in
                state = true
            }
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
            .onEnded { v in
                // 最終位置を確定（スロットルで間引かれた分を反映）
                let absX   = dragStartX + v.translation.width
                let ratio  = max(0, min(1, absX / width))
                let newSec = Double(ratio) * totalDuration
                onTrimIn(seg.id, newSec)
                print("[TRIM] IN drag END seg=\(draggingID?.uuidString.prefix(8) ?? "nil") device=\(deviceName)")
                draggingID = nil
                dragStartX = 0
                onTrimEnd?()
            }
    }

    private func outHandleGesture(seg: ClipSegment, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($isTrimDragActive) { _, state, _ in
                state = true
            }
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
            .onEnded { v in
                // 最終位置を確定（スロットルで間引かれた分を反映）
                let absX   = dragStartX + v.translation.width
                let ratio  = max(0, min(1, absX / width))
                let newSec = Double(ratio) * totalDuration
                onTrimOut(seg.id, newSec)
                print("[TRIM] OUT drag END seg=\(draggingID?.uuidString.prefix(8) ?? "nil") device=\(deviceName)")
                draggingID = nil
                dragStartX = 0
                onTrimEnd?()
            }
    }


}

// (FillPlayerView / PlayerFillUIView は Metal 移行により削除)


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

