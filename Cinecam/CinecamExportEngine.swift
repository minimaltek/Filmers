//
//  CinecamExportEngine.swift
//  Cinecam
//
//  ExclusiveEditTimeline の編集結果を AVComposition で1本の動画に書き出す

import Foundation
import Combine
import AVFoundation
import CoreImage
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
    func export(timeline: ExclusiveEditTimeline, videos: [String: URL], orientation: VideoOrientation = .cinema, audioSource: String? = nil, videoFilter: String? = nil) async {
        state = .exporting(progress: 0)

        do {
            let url = try await buildAndExport(timeline: timeline, videos: videos, orientation: orientation, audioSource: audioSource, videoFilter: videoFilter)
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
        videoFilter: String? = nil
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

        // 音声ソースが指定されている場合、そのデバイスの音声トラックと長さを事前に取得
        let audioSourceTrack: AVAssetTrack?
        let audioSourceDuration: Double  // 音声ソースアセットの長さ（秒）
        let audioVideoStart: Double      // タイムライン上の開始位置
        if let audioDevice = audioSource, let audioURL = videos[audioDevice] {
            let asset = AVURLAsset(url: audioURL)
            let loadedAudioTracks = try await asset.loadTracks(withMediaType: .audio)
            audioSourceTrack = loadedAudioTracks.first
            // 音声トラック自体の長さを使用（動画全体の duration より正確）
            if let aTrack = audioSourceTrack {
                let audioTimeRange = try await aTrack.load(.timeRange)
                audioSourceDuration = CMTimeGetSeconds(audioTimeRange.start + audioTimeRange.duration)
            } else {
                audioSourceDuration = CMTimeGetSeconds(try await asset.load(.duration))
            }
            audioVideoStart = timeline.videoRangeByDevice[audioDevice]?.start ?? 0
            #if DEBUG
            print("🔊 [Export] audioSource=\(audioDevice), audioTracks=\(loadedAudioTracks.count), duration=\(audioSourceDuration)s, videoStart=\(audioVideoStart)s")
            #endif
        } else {
            audioSourceTrack = nil
            audioSourceDuration = 0
            audioVideoStart = 0
        }

        for clip in orderedClips {
            let asset = AVURLAsset(url: clip.url)
            let duration = clip.sourceOut - clip.sourceIn
            let timeRange = CMTimeRange(start: clip.sourceIn, duration: duration)

            if let srcVideo = try? await asset.loadTracks(withMediaType: .video).first {
                try videoTrack.insertTimeRange(timeRange, of: srcVideo, at: cursor)
            }

            if let srcAudioTrack = audioSourceTrack {
                // 特定デバイスの音声を使用: clip の trimIn を音声ソースのソース時間に変換
                let audioSrcTime = clip.trimIn - audioVideoStart
                let durationSec = CMTimeGetSeconds(duration)
                #if DEBUG
                print("🔊 [Export] clip trimIn=\(clip.trimIn), audioSrcTime=\(audioSrcTime), dur=\(durationSec), audioDur=\(audioSourceDuration)")
                #endif
                // 音声ソースの範囲内かチェック（負の値や範囲超過はスキップ）
                var audioInserted = false
                if audioSrcTime >= -0.01 {
                    // 音声アセットの実際の長さに収まるようクランプ
                    let safeStart = max(audioSrcTime, 0)
                    let clampedEnd = min(safeStart + durationSec, audioSourceDuration)
                    let clampedDur = max(clampedEnd - safeStart, 0)
                    if clampedDur > 0.001 {
                        let clampedDuration = CMTimeMakeWithSeconds(clampedDur, preferredTimescale: 600)
                        let audioTimeRange = CMTimeRange(
                            start: CMTimeMakeWithSeconds(safeStart, preferredTimescale: 600),
                            duration: clampedDuration
                        )
                        do {
                            try audioTrack.insertTimeRange(audioTimeRange, of: srcAudioTrack, at: cursor)
                            audioInserted = true
                            // クランプで短くなった分を空区間で埋める
                            let shortfall = duration - clampedDuration
                            if CMTimeGetSeconds(shortfall) > 0.001 {
                                audioTrack.insertEmptyTimeRange(CMTimeRange(start: cursor + clampedDuration, duration: shortfall))
                            }
                        } catch {
                            #if DEBUG
                            print("⚠️ [Export] Audio insert failed at \(safeStart): \(error.localizedDescription)")
                            #endif
                        }
                    }
                }
                if !audioInserted {
                    // 範囲外 or 挿入失敗: 無音の空区間を挿入（ギャップ防止）
                    audioTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: duration))
                }
            } else if let srcAudio = try? await asset.loadTracks(withMediaType: .audio).first {
                // 編集に従う: 各クリップ自身の音声を使用
                try? audioTrack.insertTimeRange(timeRange, of: srcAudio, at: cursor)
            }

            clipRanges.append(ClipRange(compositionStart: cursor, duration: duration, url: clip.url))
            cursor = cursor + duration
        }

        // 音声トラックが空の場合は削除（空トラックがあるとエクスポートが失敗する場合がある）
        if audioTrack.timeRange.duration == .zero {
            composition.removeTrack(audioTrack)
        } else {
            // 音声トラックの長さが映像トラックと一致しない場合、
            // 不足分を空区間で埋める（不一致だと "Operation Stopped" エラーになる）
            let videoDuration = videoTrack.timeRange.duration
            let audioDuration = audioTrack.timeRange.duration
            let gap = videoDuration - audioDuration
            if CMTimeGetSeconds(gap) > 0.001 {
                audioTrack.insertEmptyTimeRange(CMTimeRange(start: audioDuration, duration: gap))
                #if DEBUG
                print("🔊 [Export] Audio track shorter than video by \(CMTimeGetSeconds(gap))s — padded with silence")
                #endif
            }
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

        // ④-b フィルタ付きの場合は applyingCIFiltersWithHandler で CIFilter を適用
        // layerInstruction の transform は applyingCIFiltersWithHandler では無視されるため、
        // ハンドラー内で CIAffineTransform + 選択フィルタを一括適用する
        let finalVideoComp: AVVideoComposition
        if let filterName = videoFilter {
            // クリップごとの transform と時間範囲をキャプチャ用にコピー
            let capturedRanges = clipRanges
            let capturedTransforms = transformCache
            let size = renderSize
            finalVideoComp = AVVideoComposition(asset: composition) { request in
                var image = request.sourceImage.clampedToExtent()

                // 現在の時刻に対応するクリップの transform を適用
                let timeSec = CMTimeGetSeconds(request.compositionTime)
                if let range = capturedRanges.first(where: {
                    let start = CMTimeGetSeconds($0.compositionStart)
                    let dur = CMTimeGetSeconds($0.duration)
                    return timeSec >= start && timeSec < start + dur + 0.01
                }), let transform = capturedTransforms[range.url] {
                    image = image.transformed(by: transform)
                }

                // renderSize でクロップ
                image = image.cropped(to: CGRect(origin: .zero, size: size))

                // 選択フィルタを適用
                if let ciFilter = CIFilter(name: filterName) {
                    ciFilter.setValue(image, forKey: kCIInputImageKey)
                    if let filtered = ciFilter.outputImage {
                        image = filtered.cropped(to: CGRect(origin: .zero, size: size))
                    }
                }

                request.finish(with: image, context: nil)
            }
        } else {
            finalVideoComp = videoComp
        }

        // ⑤ Export
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cinecam_export_\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ExportError.sessionFailed
        }

        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.videoComposition = finalVideoComp
        session.shouldOptimizeForNetworkUse = true

        self.exportSession = session

        let progressTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run {
                    if case .exporting = self?.state {
                        self?.state = .exporting(progress: session.progress)
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        await session.export()
        progressTask.cancel()

        switch session.status {
        case .completed:
            return outputURL
        case .cancelled:
            throw ExportError.cancelled
        default:
            #if DEBUG
            if let err = session.error {
                print("⚠️ [Export] session failed: \(err)")
                print("⚠️ [Export] renderSize=\(renderSize), clips=\(orderedClips.count), cursor=\(CMTimeGetSeconds(cursor))s")
            }
            #endif
            throw session.error ?? ExportError.sessionFailed
        }
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

        // The "applied" size is how the video actually appears after its preferred transform
        let applied = naturalSize.applying(preferredTransform)
        let srcW = abs(applied.width)
        let srcH = abs(applied.height)

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

        // Final transform: first apply the video's preferred transform (rotation etc.),
        // then scale to cover, then translate to center
        let cropTransform = preferredTransform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: tx, y: ty))

        return cropTransform
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
