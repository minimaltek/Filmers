//
//  PreviewView.swift
//  Cinecam
//

import SwiftUI
import AVKit
import AVFoundation
import AVFAudio
import Combine

// MARK: - PlaybackController
// Timer・AVPlayer の状態をクラスで管理することで、
// struct（PreviewView）からのクロージャ参照問題を回避する

@MainActor
final class PlaybackController: ObservableObject {
    @Published var isPlaying = false
    @Published var playheadTime: Double = 0
    /// 現在プレビューに表示すべきデバイス（セグメントがない黒画面区間では "" になることもある）
    @Published var activePreviewDevice: String = ""

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

    /// 音声ソースデバイス（nil = 編集に従う）
    var audioSourceDevice: String? = nil
    /// 各デバイスの映像開始オフセット（音声同期のシークに使用）
    var videoStartByDevice: [String: Double] = [:]

    func setup(videos: [String: URL]) {
        players = videos.mapValues { AVPlayer(url: $0) }
    }

    func teardown() {
        seekGeneration += 1   // 残留シークコールバックを無効化
        preloadedNext = nil
        players.values.forEach { $0.pause() }
        stopTimer()
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
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] finished in
                    if finished { player?.play() }
                }
            } else if player.rate == 0 {
                // 一時停止されていたら再開（セグメント切替で pause された場合の復帰）
                player.play()
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
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] finished in
            if finished { player?.play() }
        }
    }

    /// 音声ソースデバイスのプレイヤーを停止する
    func pauseAudioSource() {
        guard let srcDevice = audioSourceDevice,
              let player = players[srcDevice] else { return }
        player.pause()
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

        let player = players[device]

        // 音声ソースデバイスの場合はシークせず継続再生（音声を途切れさせない）
        if device == audioSourceDevice {
            preloadedNext = nil
            isSeeking = false
            if isPlaying, player?.rate == 0 { player?.play() }
            return
        }

        // 事前seekが完了していれば、seekをスキップして即再生
        if let preloaded = preloadedNext,
           preloaded.device == device,
           preloaded.segID == seg.id {
            preloadedNext = nil
            isSeeking = false
            if isPlaying { player?.play() }
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
                if self.isPlaying { player?.play() }
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
                        if self.isPlaying { player?.play() }
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
    var onSaveEditState: ((_ segments: [String: [ClipSegment]], _ lockedDevices: Set<String>, _ audioDevice: String?, _ videoFilter: String?) -> Void)? = nil
    /// 保存済みの編集状態（起動時に復元に使う）
    var savedEditState: [String: [SegmentState]] = [:]
    /// 保存済みのロック状態（起動時に復元に使う）
    var savedLockedDevices: [String] = []
    /// 保存済みの音声デバイス（起動時に復元に使う）
    var savedAudioDevice: String? = nil
    /// 保存済みの映像フィルタ（起動時に復元に使う）
    var savedVideoFilter: String? = nil
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
    /// 音声ソース選択シート表示フラグ
    @State private var showAudioSourceSheet: Bool = false

    // MARK: - Device Lock
    /// ロックパネル表示中のデバイス名（nil = 非表示）
    @State private var lockPopoverDevice: String? = nil

    // MARK: - Video Filter
    @State private var selectedFilter: String? = nil
    @State private var showFilterSheet: Bool = false

    /// フィルタ定義（表示名, CIFilter名 or nil）
    private static let videoFilters: [(label: String, icon: String, ciName: String?)] = [
        ("NONE",   "video",           nil),
        ("MONO",   "circle.lefthalf.filled",  "CIPhotoEffectMono"),
        ("NOIR",   "circle.fill",     "CIPhotoEffectNoir"),
        ("CHROME", "sparkles",        "CIPhotoEffectChrome"),
        ("FADE",   "sun.haze",        "CIPhotoEffectFade"),
        ("SEPIA",  "paintpalette",    "CISepiaTone"),
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
                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.2)
                        Text("LOADING")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(true) // 下のUIへのタッチをブロック
            }
        }
        .background(Color.black.ignoresSafeArea())
        .task {
            currentTitle = sessionTitle
            try? await Task.sleep(nanoseconds: 400_000_000)
            await setupAll()
        }
        .onDisappear {
            // 閉じる方法に関わらず編集状態を自動保存
            // （×ボタン、マスターからの強制クローズ等すべてのケース）
            onSaveEditState?(timeline.segmentsByDevice, timeline.lockedDevices, audioSource, selectedFilter)
            playback.teardown()
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
                    ForEach(sortedDevices, id: \.self) { device in
                        if let player = playback.players[device] {
                            FillPlayerView(player: player)
                                .frame(width: boxW, height: boxH)
                                .clipped()
                                .opacity(visibleDevice == device ? 1 : 0)
                        }
                    }

                    // フィルタプレビュー用カラーオーバーレイ
                    if selectedFilter == "CISepiaTone" {
                        Color(red: 0.6, green: 0.45, blue: 0.25).opacity(0.3)
                            .blendMode(.color)
                            .frame(width: boxW, height: boxH)
                            .allowsHitTesting(false)
                    } else if selectedFilter == "CIPhotoEffectChrome" {
                        Color.orange.opacity(0.06)
                            .blendMode(.overlay)
                            .frame(width: boxW, height: boxH)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: boxW, height: boxH)
                .clipped()
                // フィルタプレビュー効果（SwiftUI モディファイアで近似）
                .saturation(filterPreviewSaturation)
                .contrast(filterPreviewContrast)
                .brightness(filterPreviewBrightness)
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
    /// フィルタプレビュー用パラメータ
    private var filterPreviewSaturation: Double {
        switch selectedFilter {
        case "CIPhotoEffectMono", "CIPhotoEffectNoir", "CISepiaTone": return 0
        case "CIPhotoEffectFade": return 0.6
        default: return 1.0
        }
    }

    private var filterPreviewContrast: Double {
        switch selectedFilter {
        case "CIPhotoEffectNoir": return 1.2
        case "CIPhotoEffectChrome": return 1.1
        default: return 1.0
        }
    }

    private var filterPreviewBrightness: Double {
        switch selectedFilter {
        case "CIPhotoEffectFade": return 0.05
        case "CIPhotoEffectChrome": return 0.02
        default: return 0
        }
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
                    Task { await exportEngine.export(timeline: timeline, videos: videos, orientation: desiredOrientation, audioSource: audioSource, videoFilter: selectedFilter, showWatermark: true) }  // TestFlight: 常に透かし表示（課金実装時に !purchaseManager.isPremium に戻す）
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
        onSaveEditState?(timeline.segmentsByDevice, timeline.lockedDevices, audioSource, selectedFilter)
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
        .presentationDetents([.height(260)])
        .presentationDragIndicator(.hidden)
        .onAppear {
            // シートのスライドアニメーション（約0.4秒）が完了してから
            // フォーカスを当てる。早すぎるとシートが見えない状態でキーボードが
            // 開き、アニメーション中の画面タッチが誤入力される。
            // また titleDraft をここで再セットすることで、isEditingTitle = true と
            // State 更新が非同期で競合しても正しい値が確保される。
            titleDraft = currentTitle == "UNTITLED" ? "" : currentTitle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
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

            Button("Close") {
                lockPopoverDevice = nil
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.1))
            .foregroundColor(.white.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.1).ignoresSafeArea())
        .presentationDetents([.height(220)])
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
                playback.playheadTime = actual
                playback.throttledSeekForTrim(to: actual, timeline: timeline, selectedDevice: device)
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
            onDeleteSegment: { segID in
                print("[PARENT] onDeleteSegment device=\(device) seg=\(segID)")
                timeline.removeSegment(segmentID: segID, device: device)
                editingSegmentIDs.removeValue(forKey: device)
                editingDevices.remove(device)
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

            // ── 再生ボタン + 音声ソース ──────────────────────────
            HStack(spacing: 24) {
                // 音声ソース選択ボタン（ヘッドフォンアイコン）
                Button {
                    showAudioSourceSheet = true
                } label: {
                    Image(systemName: "headphones")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(audioSource != nil ? .cyan : .white.opacity(0.6))
                }

                // 再生ボタン
                Button(action: {
                    if !playback.isPlaying {
                        editingDevices.removeAll()
                        editingSegmentIDs.removeAll()
                    }
                    playback.togglePlayback(allSegments: allSegmentsSorted(), totalDuration: totalDuration)
                    // 音声ソース: 再生開始時に同期開始、停止時にpause
                    if playback.isPlaying {
                        playback.startAudioSource(playheadTime: playback.playheadTime)
                    } else {
                        playback.pauseAudioSource()
                    }
                }) {
                    Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64)).foregroundColor(.white)
                }

                // 映像フィルタ選択ボタン
                Button {
                    showFilterSheet = true
                } label: {
                    Image(systemName: "camera.filters")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(selectedFilter != nil ? .cyan : .white.opacity(0.6))
                }
            }
            .sheet(isPresented: $showAudioSourceSheet) {
                audioSourceSheet
            }
            .sheet(isPresented: $showFilterSheet) {
                videoFilterSheet
            }
        }
        .padding(.bottom, 16)
        .padding(.top, 4)
    }

    // MARK: - Audio Source Sheet

    private var audioSourceSheet: some View {
        NavigationView {
            List {
                // "Follow Edit" = use audio from the same device as the video cut
                Button {
                    audioSource = nil
                    applyAudioSource()
                    showAudioSourceSheet = false
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

                // Per-device audio selection
                ForEach(sortedDevices, id: \.self) { device in
                    Button {
                        audioSource = device
                        applyAudioSource()
                        showAudioSourceSheet = false
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
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("AUDIO SOURCE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("DONE") { showAudioSourceSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Video Filter Sheet

    private var videoFilterSheet: some View {
        NavigationView {
            List {
                ForEach(Self.videoFilters, id: \.label) { filter in
                    Button {
                        selectedFilter = filter.ciName
                        showFilterSheet = false
                    } label: {
                        HStack {
                            Image(systemName: filter.icon)
                                .foregroundColor(.white)
                                .frame(width: 28)
                            Text(filter.label)
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                                .foregroundColor(.white)
                            Spacer()
                            if selectedFilter == filter.ciName {
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
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("VIDEO FILTER")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("DONE") { showFilterSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    /// 音声ソース変更をプレイヤーのボリュームに反映する
    private func applyAudioSource() {
        // PlaybackController に音声ソースを伝える
        playback.audioSourceDevice = audioSource
        // videoStart マップを更新
        var starts: [String: Double] = [:]
        for device in sortedDevices {
            starts[device] = timeline.videoRangeByDevice[device]?.start ?? 0
        }
        playback.videoStartByDevice = starts

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

        // duration 並列取得
        var durations: [String: Double] = [:]
        await withTaskGroup(of: (String, Double).self) { group in
            for (device, url) in videos {
                group.addTask {
                    let asset = AVURLAsset(url: url)
                    let dur = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
                    return (device, dur)
                }
            }
            for await (device, dur) in group { durations[device] = dur }
        }

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
            // 音声デバイス・フィルタを復元
            audioSource = savedAudioDevice
            selectedFilter = savedVideoFilter
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
        }

        // アスペクト比はすぐ設定（サムネイルより先にレイアウトを確定）
        await MainActor.run { previewAspectRatio = desiredOrientation.aspectRatio }

        // サムネイル取得（バックグラウンドで実行）
        await generateAllThumbnails()

        // 準備完了
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
                images.append(UIImage(cgImage: cg))
            }
        }
        return images
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
    /// トリムハンドルのダブルタップでセグメントを削除する
    var onDeleteSegment: ((UUID) -> Void)? = nil
    /// トリムドラッグ終了時のコールバック
    var onTrimEnd: (() -> Void)? = nil

    @State private var draggingID: UUID? = nil
    @State private var dragStartX: CGFloat = 0
    @State private var longPressLocation: CGFloat = 0

    private let labelWidth:  CGFloat = 52
    private let thumbHeight: CGFloat = 52
    private let handleWidth: CGFloat = 16

    /// セグメントの枠色（ロック時は深いブルー）
    private var segmentColor: Color { isLocked ? Color(red: 0.1, green: 0.25, blue: 0.7) : trimHandleColor }
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
            let rangeW   = max(outX - inX, 0)
            let isDragging = draggingID == seg.id

            ZStack(alignment: .topLeading) {
                // 上下ボーダー：常時表示（選択中を示す）
                // ボーダーの線幅が scaleEffect で伸びるのを防ぐため、逆スケール補正した lineWidth を使用
                let borderW: CGFloat = (isDragging ? 3 : 2.5) * inverseScaleX
                Path { path in
                    path.move(to: CGPoint(x: inX, y: 0))
                    path.addLine(to: CGPoint(x: outX, y: 0))
                    path.move(to: CGPoint(x: inX, y: thumbHeight))
                    path.addLine(to: CGPoint(x: outX, y: thumbHeight))
                }
                .stroke(isDragging ? Color.red : trimHandleColor.opacity(0.9), lineWidth: borderW)
                .allowsHitTesting(false)

                // IN点ハンドル：右端を inX に合わせる
                handleBar(isLeading: true, isDragging: isDragging)
                    .frame(width: handleWidth, height: thumbHeight)
                    .scaleEffect(x: inverseScaleX, y: 1.0)
                    .padding(.horizontal, 20)  // タッチ領域拡大
                    .offset(x: inX - handleWidth - 20)
                    .onTapGesture(count: 2) {
                        onDeleteSegment?(seg.id)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    .gesture(inHandleGesture(seg: seg, width: width))

                // OUT点ハンドル：左端を outX に合わせる
                handleBar(isLeading: false, isDragging: isDragging)
                    .frame(width: handleWidth, height: thumbHeight)
                    .scaleEffect(x: inverseScaleX, y: 1.0)
                    .padding(.horizontal, 20)  // タッチ領域拡大
                    .offset(x: outX - 20)
                    .onTapGesture(count: 2) {
                        onDeleteSegment?(seg.id)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    .gesture(outHandleGesture(seg: seg, width: width))

                // 中央エリア：ダブルタップで削除のみ
                if rangeW > 0 {
                    Color.clear
                        .frame(width: rangeW, height: thumbHeight)
                        .offset(x: inX)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            onDeleteSegment?(seg.id)
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                }

                // IN点の縦線
                Rectangle()
                    .fill(isDragging ? Color.red : trimHandleColor)
                    .frame(width: 1, height: thumbHeight)
                    .scaleEffect(x: inverseScaleX, y: 1.0)
                    .offset(x: inX)
                    .allowsHitTesting(false)

                // OUT点の縦線
                Rectangle()
                    .fill(isDragging ? Color.red : trimHandleColor)
                    .frame(width: 1, height: thumbHeight)
                    .scaleEffect(x: inverseScaleX, y: 1.0)
                    .offset(x: outX - 1)
                    .allowsHitTesting(false)
            }
            .frame(width: width, height: thumbHeight)
        }
    }

    /// Photos風ハンドルバー：黄色塗り + シェブロン（ドラッグ中は赤系に変化）
    private func handleBar(isLeading: Bool, isDragging: Bool = false) -> some View {
        let bgColor = isDragging ? Color.red : trimHandleColor
        let chevronColor: Color = isDragging ? .white : .black.opacity(0.4)
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

// MARK: - FillPlayerView (AVPlayerLayer with resizeAspectFill)

/// UIViewRepresentable that uses AVPlayerLayer with videoGravity = .resizeAspectFill.
/// This ensures all videos—regardless of their native orientation—fill the target box
/// and get center-cropped identically.
private struct FillPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerFillUIView {
        let view = PlayerFillUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerFillUIView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

private class PlayerFillUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

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

