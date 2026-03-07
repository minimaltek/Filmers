//
//  CinecamExportEngine.swift
//  Cinecam
//
//  ExclusiveEditTimeline の編集結果を AVComposition で1本の動画に書き出す

import Foundation
import Combine
import AVFoundation
import CoreImage
import UIKit
import Photos

@MainActor
final class ExportEngine: ObservableObject {

    enum ExportState: Equatable {
        case idle
        case exporting(progress: Float)
        case done(url: URL)
        case failed(message: String)
    }

    @Published var state: ExportState = .idle

    private var exportSession: AVAssetExportSession?

    // MARK: - Public

    /// 書き出し実行 → カメラロールに保存
    /// - audioSource: nil = 編集に従う（カット毎の音声）、デバイス名 = そのデバイスの音声を全編に使用
    /// - pitchCents: ピッチシフト量（セント単位: 0 = 無効）
    func export(timeline: ExclusiveEditTimeline, videos: [String: URL], orientation: VideoOrientation = .cinema, audioSource: String? = nil, videoFilter: String? = nil, showWatermark: Bool = false, pitchCents: Float = 0) async {
        state = .exporting(progress: 0)

        do {
            let url = try await buildAndExport(timeline: timeline, videos: videos, orientation: orientation, audioSource: audioSource, videoFilter: videoFilter, showWatermark: showWatermark, pitchCents: pitchCents)
            // カメラロールに保存（失敗したら .done には絶対到達しない）
            do {
                try await saveToPhotoLibrary(url: url)
            } catch {
                try? FileManager.default.removeItem(at: url)
                state = .failed(message: error.localizedDescription)
                return
            }
            // 保存成功 → 一時ファイルを削除して完了
            try? FileManager.default.removeItem(at: url)
            state = .done(url: url)
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    func cancel() {
        exportSession?.cancelExport()
        state = .idle
    }

    // MARK: - カメラロール保存

    private func saveToPhotoLibrary(url: URL) async throws {
        // 権限確認
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ExportError.photoLibraryDenied
        }
        // PHPhotosErrorDomain 3302 等が来ることがあるのでここで catch して再スロー
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
        } catch {
            // 権限エラー (3302) はより分かりやすいメッセージに置き換える
            let nsError = error as NSError
            if nsError.domain == "PHPhotosErrorDomain" && nsError.code == 3302 {
                throw ExportError.photoLibraryDenied
            }
            throw error
        }
    }

    // MARK: - Private

    private func buildAndExport(
        timeline: ExclusiveEditTimeline,
        videos: [String: URL],
        orientation: VideoOrientation = .cinema,
        audioSource: String? = nil,
        videoFilter: String? = nil,
        showWatermark: Bool = false,
        pitchCents: Float = 0
    ) async throws -> URL {

        // ① 使用するセグメントを trimIn 順に並べる
        struct EditClip {
            let url: URL
            let sourceIn: CMTime
            let sourceOut: CMTime
            let trimIn: Double
        }

        var clips: [EditClip] = []
        for device in timeline.devices {
            guard let url = videos[device] else { continue }
            for seg in timeline.segments(for: device) where seg.isValid {
                clips.append(EditClip(
                    url:       url,
                    sourceIn:  CMTimeMakeWithSeconds(seg.sourceInTime,  preferredTimescale: 600),
                    sourceOut: CMTimeMakeWithSeconds(seg.sourceOutTime, preferredTimescale: 600),
                    trimIn:    seg.trimIn
                ))
            }
        }

        let orderedClips = clips.sorted { $0.trimIn < $1.trimIn }

        guard !orderedClips.isEmpty else {
            throw ExportError.noClips
        }

        // ② Determine render size from orientation
        //    Use the first clip to get a base resolution, then apply target aspect ratio
        let renderSize = try await computeRenderSize(
            firstClipURL: orderedClips[0].url,
            orientation: orientation
        )

        // ③ AVMutableComposition + per-clip instructions
        let composition = AVMutableComposition()
        let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )!
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )!

        // Track each clip's position in the composition timeline
        struct ClipRange {
            let compositionStart: CMTime
            let duration: CMTime
            let url: URL
        }
        var clipRanges: [ClipRange] = []
        var cursor = CMTime.zero

        // ③-a 映像クリップを composition に挿入
        for clip in orderedClips {
            let asset = AVURLAsset(url: clip.url)
            let duration = clip.sourceOut - clip.sourceIn
            let timeRange = CMTimeRange(start: clip.sourceIn, duration: duration)

            if let srcVideo = try? await asset.loadTracks(withMediaType: .video).first {
                try videoTrack.insertTimeRange(timeRange, of: srcVideo, at: cursor)
            }

            clipRanges.append(ClipRange(compositionStart: cursor, duration: duration, url: clip.url))
            cursor = cursor + duration
        }

        // ③-b 音声トラックを構築
        if let audioDevice = audioSource, let audioURL = videos[audioDevice] {
            // 特定デバイスの音声を使用: 各クリップの区間に対応する音声を挿入
            let audioAsset = AVURLAsset(url: audioURL)
            if let srcAudioTrack = try? await audioAsset.loadTracks(withMediaType: .audio).first {
                let audioAssetDuration = CMTimeGetSeconds(try await audioAsset.load(.duration))
                let audioVideoStart = timeline.videoRangeByDevice[audioDevice]?.start ?? 0

                var audioCursor = CMTime.zero
                for clip in orderedClips {
                    let clipDur = clip.sourceOut - clip.sourceIn
                    // clip.trimIn（タイムライン上の絶対位置）を音声ソースファイル内の時間に変換
                    let audioSrcTime = clip.trimIn - audioVideoStart
                    let durationSec = CMTimeGetSeconds(clipDur)
                    let safeStart = max(audioSrcTime, 0)
                    let clampedEnd = min(safeStart + durationSec, audioAssetDuration)
                    let clampedDur = max(clampedEnd - safeStart, 0)

                    if clampedDur > 0.01 {
                        let audioRange = CMTimeRange(
                            start: CMTimeMakeWithSeconds(safeStart, preferredTimescale: 600),
                            duration: CMTimeMakeWithSeconds(clampedDur, preferredTimescale: 600)
                        )
                        do {
                            try audioTrack.insertTimeRange(audioRange, of: srcAudioTrack, at: audioCursor)
                        } catch {
                            #if DEBUG
                            print("⚠️ [Export] Audio insert failed at \(safeStart)s: \(error.localizedDescription)")
                            #endif
                        }
                    }
                    audioCursor = audioCursor + clipDur
                }
            }
        } else {
            // 編集に従う: 各クリップ自身の音声を使用
            var audioCursor = CMTime.zero
            for clip in orderedClips {
                let asset = AVURLAsset(url: clip.url)
                let duration = clip.sourceOut - clip.sourceIn
                let timeRange = CMTimeRange(start: clip.sourceIn, duration: duration)
                if let srcAudio = try? await asset.loadTracks(withMediaType: .audio).first {
                    try? audioTrack.insertTimeRange(timeRange, of: srcAudio, at: audioCursor)
                }
                audioCursor = audioCursor + duration
            }
        }

        // 音声トラックが空なら削除（空トラックがあるとエクスポートが失敗する場合がある）
        if audioTrack.timeRange.duration == .zero {
            composition.removeTrack(audioTrack)
        }

        // ③-c ピッチシフト適用: composition の音声を書き出し → オフラインピッチ処理 → 差し替え
        if pitchCents != 0, audioTrack.timeRange.duration != .zero {
            let pitchedURL = try await renderPitchShiftedAudio(
                composition: composition,
                audioTrack: audioTrack,
                pitchCents: pitchCents
            )
            // 元の音声トラックを削除し、ピッチ済み音声で差し替え
            composition.removeTrack(audioTrack)
            let newAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )!
            let pitchedAsset = AVURLAsset(url: pitchedURL)
            if let pitchedSrc = try? await pitchedAsset.loadTracks(withMediaType: .audio).first {
                let pitchedDuration = try await pitchedAsset.load(.duration)
                try newAudioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: pitchedDuration),
                    of: pitchedSrc,
                    at: .zero
                )
            }
            // 一時ファイルは後で削除
            try? FileManager.default.removeItem(at: pitchedURL)
        }

        // ④ Build per-clip video composition instructions
        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize = renderSize
        videoComp.frameDuration = CMTimeMake(value: 1, timescale: 30)

        guard let compTrack = composition.tracks(withMediaType: .video).first else {
            throw ExportError.sessionFailed
        }

        // Cache transforms per URL to avoid redundant loading
        var transformCache: [URL: CGAffineTransform] = [:]
        var instructions: [AVMutableVideoCompositionInstruction] = []

        for range in clipRanges {
            let transform: CGAffineTransform
            if let cached = transformCache[range.url] {
                transform = cached
            } else {
                transform = try await computeCropTransform(
                    videoURL: range.url,
                    renderSize: renderSize,
                    orientation: orientation
                )
                transformCache[range.url] = transform
            }

            let instr = AVMutableVideoCompositionInstruction()
            instr.timeRange = CMTimeRange(start: range.compositionStart, duration: range.duration)
            let layerInstr = AVMutableVideoCompositionLayerInstruction(assetTrack: compTrack)
            layerInstr.setTransform(transform, at: .zero)
            instr.layerInstructions = [layerInstr]
            instructions.append(instr)
        }

        // 最後の instruction がコンポジション全体を確実にカバーするよう調整
        // （CMTime の丸め誤差で末尾に隙間ができると "Operation Stopped" エラーになる）
        if let lastInstr = instructions.last {
            let compEnd = cursor  // composition の合計長
            let instrEnd = lastInstr.timeRange.start + lastInstr.timeRange.duration
            if instrEnd < compEnd {
                lastInstr.timeRange = CMTimeRange(
                    start: lastInstr.timeRange.start,
                    duration: compEnd - lastInstr.timeRange.start
                )
            }
        }

        videoComp.instructions = instructions

        // ④-b 常に videoComp（layerInstructions で回転・スケール済み）を使用。
        //   フィルタ・透かしが必要な場合は 2パス方式:
        //   1パス目: videoComp で回転済み中間ファイルを書き出し
        //   2パス目: 中間ファイルに CIFilter + 透かしを適用
        let needsSecondPass = videoFilter != nil || showWatermark

        // ⑤ Export (1パス目: 回転・クロップ済み)
        let pass1URL = needsSecondPass
            ? FileManager.default.temporaryDirectory.appendingPathComponent("cinecam_pass1_\(Int(Date().timeIntervalSince1970)).mp4")
            : FileManager.default.temporaryDirectory.appendingPathComponent("cinecam_export_\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: pass1URL)

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ExportError.sessionFailed
        }

        session.outputURL = pass1URL
        session.outputFileType = .mp4
        session.videoComposition = videoComp
        session.shouldOptimizeForNetworkUse = !needsSecondPass

        self.exportSession = session

        let progressTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run {
                    if case .exporting = self?.state {
                        // 2パスの場合、1パス目は進捗の 0〜50%
                        let raw = session.progress
                        let adjusted = needsSecondPass ? raw * 0.5 : raw
                        self?.state = .exporting(progress: adjusted)
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        await session.export()
        progressTask.cancel()

        switch session.status {
        case .completed:
            break
        case .cancelled:
            throw ExportError.cancelled
        default:
            #if DEBUG
            if let err = session.error {
                print("⚠️ [Export] pass1 failed: \(err)")
                print("⚠️ [Export] renderSize=\(renderSize), clips=\(orderedClips.count), cursor=\(CMTimeGetSeconds(cursor))s")
            }
            #endif
            throw session.error ?? ExportError.sessionFailed
        }

        // 2パス目不要ならそのまま返す
        guard needsSecondPass else { return pass1URL }

        // ⑥ 2パス目: 回転済み中間ファイルに CIFilter + 透かしを適用
        let finalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cinecam_export_\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: finalURL)

        let pass1Asset = AVURLAsset(url: pass1URL)
        let watermarkImage = showWatermark ? Self.renderWatermarkCIImage(size: renderSize) : nil

        let ciComp = try await AVMutableVideoComposition.videoComposition(
            with: pass1Asset,
            applyingCIFiltersWithHandler: { request in
                var image = request.sourceImage

                // フィルタ適用
                if let filterName = videoFilter, let ciFilter = CIFilter(name: filterName) {
                    ciFilter.setValue(image, forKey: kCIInputImageKey)
                    if let filtered = ciFilter.outputImage {
                        image = filtered.cropped(to: request.sourceImage.extent)
                    }
                }

                // 透かし合成
                if let wm = watermarkImage {
                    image = wm.composited(over: image)
                }

                request.finish(with: image, context: nil)
            }
        )

        guard let session2 = AVAssetExportSession(
            asset: pass1Asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            try? FileManager.default.removeItem(at: pass1URL)
            throw ExportError.sessionFailed
        }

        session2.outputURL = finalURL
        session2.outputFileType = .mp4
        session2.videoComposition = ciComp
        session2.shouldOptimizeForNetworkUse = true

        self.exportSession = session2

        let progressTask2 = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run {
                    if case .exporting = self?.state {
                        self?.state = .exporting(progress: 0.5 + session2.progress * 0.5)
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        await session2.export()
        progressTask2.cancel()

        // 中間ファイルを削除
        try? FileManager.default.removeItem(at: pass1URL)

        switch session2.status {
        case .completed:
            return finalURL
        case .cancelled:
            throw ExportError.cancelled
        default:
            #if DEBUG
            if let err = session2.error {
                print("⚠️ [Export] pass2 failed: \(err)")
            }
            #endif
            throw session2.error ?? ExportError.sessionFailed
        }
    }

    // MARK: - Pitch Shift (Offline Render)

    /// composition の音声トラックをピッチシフト済み M4A にオフラインレンダリングする
    private func renderPitchShiftedAudio(
        composition: AVMutableComposition,
        audioTrack: AVMutableCompositionTrack,
        pitchCents: Float
    ) async throws -> URL {
        // 1) composition の音声だけを一時 M4A に書き出す
        let tempAudioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pitch_src_\(Int(Date().timeIntervalSince1970)).m4a")
        try? FileManager.default.removeItem(at: tempAudioURL)

        // 音声だけの composition を作成
        let audioComp = AVMutableComposition()
        let tempTrack = audioComp.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        )!
        try tempTrack.insertTimeRange(audioTrack.timeRange, of: audioTrack, at: .zero)

        guard let audioExport = AVAssetExportSession(
            asset: audioComp, presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ExportError.sessionFailed
        }
        audioExport.outputURL = tempAudioURL
        audioExport.outputFileType = .m4a
        await audioExport.export()
        guard audioExport.status == .completed else {
            throw audioExport.error ?? ExportError.sessionFailed
        }

        // 2) AVAudioEngine でオフラインレンダリング（ピッチシフト適用）
        let pitchedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pitch_out_\(Int(Date().timeIntervalSince1970)).caf")
        try? FileManager.default.removeItem(at: pitchedURL)

        // バックグラウンドで実行
        let srcURL = tempAudioURL
        let outURL = pitchedURL
        let cents = pitchCents
        try await Task.detached(priority: .userInitiated) {
            let srcFile = try AVAudioFile(forReading: srcURL)
            let format = srcFile.processingFormat
            let totalFrames = srcFile.length

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let timePitch = AVAudioUnitTimePitch()
            timePitch.pitch = cents
            timePitch.rate = 1.0

            engine.attach(player)
            engine.attach(timePitch)
            engine.connect(player, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)

            // オフラインレンダリング用にマニュアルレンダリングモードで起動
            try engine.enableManualRenderingMode(.offline, format: format,
                                                  maximumFrameCount: 4096)
            try engine.start()
            player.play()

            // ソースファイル全体をスケジュール
            player.scheduleFile(srcFile, at: nil)

            let outFile = try AVAudioFile(forWriting: outURL, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                          frameCapacity: engine.manualRenderingMaximumFrameCount)!

            // レンダリングループ
            var framesRendered: AVAudioFramePosition = 0
            while framesRendered < totalFrames {
                let status = try engine.renderOffline(engine.manualRenderingMaximumFrameCount,
                                                      to: buffer)
                switch status {
                case .success:
                    try outFile.write(from: buffer)
                    framesRendered += Int64(buffer.frameLength)
                case .insufficientDataFromInputNode:
                    // 入力データ待ち — 少し続ける
                    framesRendered += Int64(buffer.frameLength)
                case .cannotDoInCurrentContext:
                    continue
                case .error:
                    throw ExportError.sessionFailed
                @unknown default:
                    break
                }
            }

            engine.stop()
            player.stop()
        }.value

        // 一時ソースファイルを削除
        try? FileManager.default.removeItem(at: tempAudioURL)

        return pitchedURL
    }

    // MARK: - Render Size

    /// Compute the output render size based on the first clip's resolution and the target aspect ratio.
    private func computeRenderSize(
        firstClipURL: URL,
        orientation: VideoOrientation
    ) async throws -> CGSize {
        let asset = AVURLAsset(url: firstClipURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return CGSize(width: 1920, height: 804) // fallback cinema
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let applied = naturalSize.applying(transform)
        let w = abs(applied.width)
        let h = abs(applied.height)

        let targetRatio = orientation.aspectRatio
        let sourceRatio = w / h
        let tolerance: CGFloat = 0.05

        // 偶数ピクセルに丸める（H.264/HEVC エンコーダの要件）
        func roundToEven(_ v: CGFloat) -> CGFloat { CGFloat(Int(v / 2) * 2) }

        if abs(sourceRatio - targetRatio) < tolerance {
            return CGSize(width: roundToEven(w), height: roundToEven(h))
        } else if targetRatio > sourceRatio {
            // Crop top/bottom
            return CGSize(width: roundToEven(w), height: roundToEven(w / targetRatio))
        } else {
            // Crop left/right
            return CGSize(width: roundToEven(h * targetRatio), height: roundToEven(h))
        }
    }

    // MARK: - Per-Clip Transform

    /// Compute the transform that maps a specific video's native frame into the target renderSize.
    /// Handles videos with different orientations/sizes by scaling + centering + cropping.
    private func computeCropTransform(
        videoURL: URL,
        renderSize: CGSize,
        orientation: VideoOrientation
    ) async throws -> CGAffineTransform {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return .identity
        }
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)

        // preferredTransform を正規化: 回転後の原点を (0,0) に補正する
        // iPhoneの動画は preferredTransform に translation 成分が含まれるが、
        // そのまま scale と連結すると translation もスケールされてずれる
        let applied = naturalSize.applying(preferredTransform)
        let srcW = abs(applied.width)
        let srcH = abs(applied.height)

        // preferredTransform 適用後の矩形の origin を (0,0) にする補正 translation
        let appliedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let normalizedTransform = preferredTransform
            .concatenating(CGAffineTransform(translationX: -appliedRect.origin.x, y: -appliedRect.origin.y))

        let outW = renderSize.width
        let outH = renderSize.height

        // Scale to cover the render size (fill, not fit) then center-crop
        let scaleX = outW / srcW
        let scaleY = outH / srcH
        let scale = max(scaleX, scaleY) // "cover" scale

        let scaledW = srcW * scale
        let scaledH = srcH * scale
        let tx = (outW - scaledW) / 2.0
        let ty = (outH - scaledH) / 2.0

        // Final transform:
        // 1. preferredTransform で回転（原点補正済み）→ srcW x srcH の正しい向きに
        // 2. scale で renderSize を埋めるサイズに拡縮
        // 3. translate でセンタリング
        let cropTransform = normalizedTransform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: tx, y: ty))

        return cropTransform
    }

    // MARK: - Watermark

    /// 透かし用の CIImage を生成（右下に「CINECAM.」ロゴテキスト）
    /// 接続画面と同じフォントスタイル（black weight, compressed width）を使用
    /// renderSize に合わせてフォントサイズを自動調整する
    private static func renderWatermarkCIImage(size: CGSize) -> CIImage? {
        let fontSize = max(size.width * 0.03, 16)
        let margin = size.width * 0.025

        // 接続画面と同じ compressed black フォント
        let fontDescriptor = UIFont.systemFont(ofSize: fontSize, weight: .black).fontDescriptor
            .withDesign(.default)!
            .withSymbolicTraits(.traitCondensed)!
        let font = UIFont(descriptor: fontDescriptor, size: fontSize)

        let text = "CINECAM."
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white.withAlphaComponent(0.5),
            .kern: -0.5 as NSNumber,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)

        // 影付きでテキストを描画
        let renderer = UIGraphicsImageRenderer(size: size)
        let uiImage = renderer.image { ctx in
            let context = ctx.cgContext

            // 影を設定
            context.setShadow(
                offset: CGSize(width: 1, height: -1),
                blur: 3,
                color: UIColor.black.withAlphaComponent(0.7).cgColor
            )

            // テキスト位置（右下、マージン付き）
            // ★ CIImage は Y-up 座標系なので、UIKit で「上側」に描画すると
            //   CIImage では「下側」（= 動画の右下）になる
            let x = size.width - textSize.width - margin
            let drawY = margin  // UIKit の上側 = CIImage の下側
            (text as NSString).draw(
                at: CGPoint(x: x, y: drawY),
                withAttributes: attributes
            )
        }

        guard let cgImage = uiImage.cgImage else { return nil }
        return CIImage(cgImage: cgImage)
    }

    // MARK: - Errors

    enum ExportError: LocalizedError {
        case noClips
        case sessionFailed
        case cancelled
        case photoLibraryDenied

        var errorDescription: String? {
            switch self {
            case .noClips:            return "No clips to export"
            case .sessionFailed:      return "Failed to create export session"
            case .cancelled:          return "Export was cancelled"
            case .photoLibraryDenied: return "Photo library access denied. Please allow access in Settings."
            }
        }
    }
}
