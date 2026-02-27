//
//  CinecamExportEngine.swift
//  Cinecam
//
//  ExclusiveEditTimeline の編集結果を AVComposition で1本の動画に書き出す

import Foundation
import Combine
import AVFoundation
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
    func export(timeline: ExclusiveEditTimeline, videos: [String: URL], orientation: VideoOrientation = .cinema) async {
        state = .exporting(progress: 0)

        do {
            let url = try await buildAndExport(timeline: timeline, videos: videos, orientation: orientation)
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
        orientation: VideoOrientation = .cinema
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

        for clip in orderedClips {
            let asset = AVURLAsset(url: clip.url)
            let duration = clip.sourceOut - clip.sourceIn
            let timeRange = CMTimeRange(start: clip.sourceIn, duration: duration)

            if let srcVideo = try? await asset.loadTracks(withMediaType: .video).first {
                try videoTrack.insertTimeRange(timeRange, of: srcVideo, at: cursor)
            }
            if let srcAudio = try? await asset.loadTracks(withMediaType: .audio).first {
                try? audioTrack.insertTimeRange(timeRange, of: srcAudio, at: cursor)
            }

            clipRanges.append(ClipRange(compositionStart: cursor, duration: duration, url: clip.url))
            cursor = cursor + duration
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

        videoComp.instructions = instructions

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
        session.videoComposition = videoComp
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

        if abs(sourceRatio - targetRatio) < tolerance {
            return CGSize(width: w, height: h)
        } else if targetRatio > sourceRatio {
            // Crop top/bottom
            return CGSize(width: w, height: w / targetRatio)
        } else {
            // Crop left/right
            return CGSize(width: h * targetRatio, height: h)
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
