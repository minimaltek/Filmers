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
    func export(timeline: ExclusiveEditTimeline, videos: [String: URL], orientation: VideoOrientation = .cinema, audioSource: String? = nil, videoFilter: String? = nil, showWatermark: Bool = false, pitchCents: Float = 0, kaleidoscopeType: String? = nil, kaleidoscopeSize: Float = 200, kaleidoscopeCenterX: Float = 0.5, kaleidoscopeCenterY: Float = 0.5, tileHeight: Float = 200, mirrorDirection: Int = 0, rotationAngle: Float = 0, filterIntensity: Float = 1.0, segmentFilterSettings: [UUID: SegmentFilterSettings] = [:], speedRate: Float = 1.0, noSoundExport: Bool = false) async {
        state = .exporting(progress: 0)

        do {
            let url = try await buildAndExport(timeline: timeline, videos: videos, orientation: orientation, audioSource: audioSource, videoFilter: videoFilter, showWatermark: showWatermark, pitchCents: pitchCents, kaleidoscopeType: kaleidoscopeType, kaleidoscopeSize: kaleidoscopeSize, kaleidoscopeCenterX: kaleidoscopeCenterX, kaleidoscopeCenterY: kaleidoscopeCenterY, tileHeight: tileHeight, mirrorDirection: mirrorDirection, rotationAngle: rotationAngle, filterIntensity: filterIntensity, segmentFilterSettings: segmentFilterSettings, speedRate: speedRate, noSoundExport: noSoundExport)
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
        pitchCents: Float = 0,
        kaleidoscopeType: String? = nil,
        kaleidoscopeSize: Float = 200,
        kaleidoscopeCenterX: Float = 0.5,
        kaleidoscopeCenterY: Float = 0.5,
        tileHeight: Float = 200,
        mirrorDirection: Int = 0,
        rotationAngle: Float = 0,
        filterIntensity: Float = 1.0,
        segmentFilterSettings: [UUID: SegmentFilterSettings] = [:],
        speedRate: Float = 1.0,
        noSoundExport: Bool = false
    ) async throws -> URL {

        // ① 使用するセグメントを trimIn 順に並べる
        struct EditClip {
            let url: URL
            let sourceIn: CMTime
            let sourceOut: CMTime
            let trimIn: Double
            let segmentID: UUID
        }

        var clips: [EditClip] = []
        for device in timeline.devices {
            guard let url = videos[device] else { continue }
            for seg in timeline.segments(for: device) where seg.isValid {
                clips.append(EditClip(
                    url:       url,
                    sourceIn:  CMTimeMakeWithSeconds(seg.sourceInTime,  preferredTimescale: 600),
                    sourceOut: CMTimeMakeWithSeconds(seg.sourceOutTime, preferredTimescale: 600),
                    trimIn:    seg.trimIn,
                    segmentID: seg.id
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
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw ExportError.compositionFailed("videoTrack の作成に失敗しました") }
        guard let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw ExportError.compositionFailed("audioTrack の作成に失敗しました") }

        // Track each clip's position in the composition timeline
        struct ClipRange {
            let compositionStart: CMTime
            let duration: CMTime
            let url: URL
            let segmentID: UUID
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

            clipRanges.append(ClipRange(compositionStart: cursor, duration: duration, url: clip.url, segmentID: clip.segmentID))
            cursor = cursor + duration
        }

        // ③-b 音声トラックを構築
        // noSoundExport = true のとき（グローバル NO SOUND）は音声トラックを一切追加しない
        if noSoundExport {
            composition.removeTrack(audioTrack)
        } else if let audioDevice = audioSource, let audioURL = videos[audioDevice] {
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
            // ただし segmentFilterSettings で noSound = true のセグメントは無音（無音区間を挿入）
            var audioCursor = CMTime.zero
            for clip in orderedClips {
                let duration = clip.sourceOut - clip.sourceIn
                let isNoSound = segmentFilterSettings[clip.segmentID]?.noSound ?? false
                if !isNoSound {
                    let asset = AVURLAsset(url: clip.url)
                    let timeRange = CMTimeRange(start: clip.sourceIn, duration: duration)
                    if let srcAudio = try? await asset.loadTracks(withMediaType: .audio).first {
                        try? audioTrack.insertTimeRange(timeRange, of: srcAudio, at: audioCursor)
                    }
                }
                // noSound セグメントは音声を挿入せず cursor だけ進める（無音区間になる）
                audioCursor = audioCursor + duration
            }
        }

        // 音声トラックが空なら削除（空トラックがあるとエクスポートが失敗する場合がある）
        if audioTrack.timeRange.duration == .zero {
            composition.removeTrack(audioTrack)
        }

        // ③-c スピード変更: セグメント単位で scaleTimeRange を適用
        //     ★ ピッチシフトより先に適用する（scaleTimeRange は映像+音声両方に作用するため、
        //       先にピッチ差し替えすると音声長のずれで scaleTimeRange が失敗する）
        //     後ろのセグメントから処理することで、先に処理したスケーリングが後続に影響しない
        do {
            // 各セグメントの速度を決定（セグメント固有 > グローバル speedRate）
            var segmentSpeeds: [(index: Int, rate: Float)] = []
            for (i, range) in clipRanges.enumerated() {
                let segSpeed = segmentFilterSettings[range.segmentID]?.speedRate ?? speedRate
                if segSpeed != 1.0, segSpeed > 0 {
                    segmentSpeeds.append((i, segSpeed))
                }
            }

            // 後ろから処理（scaleTimeRange は時間軸を伸縮するので前から処理すると位置がずれる）
            for (i, rate) in segmentSpeeds.sorted(by: { $0.index > $1.index }) {
                let range = clipRanges[i]
                // 安全チェック: composition の duration を超えないようにクランプ
                let compDuration = composition.duration
                let clampedStart = CMTimeMinimum(range.compositionStart, compDuration)
                let maxDuration = compDuration - clampedStart
                let clampedDuration = CMTimeMinimum(range.duration, maxDuration)

                guard CMTimeGetSeconds(clampedDuration) > 0.001 else { continue }

                let originalTimeRange = CMTimeRange(start: clampedStart, duration: clampedDuration)
                let scaledDuration = CMTimeMultiplyByFloat64(clampedDuration, multiplier: Float64(1.0 / rate))
                composition.scaleTimeRange(originalTimeRange, toDuration: scaledDuration)

                // clipRanges を再計算: このセグメントの duration が変わり、以降のセグメントの開始位置もずれる
                let durationDelta = scaledDuration - clampedDuration
                clipRanges[i] = ClipRange(
                    compositionStart: clampedStart,
                    duration: scaledDuration,
                    url: range.url,
                    segmentID: range.segmentID
                )
                // 後続セグメントの開始位置をずらす
                for j in (i + 1)..<clipRanges.count {
                    let r = clipRanges[j]
                    clipRanges[j] = ClipRange(
                        compositionStart: r.compositionStart + durationDelta,
                        duration: r.duration,
                        url: r.url,
                        segmentID: r.segmentID
                    )
                }
                cursor = cursor + durationDelta
            }
        }

        // ③-d ピッチシフト適用: composition の音声を書き出し → オフラインピッチ処理 → 差し替え
        //     ★ scaleTimeRange 後に実行する（スピード変更済みの音声をピッチシフトする）
        //     セグメント固有 pitchCents が設定されている場合はグローバル pitchCents より優先する
        //     （複数のセグメントで異なる pitch が混在する場合は、最初に見つかったセグメント固有値を使用）
        let effectivePitchCents: Float = {
            // セグメント固有の pitch を検索（0以外の値を持つ最初のセグメントを採用）
            for clip in orderedClips {
                let segPitch = segmentFilterSettings[clip.segmentID]?.pitchCents ?? 0
                if segPitch != 0 { return segPitch }
            }
            return pitchCents
        }()
        var pitchedTempURL: URL? = nil  // エクスポート完了まで削除を遅延するため保持
        let activeAudioTracks = composition.tracks(withMediaType: .audio)
        if effectivePitchCents != 0, let currentAudioTrack = activeAudioTracks.first,
           currentAudioTrack.timeRange.duration != .zero {
            let pitchedURL = try await renderPitchShiftedAudio(
                composition: composition,
                audioTrack: currentAudioTrack,
                pitchCents: effectivePitchCents
            )
            pitchedTempURL = pitchedURL
            // 元の音声トラックを全て削除し、ピッチ済み音声で差し替え
            for t in composition.tracks(withMediaType: .audio) {
                composition.removeTrack(t)
            }
            guard let newAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { throw ExportError.compositionFailed("newAudioTrack の作成に失敗しました") }
            let pitchedAsset = AVURLAsset(url: pitchedURL)
            if let pitchedSrc = try? await pitchedAsset.loadTracks(withMediaType: .audio).first {
                let pitchedDuration = try await pitchedAsset.load(.duration)
                // ピッチ済み音声の長さをcompositionの映像に合わせてクランプ
                let videoDuration = composition.duration
                let insertDuration = CMTimeMinimum(pitchedDuration, videoDuration)
                try newAudioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: insertDuration),
                    of: pitchedSrc,
                    at: .zero
                )
            }
            // ★ pitchedURL は AVComposition が参照しているため、ここでは削除しない
            //   エクスポート完了後に削除する
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
            let compEnd = composition.duration  // scaleTimeRange 後の実際の長さを使用
            let instrEnd = lastInstr.timeRange.start + lastInstr.timeRange.duration
            if instrEnd < compEnd {
                lastInstr.timeRange = CMTimeRange(
                    start: lastInstr.timeRange.start,
                    duration: compEnd - lastInstr.timeRange.start
                )
            }
        }

        videoComp.instructions = instructions

        // ④-b 透かし/フィルタが必要な場合は 2パス方式（CIImage 合成で確実に焼き込む）
        let hasPerSegmentFilters = !segmentFilterSettings.isEmpty
        let needsSecondPass = videoFilter != nil || kaleidoscopeType != nil || hasPerSegmentFilters || showWatermark

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

        // 1パス目完了後にピッチ済み一時ファイルを削除（composition が参照していたため遅延削除）
        if let pitchedURL = pitchedTempURL {
            try? FileManager.default.removeItem(at: pitchedURL)
        }

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

        // セグメントごとのフィルタ設定を時間範囲と紐付けたルックアップテーブルを構築
        struct FilterRange {
            let start: CMTime
            let end: CMTime
            let settings: SegmentFilterSettings
        }
        var filterRanges: [FilterRange] = []
        for range in clipRanges {
            let segSettings = segmentFilterSettings[range.segmentID]
            // セグメント固有設定 > グローバル設定
            let effective = segSettings ?? SegmentFilterSettings(
                videoFilter: videoFilter,
                kaleidoscopeType: kaleidoscopeType,
                kaleidoscopeSize: kaleidoscopeSize,
                kaleidoscopeCenterX: kaleidoscopeCenterX,
                kaleidoscopeCenterY: kaleidoscopeCenterY,
                tileHeight: tileHeight,
                mirrorDirection: mirrorDirection,
                rotationAngle: rotationAngle,
                filterIntensity: filterIntensity
            )
            filterRanges.append(FilterRange(
                start: range.compositionStart,
                end: range.compositionStart + range.duration,
                settings: effective
            ))
        }

        // 透かし用 CIImage を事前にロード（クロージャ外で1回だけ）
        let watermarkCI: CIImage? = showWatermark ? Self.loadWatermarkCIImage(renderSize: renderSize) : nil

        let ciComp = try await AVMutableVideoComposition.videoComposition(
            with: pass1Asset,
            applyingCIFiltersWithHandler: { request in
                var image = request.sourceImage

                // request.compositionTime から該当セグメントのフィルタ設定を取得
                let time = request.compositionTime
                var activeSettings: SegmentFilterSettings? = nil
                for fr in filterRanges {
                    if time >= fr.start && time < fr.end {
                        activeSettings = fr.settings
                        break
                    }
                }
                // 最後のフレーム（境界）用フォールバック
                if activeSettings == nil, let last = filterRanges.last, time >= last.start {
                    activeSettings = last.settings
                }

                if let settings = activeSettings, !settings.isDefault {
                    // AUTO回転: autoRotateSpeed > 0 なら時間に応じて角度を加算
                    var angle = settings.rotationAngle
                    if settings.autoRotateSpeed != 0 {
                        let elapsed = Float(CMTimeGetSeconds(time))
                        angle += settings.autoRotateSpeed * elapsed
                    }
                    image = PlaybackController.applyFilters(
                        to: image,
                        videoFilter: settings.videoFilter,
                        kaleidoscopeType: settings.kaleidoscopeType,
                        kaleidoscopeSize: settings.kaleidoscopeSize,
                        centerX: settings.kaleidoscopeCenterX,
                        centerY: settings.kaleidoscopeCenterY,
                        tileHeight: settings.tileHeight,
                        mirrorDirection: settings.mirrorDirection,
                        rotationAngle: angle,
                        filterIntensity: settings.filterIntensity
                    )
                }

                // 透かしを CIImage 合成で焼き込む（フィルタ適用後）
                if let wm = watermarkCI,
                   let composite = CIFilter(name: "CISourceOverCompositing") {
                    composite.setValue(wm, forKey: kCIInputImageKey)
                    composite.setValue(image, forKey: kCIInputBackgroundImageKey)
                    if let out = composite.outputImage {
                        image = out
                    }
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
        guard let tempTrack = audioComp.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw ExportError.compositionFailed("tempTrack の作成に失敗しました") }
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

    // MARK: - Watermark (CIImage 合成方式)

    /// 透かしロゴを CIImage として読み込み、右下に配置・半透明化した状態で返す
    /// 毎フレーム composited(over:) するだけで済むよう、位置・サイズ・透明度を事前に適用
    private static func loadWatermarkCIImage(renderSize: CGSize) -> CIImage? {
        // ロゴ画像読み込み（Asset Catalog → バンドル直接のフォールバック）
        let logo: UIImage? = UIImage(named: "WatermarkLogo")
            ?? Bundle.main.url(forResource: "Cinecam_logo_white", withExtension: "png")
                .flatMap { try? Data(contentsOf: $0) }
                .flatMap { UIImage(data: $0) }
        guard let logo, let cgImage = logo.cgImage else {
            print("⚠️ [Watermark] Logo image not found")
            return nil
        }

        let margin = renderSize.width * 0.015
        let logoTargetWidth = renderSize.width * 0.06  // 映像幅の6%（元の0.5倍）
        let logoScale = logoTargetWidth / logo.size.width
        let logoW = logo.size.width * logoScale

        // CIImage に変換 → スケール → 半透明 → 右下に配置
        var ci = CIImage(cgImage: cgImage)

        // スケール
        let scaleTransform = CGAffineTransform(scaleX: logoScale, y: logoScale)
        ci = ci.transformed(by: scaleTransform)

        // 半透明（CIColorMatrix で alpha を下げる）
        if let alphaFilter = CIFilter(name: "CIColorMatrix") {
            alphaFilter.setValue(ci, forKey: kCIInputImageKey)
            alphaFilter.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
            alphaFilter.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
            alphaFilter.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
            alphaFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0.25), forKey: "inputAVector")
            if let out = alphaFilter.outputImage {
                ci = out
            }
        }

        // 右下に配置（CIImage 座標系: 左下原点）
        let tx = renderSize.width - logoW - margin
        let ty = margin  // 左下原点 → y=margin で右下配置
        ci = ci.transformed(by: CGAffineTransform(translationX: tx, y: ty))

        return ci
    }

    // MARK: - Errors

    enum ExportError: LocalizedError {
        case noClips
        case sessionFailed
        case cancelled
        case photoLibraryDenied
        case compositionFailed(String)

        var errorDescription: String? {
            switch self {
            case .noClips:                   return "No clips to export"
            case .sessionFailed:             return "Failed to create export session"
            case .cancelled:                 return "Export was cancelled"
            case .photoLibraryDenied:        return "Photo library access denied. Please allow access in Settings."
            case .compositionFailed(let msg): return msg
            }
        }
    }
}
