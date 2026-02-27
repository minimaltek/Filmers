//
//  PreviewView.swift
//  Cinecam
//

import SwiftUI
import AVKit
import AVFoundation
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
    /// 黒画面区間の再生用：区間終了時刻
    private var blackUntil: Double = 0
    /// totalDuration キャッシュ（tick 内で参照）
    var totalDuration: Double = 0
    /// 次セグメントの事前seek済み情報（device, segmentID）
    private var preloadedNext: (device: String, segID: UUID)? = nil

    func setup(videos: [String: URL]) {
        players = videos.mapValues { AVPlayer(url: $0) }
    }

    func teardown() {
        seekGeneration += 1   // 残留シークコールバックを無効化
        preloadedNext = nil
        players.values.forEach { $0.pause() }
        stopTimer()
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
                players[activePreviewDevice]?.pause()
                activePreviewDevice = device
            }
            players[device]?.seek(
                to: CMTimeMakeWithSeconds(srcTime, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero
            )
        } else {
            // セグメント外 → 全プレイヤー停止・黒画面
            players.values.forEach { $0.pause() }
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

    func seekToSegment(device: String, seg: ClipSegment) {
        // 前のデバイスのプレイヤーを止める
        if !activePreviewDevice.isEmpty && activePreviewDevice != device {
            players[activePreviewDevice]?.pause()
        }
        activePreviewDevice = device
        playheadTime = seg.trimIn
        blackUntil = 0

        let player = players[device]

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
        players.values.forEach { $0.pause() }
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
        players.values.forEach { $0.pause() }
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
            players.values.forEach { $0.pause() }
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
            players.values.forEach { $0.pause() }
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
            players.values.forEach { $0.pause() }
            stopTimer()
        } else {
            guard totalDuration > 0 else { return }
            isPlaying = true
            self.totalDuration = totalDuration
            let pt = playheadTime

            if let current = allSegments.first(where: { $0.seg.trimIn <= pt && pt < $0.seg.trimOut }) {
                // プレイヘッドがセグメント内 → 現在位置から再生
                if activePreviewDevice != current.device {
                    players[activePreviewDevice]?.pause()
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

        // セグメント終端判定（1フレーム手前で切り替え）
        guard now >= currentEntry.seg.sourceOutTime - frameTime else { return }

        // 終端処理：isSeeking を即セットして多重発火を防ぐ
        player.pause()
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
    var onSaveEditState: (([String: [ClipSegment]]) -> Void)? = nil
    /// 保存済みの編集状態（起動時に復元に使う）
    var savedEditState: [String: [SegmentState]] = [:]
    /// 撮影時の向き設定（クロップ・エクスポートに使用）
    var desiredOrientation: VideoOrientation = .cinema

    @Environment(\.dismiss) private var dismiss

    @StateObject private var timeline = ExclusiveEditTimeline()
    @StateObject private var exportEngine = ExportEngine()
    @StateObject private var playback = PlaybackController()

    @State private var selectedDevice: String = ""
    /// デバイスごとの編集モード状態（長押しで true になる）
    @State private var editingDevices: Set<String> = []
    /// デバイスごとの「編集中セグメントID」（ハンドル表示対象：最後に操作した1つ）
    @State private var editingSegmentIDs: [String: UUID] = [:]
    /// 前回選択されていたデバイス（行き来確定に使う）
    @State private var previousSelectedDevice: String = ""
    @State private var thumbnails: [String: [UIImage]] = [:]
    @State private var previewAspectRatio: CGFloat = 16.0 / 9.0
    @State private var timelineWidth: CGFloat = 1  // 後方互換のため残す（未使用）
    @State private var isPlayheadDragging: Bool = false
    @State private var showExportResult = false
    @State private var showExportError = false
    @State private var exportedURL: URL? = nil
    /// 表示中のタイトル（タップ編集）
    @State private var currentTitle: String = ""
    /// タイトル編集モード中フラグ
    @State private var isEditingTitle: Bool = false
    /// 編集中の一時テキスト
    @State private var titleDraft: String = ""
    /// TextField のフォーカス制御
    @FocusState private var titleFieldFocused: Bool

    // MARK: - Timeline Zoom
    /// タイムラインのズーム倍率（1.0 = 全体表示、最大 8.0）
    @State private var zoomScale: CGFloat = 1.0
    /// ピンチ開始時の倍率スナップショット
    @State private var zoomScaleAtGestureStart: CGFloat = 1.0
    /// ScrollView のスクロールオフセット（ズーム時に中心を保つ）
    @State private var scrollOffset: CGFloat = 0
    /// タイムライン表示領域の実幅（ズーム前・ラベル除く）
    @State private var baseTrackWidth: CGFloat = 1
    /// zoomBar のドラッグで要求されたスクロール先アンカーID（nil = スクロール不要）
    @State private var zoomBarScrollRequest: Int? = nil

    private var sortedDevices: [String] { videos.keys.sorted() }
    private var totalDuration: Double { timeline.totalDuration }

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
                VStack(spacing: 0) {
                    headerBar
                    previewArea
                    timelineSection
                    Spacer(minLength: 0)
                    playbackControls
                }
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
            onSaveEditState?(timeline.segmentsByDevice)
            playback.teardown()
        }
        // タイトル編集：キーボードが上がっても入力欄が見えるよう専用シートで表示
        .sheet(isPresented: $isEditingTitle) {
            titleEditSheet
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
    }

    // MARK: - Preview Area

    private var previewContainerHeight: CGFloat {
        // UIScreen は向きに追従しないので GeometryReader で得た実際のウィンドウサイズを使う
        // ここでは安全な上限として画面の短辺 × 0.45 を用いる
        let bounds = UIScreen.main.bounds
        let shortSide = min(bounds.width, bounds.height)
        let longSide  = max(bounds.width, bounds.height)
        // 縦向き想定の幅を使ってアスペクト比から高さを計算し、上限を設ける
        let h = shortSide / previewAspectRatio
        return min(h, longSide * 0.40)
    }

    private var previewArea: some View {
        GeometryReader { geo in
            let boxW = min(geo.size.height * previewAspectRatio, geo.size.width)
            let boxH = min(geo.size.width / previewAspectRatio,  geo.size.height)

            ZStack {
                Color.black

                ForEach(sortedDevices, id: \.self) { device in
                    if let player = playback.players[device] {
                        FillPlayerView(player: player)
                            .frame(width: boxW, height: boxH)
                            .clipped()
                            .opacity(visibleDevice == device ? 1 : 0)
                    }
                }
            }
            .frame(width: boxW, height: boxH)
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: previewContainerHeight)
        .background(Color.black)
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

                // ライブラリへ戻るボタン（onRename が設定されているときのみ表示）
                if onRename != nil {
                    Button(action: { dismiss() }) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.15))
                            .clipShape(Circle())
                    }
                }

                // 書き出しボタン
                Button {
                    Task { await exportEngine.export(timeline: timeline, videos: videos, orientation: desiredOrientation) }
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
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func commitRename() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespaces)
        currentTitle = trimmed.isEmpty ? "UNTITLED" : trimmed
        onRename?(currentTitle)
        // タイトル保存と同時に現在の編集状態（セグメント）も保存
        onSaveEditState?(timeline.segmentsByDevice)
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
    private var scaledTrackWidth: CGFloat { max(trackViewportWidth * zoomScale, 1) }

    private var timelineSection: some View {
        let rowH: CGFloat = 56
        let rowCount = min(sortedDevices.count, 5)
        // トラック行の総高さ（行間スペース3pt × (rowCount-1) + 上下パディング各4pt = 8pt）
        let trackAreaH: CGFloat = CGFloat(rowCount) * rowH + 3 * CGFloat(max(rowCount - 1, 0)) + 8
        let knobOverhang: CGFloat = knobDiameter + 8

        return HStack(spacing: 0) {
                // ① 固定ラベル列
                VStack(spacing: 3) {
                    ForEach(sortedDevices, id: \.self) { device in
                        VStack(spacing: 3) {
                            Image(systemName: "video.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.5))
                            Text(device)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white.opacity(0.7))
                                .lineLimit(1).truncationMode(.tail)
                                .frame(width: fixedLabelWidth - 8)
                        }
                        .frame(width: fixedLabelWidth, height: rowH)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(.leading, fixedLabelLeading)
                .padding(.bottom, 8)
                .frame(height: trackAreaH + knobOverhang, alignment: .top)

                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: fixedDividerWidth, height: trackAreaH + knobOverhang)

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
                        ScrollView(.horizontal, showsIndicators: false) {
                            ZStack(alignment: .topLeading) {
                                VStack(spacing: 3) {
                                    ForEach(sortedDevices, id: \.self) { device in
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
                                            showLabel: false,
                                            onTrimIn: { segID, newSec in
                                                editingSegmentIDs[device] = segID
                                                timeline.moveTrimIn(segmentID: segID, device: device, newTrimIn: newSec)
                                                // クランプ後の実際の trimIn に合わせる
                                                let actual = timeline.segments(for: device).first(where: { $0.id == segID })?.trimIn ?? newSec
                                                playback.playheadTime = actual
                                                playback.seekPreview(to: actual, timeline: timeline, selectedDevice: device)
                                            },
                                            onTrimOut: { segID, newSec in
                                                editingSegmentIDs[device] = segID
                                                timeline.moveTrimOut(segmentID: segID, device: device, newTrimOut: newSec)
                                                // クランプ後の実際の trimOut に合わせる
                                                let actual = timeline.segments(for: device).first(where: { $0.id == segID })?.trimOut ?? newSec
                                                playback.playheadTime = actual
                                                playback.seekPreview(to: actual, timeline: timeline, selectedDevice: device)
                                            },
                                            onSlide: { segID, deltaSec in
                                                editingSegmentIDs[device] = segID
                                                timeline.moveSegment(segmentID: segID, device: device, deltaSeconds: deltaSec)
                                                if let seg = timeline.segments(for: device).first(where: { $0.id == segID }) {
                                                    playback.playheadTime = seg.trimIn
                                                    playback.seekPreview(to: seg.trimIn, timeline: timeline, selectedDevice: device)
                                                }
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
                                                // デバイスを選択状態にしてから編集対象セグメントを切り替える
                                                handleDeviceTap(device)
                                                editingSegmentIDs[device] = segID
                                                editingDevices.insert(device)
                                                // タップ時点で排他制約を強制適用
                                                timeline.commitAllSegments(for: device)
                                                // タップしたセグメントの先頭にプレイヘッドを移動
                                                if let seg = timeline.segments(for: device).first(where: { $0.id == segID }) {
                                                    playback.playheadTime = seg.trimIn
                                                    playback.seekPreview(to: seg.trimIn, timeline: timeline, selectedDevice: device)
                                                }
                                            },
                                            onDeleteSegment: { segID in
                                                timeline.removeSegment(segmentID: segID, device: device)
                                                editingSegmentIDs.removeValue(forKey: device)
                                                editingDevices.remove(device)
                                            }
                                        )
                                    }
                                }
                                .padding(.leading, trackInnerPad)
                                .padding(.trailing, 12)
                                .padding(.vertical, 4)

                                // スクロール位置アンカー（101分割）：再生追従に使用
                                HStack(spacing: 0) {
                                    ForEach(0...100, id: \.self) { i in
                                        Color.clear
                                            .frame(width: max(viewportW * zoomScale, viewportW) / 101, height: 1)
                                            .id("scroll-anchor-\(i)")
                                    }
                                }
                                .frame(height: 0)

                                // 再生ヘッド：行群と同じ高さの ZStack 内に配置
                                playheadOverlay(trackHeight: trackAreaH)
                            }
                            // コンテンツ幅 = ビューポート幅 × zoomScale
                            // zoomScale=1.0 のとき viewportW にぴったり収まる
                            .frame(width: max(viewportW * zoomScale, viewportW))
                            .onChange(of: zoomScale) { _ in
                                let ratio = totalDuration > 0
                                    ? CGFloat(playback.playheadTime / totalDuration) : 0
                                let anchorID = Int((ratio * 100).rounded()).clamped(to: 0...100)
                                scrollProxy.scrollTo("scroll-anchor-\(anchorID)", anchor: .center)
                            }
                            .onChange(of: playback.playheadTime) { _ in
                                guard playback.isPlaying || isPlayheadDragging else { return }
                                let ratio = totalDuration > 0
                                    ? CGFloat(playback.playheadTime / totalDuration) : 0
                                let anchorID = Int((ratio * 100).rounded()).clamped(to: 0...100)
                                scrollProxy.scrollTo("scroll-anchor-\(anchorID)", anchor: .center)
                            }
                            .onChange(of: zoomBarScrollRequest) { anchorID in
                                guard let id = anchorID else { return }
                                scrollProxy.scrollTo("scroll-anchor-\(id)", anchor: .center)
                            }
                        }
                    }
                }
                // ピンチズームはタイムライン列全体で受け取る
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            zoomScale = (zoomScaleAtGestureStart * value).clamped(to: 1.0...8.0)
                        }
                        .onEnded { _ in
                            zoomScaleAtGestureStart = zoomScale
                        }
                )
            }
            .frame(height: trackAreaH + knobOverhang)
            .background(Color.white.opacity(0.04))
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
        let knob  = knobDiameter

        return ZStack(alignment: .topLeading) {
            // ── 縦ライン（トラック上端 y:0 からノブ中心まで）──
            Rectangle()
                .fill(Color.red)
                .frame(width: 2, height: trackHeight + knob / 2)
                .offset(x: lineX - 1, y: 0)
                .allowsHitTesting(false)
                .id("playhead-anchor")

            // ── ●ドラッグハンドル（トラック直下に配置）──
            Circle()
                .fill(Color.red)
                .frame(width: knob, height: knob)
                .offset(x: lineX - knob / 2, y: trackHeight)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            isPlayheadDragging = true
                            let startRatio = max(0, min(1,
                                (v.startLocation.x - scrollLeftPad) / effectiveTrackWidth))
                            let deltaRatio = v.translation.width / effectiveTrackWidth
                            let r = max(0, min(1, CGFloat(startRatio) + deltaRatio))
                            let sec = Double(r) * totalDuration
                            playback.playheadTime = sec
                            playback.seekPreview(to: sec, timeline: timeline, selectedDevice: selectedDevice)
                        }
                        .onEnded { _ in
                            isPlayheadDragging = false
                        }
                )
        }
        // ZStack のフレームをトラック行全体 + ノブ分に明示固定
        // これにより VStack などの兄弟ビューの高さに左右されなくなる
        .frame(height: trackHeight + knob, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Playback Controls

    private var playbackControls: some View {
        VStack(spacing: 20) {
            // ── ズームバー ──────────────────────────────────────
            zoomBar

            // ── 再生ボタン ──────────────────────────────────────
            Button(action: {
                if !playback.isPlaying {
                    editingDevices.removeAll()
                    editingSegmentIDs.removeAll()
                }
                playback.togglePlayback(allSegments: allSegmentsSorted(), totalDuration: totalDuration)
            }) {
                Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64)).foregroundColor(.white)
            }
        }
        .padding(.bottom, 32)
        .padding(.top, 8)
    }

    // MARK: - Zoom Bar（スクロール位置インジケーター兼ズームコントロール）

    /// バーの表示幅（固定）
    private let zoomBarBaseWidth: CGFloat = 200
    /// スクロールバー操作中フラグ（ピンチ・ドラッグのいずれかが true のとき拡大表示）
    @State private var isZoomBarActive: Bool = false

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
        // 現在の再生位置がバー上のどこにあるか
        let playRatio = totalDuration > 0 ? CGFloat(playback.playheadTime / totalDuration) : 0
        // 表示領域の左端比率（再生ヘッド中央固定）
        let visibleLeft = (playRatio - viewRatio / 2).clamped(to: 0...(1 - viewRatio))
        let thumbX = visibleLeft * zoomBarBaseWidth
        let thumbW = max(viewRatio * zoomBarBaseWidth, 12)

        // アクティブ時はバーを太く・サム（つまみ）も太く
        let trackH: CGFloat = isZoomBarActive ? 6 : 3
        let thumbH: CGFloat = isZoomBarActive ? 10 : 5

        // ズームイン済み（>1.05）なら矢印が内向き（→←）、等倍なら外向き（←→）
        let isZoomed = zoomScale > 1.05
        let leftArrow  = isZoomed ? "arrow.right" : "arrow.left"
        let rightArrow = isZoomed ? "arrow.left"  : "arrow.right"
        let arrowOpacity: Double = isZoomBarActive ? 1.0 : 0.45

        return VStack(spacing: 6) {
            // ── ピンチ操作エリア ──────────────────────────────────
            HStack(spacing: 10) {
                // 左矢印（丸背景付き）
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(isZoomBarActive ? 0.25 : 0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: leftArrow)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white.opacity(arrowOpacity))
                }
                .animation(.easeOut(duration: 0.2), value: isZoomed)
                // シングルタップ → 先頭ジャンプ
                .onTapGesture(count: 1) {
                    playback.jumpToStart(allSegments: allSegmentsSorted())
                }
                // ダブルタップ → ズームリセット
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        zoomScale = 1.0
                        zoomScaleAtGestureStart = 1.0
                    }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }

                // スクロール位置インジケーターバー
                ZStack(alignment: .leading) {
                    // ベーストラック
                    Capsule()
                        .fill(Color.white.opacity(isZoomBarActive ? 0.18 : 0.10))
                        .frame(width: zoomBarBaseWidth, height: trackH)

                    // 現在表示中の範囲を示すつまみ
                    Capsule()
                        .fill(Color.white.opacity(isZoomBarActive ? 0.85 : 0.50))
                        .frame(width: thumbW, height: thumbH)
                        .offset(x: thumbX, y: 0)
                        .animation(.easeOut(duration: 0.08), value: thumbX)
                        .shadow(color: isZoomBarActive ? .white.opacity(0.4) : .clear, radius: 4)
                }
                .frame(width: zoomBarBaseWidth)

                // 右矢印（丸背景付き）
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(isZoomBarActive ? 0.25 : 0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: rightArrow)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white.opacity(arrowOpacity))
                }
                .animation(.easeOut(duration: 0.2), value: isZoomed)
                // シングルタップ → 末尾ジャンプ
                .onTapGesture(count: 1) {
                    playback.jumpToEnd(allSegments: allSegmentsSorted(), totalDuration: totalDuration)
                }
                // ダブルタップ → ズームリセット
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        zoomScale = 1.0
                        zoomScaleAtGestureStart = 1.0
                    }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(isZoomBarActive ? 0.10 : 0.05))
                    .animation(.easeOut(duration: 0.2), value: isZoomBarActive)
            )
            .contentShape(Rectangle())
            // バー全体でドラッグ → タイムラインをスクロール（再生ヘッドは動かさない）
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        isZoomBarActive = true
                        // タップ位置比率をスクロールアンカーIDに変換して ScrollView を動かす
                        let ratio = max(0, min(1, v.location.x / (zoomBarBaseWidth + 36 + 10 + 16 + 36 + 10 + 16)))
                        let anchorID = Int((ratio * 100).rounded()).clamped(to: 0...100)
                        zoomBarScrollRequest = anchorID
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.35)) { isZoomBarActive = false }
                        zoomBarScrollRequest = nil
                    }
            )
            // ピンチでズーム倍率を変える（エリア全体で受け取る）
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        isZoomBarActive = true
                        zoomScale = (zoomScaleAtGestureStart * value).clamped(to: 1.0...8.0)
                    }
                    .onEnded { _ in
                        zoomScaleAtGestureStart = zoomScale
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
            playback.totalDuration = timeline.totalDuration
            if let longest = durations.max(by: { $0.value < $1.value })?.key {
                selectedDevice = longest
                playback.activePreviewDevice = longest
            } else if let first = sortedDevices.first {
                selectedDevice = first
                playback.activePreviewDevice = first
            }
        }

        // サムネイル取得 + アスペクト比設定
        await generateAllThumbnails()
        previewAspectRatio = desiredOrientation.aspectRatio
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
    /// false のときラベル列を非表示にする（ラベルを ScrollView 外に固定するため）
    var showLabel: Bool = true

    let onTrimIn:          (UUID, Double) -> Void
    let onTrimOut:         (UUID, Double) -> Void
    let onSlide:           (UUID, Double) -> Void
    let onCommitSelection: (Double, Double) -> Void
    let onAddSegment:      (_ seconds: Double, _ trackWidth: CGFloat) -> Void
    let onTap: () -> Void
    /// セグメントの青枠をタップしたときに、そのセグメントIDを通知する
    var onSegmentTap: ((UUID) -> Void)? = nil
    /// トリムハンドルのダブルタップでセグメントを削除する
    var onDeleteSegment: ((UUID) -> Void)? = nil

    @State private var draggingID: UUID? = nil
    @State private var dragStartX: CGFloat = 0
    @State private var slideStartTrimIn: Double = 0
    @State private var longPressLocation: CGFloat = 0
    @State private var longPressTimer: Timer? = nil

    private let labelWidth:  CGFloat = 52
    private let thumbHeight: CGFloat = 52
    private let handleWidth: CGFloat = 16

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
                    //    長押しジェスチャーはベースレイヤーに付けることで、
                    //    セグメントやトリムハンドルのジェスチャーと競合しない
                    thumbnailStrip(width: geo.size.width, dimmed: true)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    guard longPressTimer == nil else { return }
                                    longPressLocation = v.location.x
                                    let capturedWidth = geo.size.width
                                    longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
                                        Task { @MainActor in
                                            guard self.totalDuration > 0, capturedWidth > 0 else { return }
                                            let ratio = max(0, min(1, self.longPressLocation / capturedWidth))
                                            let seconds = Double(ratio) * self.totalDuration
                                            self.onAddSegment(seconds, capturedWidth)
                                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                            self.onTap()
                                        }
                                    }
                                }
                                .onEnded { _ in
                                    longPressTimer?.invalidate()
                                    longPressTimer = nil
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
                    // ③ トリムハンドル：編集モード かつ 対象セグメントのみ表示
                    if isEditing {
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
    // UIGraphicsImageRenderer でサムネイルを合成 → CGImage.cropping でクリップ
    // SwiftUI の mask/offset の座標系に依存しないため位置ズレが起きない

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

            // ① サムネイルストリップ全体を UIImage として合成
            let full = renderThumbnailStrip(
                totalWidth: width, height: thumbHeight,
                vStartX: vStartX, vWidth: vWidth
            )
            // ② inX〜outX の範囲だけ切り出して表示
            if let cropped = cropImage(full, fromX: inX, width: clipW, height: thumbHeight) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: inX, height: thumbHeight)
                    ZStack {
                        Image(uiImage: cropped)
                            .resizable()
                            .frame(width: clipW, height: thumbHeight)
                            .clipped()

                        // 選択中セグメントに青い枠を表示
                        if showBlueBorder && clipW > 0 {
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.cyan, lineWidth: 2)
                                .frame(width: clipW, height: thumbHeight)
                        }
                    }
                    .frame(width: clipW, height: thumbHeight)
                    // 青枠エリアをタップ → このセグメントを編集対象に選択
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSegmentTap?(seg.id)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: width, height: thumbHeight)
                .allowsHitTesting(onSegmentTap != nil)
            }
        }
    }

    /// サムネイルを横に並べた UIImage を生成（totalWidth × height のキャンバス上に vStartX から配置）
    private func renderThumbnailStrip(
        totalWidth: CGFloat, height: CGFloat,
        vStartX: CGFloat, vWidth: CGFloat
    ) -> UIImage {
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: max(totalWidth, 1), height: max(height, 1))
        )
        return renderer.image { _ in
            if thumbnails.isEmpty {
                UIColor.white.withAlphaComponent(0.15).setFill()
                UIRectFill(CGRect(x: vStartX, y: 0, width: vWidth, height: height))
            } else {
                let tw = vWidth / CGFloat(thumbnails.count)
                for (i, img) in thumbnails.enumerated() {
                    let rect = CGRect(x: vStartX + tw * CGFloat(i), y: 0,
                                      width: tw, height: height)
                    img.draw(in: rect)
                }
            }
        }
    }

    /// UIImage の x 位置から指定幅で切り出す
    private func cropImage(
        _ image: UIImage, fromX: CGFloat, width: CGFloat, height: CGFloat
    ) -> UIImage? {
        guard width > 0, height > 0 else { return nil }
        let s = image.scale
        let cropRect = CGRect(x: fromX * s, y: 0, width: width * s, height: height * s)
        guard let cg = image.cgImage?.cropping(to: cropRect) else { return nil }
        return UIImage(cgImage: cg, scale: s, orientation: image.imageOrientation)
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
                Path { path in
                    path.move(to: CGPoint(x: inX, y: 0))
                    path.addLine(to: CGPoint(x: outX, y: 0))
                    path.move(to: CGPoint(x: inX, y: thumbHeight))
                    path.addLine(to: CGPoint(x: outX, y: thumbHeight))
                }
                .stroke(Color.white.opacity(isDragging ? 1.0 : 0.7), lineWidth: isDragging ? 2 : 1.5)
                .allowsHitTesting(false)

                // IN点ハンドル：右端を inX に合わせる
                handleBar
                    .frame(width: handleWidth, height: thumbHeight)
                    .offset(x: inX - handleWidth)
                    .onTapGesture(count: 2) {
                        onDeleteSegment?(seg.id)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    .gesture(inHandleGesture(seg: seg, width: width))

                // OUT点ハンドル：左端を outX に合わせる
                handleBar
                    .frame(width: handleWidth, height: thumbHeight)
                    .offset(x: outX)
                    .onTapGesture(count: 2) {
                        onDeleteSegment?(seg.id)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    .gesture(outHandleGesture(seg: seg, width: width))

                // 中央エリア：スライドのみ（確定は別デバイス選択時）
                if rangeW > 0 {
                    Color.clear
                        .frame(width: rangeW, height: thumbHeight)
                        .offset(x: inX)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            onDeleteSegment?(seg.id)
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                        .gesture(slideGesture(seg: seg, width: width))
                }

                // IN点の蛍光青縦線
                Rectangle()
                    .fill(Color.cyan)
                    .frame(width: 1, height: thumbHeight)
                    .offset(x: inX)
                    .allowsHitTesting(false)

                // OUT点の蛍光青縦線
                Rectangle()
                    .fill(Color.cyan)
                    .frame(width: 1, height: thumbHeight)
                    .offset(x: outX - 1)
                    .allowsHitTesting(false)
            }
            .frame(width: width, height: thumbHeight)
        }
    }

    private var handleBar: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.black.opacity(0.35))
                    .frame(width: 2, height: 14)
            )
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
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if draggingID != seg.id {
                    draggingID = seg.id
                    dragStartX = seg.trimInRatio(total: totalDuration) * width
                }
                let absX   = dragStartX + v.translation.width
                let ratio  = max(0, min(1, absX / width))
                let newSec = Double(ratio) * totalDuration
                onTrimIn(seg.id, newSec)
            }
            .onEnded { _ in
                draggingID = nil
                dragStartX = 0
                // 確定はダブルタップで行うため、onEnded では何もしない
            }
    }

    private func outHandleGesture(seg: ClipSegment, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if draggingID != seg.id {
                    draggingID = seg.id
                    dragStartX = seg.trimOutRatio(total: totalDuration) * width
                }
                let absX   = dragStartX + v.translation.width
                let ratio  = max(0, min(1, absX / width))
                let newSec = Double(ratio) * totalDuration
                onTrimOut(seg.id, newSec)
            }
            .onEnded { _ in
                draggingID = nil
                dragStartX = 0
                // 確定はダブルタップで行うため、onEnded では何もしない
            }
    }

    private func slideGesture(seg: ClipSegment, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                if draggingID != seg.id {
                    draggingID = seg.id
                    slideStartTrimIn = seg.trimIn
                }
                let deltaSec  = Double(v.translation.width / width) * totalDuration
                let targetIn  = slideStartTrimIn + deltaSec
                let currentIn = seg.trimIn
                onSlide(seg.id, targetIn - currentIn)
            }
            .onEnded { _ in
                draggingID = nil
                slideStartTrimIn = 0
                // 確定はダブルタップで行うため、onEnded では何もしない
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

// MARK: - Comparable + clamped

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

