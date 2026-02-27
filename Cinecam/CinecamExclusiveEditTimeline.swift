import Foundation
import Combine

struct ClipSegment: Identifiable, Equatable {
    let id: UUID
    let videoDuration: Double
    let videoStart: Double
    let videoEnd: Double
    var trimIn: Double
    var trimOut: Double

    init(id: UUID = UUID(), videoDuration: Double, videoStart: Double, videoEnd: Double,
         trimIn: Double? = nil, trimOut: Double? = nil) {
        self.id = id; self.videoDuration = videoDuration
        self.videoStart = videoStart; self.videoEnd = videoEnd
        self.trimIn = trimIn ?? videoStart; self.trimOut = trimOut ?? videoEnd
    }

    var isValid: Bool { trimOut - trimIn >= 0.1 }

    func trimInRatio(total: Double) -> CGFloat { total > 0 ? CGFloat(trimIn / total) : 0 }
    func trimOutRatio(total: Double) -> CGFloat { total > 0 ? CGFloat(trimOut / total) : 1 }
    func videoStartRatio(total: Double) -> CGFloat { total > 0 ? CGFloat(videoStart / total) : 0 }
    func videoEndRatio(total: Double) -> CGFloat { total > 0 ? CGFloat(videoEnd / total) : 1 }

    var sourceInTime: Double  { trimIn  - videoStart }
    var sourceOutTime: Double { trimOut - videoStart }
    var trimmedDuration: Double { trimOut - trimIn }
}

@MainActor
final class ExclusiveEditTimeline: ObservableObject {
    @Published private(set) var segmentsByDevice: [String: [ClipSegment]] = [:]
    private(set) var totalDuration: Double = 0
    private(set) var devices: [String] = []

    /// 各デバイスの映像範囲（segments が空になっても消えない固定値）
    private(set) var videoRangeByDevice: [String: (start: Double, end: Double, duration: Double)] = [:]

    func setup(durations: [String: Double], orderedDevices: [String]) {
        let maxDur = durations.values.max() ?? 0
        guard maxDur > 0 else { return }
        totalDuration = maxDur
        devices = orderedDevices
        // 初期状態はセグメントなし（長押しで新規追加する仕様）
        var initial: [String: [ClipSegment]] = [:]
        var ranges: [String: (Double, Double, Double)] = [:]
        for device in orderedDevices {
            guard let dur = durations[device], dur > 0 else { continue }
            let vStart = maxDur - dur
            let vEnd   = maxDur
            initial[device] = []   // ← 空配列：長押しで追加
            ranges[device]  = (vStart, vEnd, dur)
        }
        segmentsByDevice   = initial
        videoRangeByDevice = ranges
    }

    /// 保存済みの編集状態を復元する（setup() の後に呼ぶ）
    func restoreEditState(_ editState: [String: [SegmentState]]) {
        guard !editState.isEmpty else { return }
        var restored: [String: [ClipSegment]] = segmentsByDevice
        for (device, states) in editState {
            guard let range = videoRangeByDevice[device], !states.isEmpty else { continue }
            restored[device] = states.compactMap { state -> ClipSegment? in
                // trimIn/trimOut が映像範囲内に収まるようにクランプ
                let trimIn  = max(range.start, min(range.end, state.trimIn))
                let trimOut = max(range.start, min(range.end, state.trimOut))
                guard trimOut - trimIn >= 0.1 else { return nil }
                return ClipSegment(
                    id: state.id,
                    videoDuration: range.duration,
                    videoStart: range.start,
                    videoEnd: range.end,
                    trimIn: trimIn,
                    trimOut: trimOut
                )
            }
        }
        segmentsByDevice = restored
    }

    func moveTrimIn(segmentID: UUID, device: String, newTrimIn: Double) {
        guard var segs = segmentsByDevice[device],
              let idx = segs.firstIndex(where: { $0.id == segmentID }),
              let range = videoRangeByDevice[device] else { return }
        segs[idx].trimIn = max(segs[idx].videoStart, min(segs[idx].trimOut - 0.1, newTrimIn))
        segmentsByDevice[device] = mergeAdjacentSegments(segs, range: range)
        enforceExclusivity(priorityDevice: device)
    }

    func moveTrimOut(segmentID: UUID, device: String, newTrimOut: Double) {
        guard var segs = segmentsByDevice[device],
              let idx = segs.firstIndex(where: { $0.id == segmentID }),
              let range = videoRangeByDevice[device] else { return }
        segs[idx].trimOut = min(segs[idx].videoEnd, max(segs[idx].trimIn + 0.1, newTrimOut))
        segmentsByDevice[device] = mergeAdjacentSegments(segs, range: range)
        enforceExclusivity(priorityDevice: device)
    }

    func moveSegment(segmentID: UUID, device: String, deltaSeconds: Double) {
        guard var segs = segmentsByDevice[device],
              let idx = segs.firstIndex(where: { $0.id == segmentID }),
              let range = videoRangeByDevice[device] else { return }
        let span = segs[idx].trimOut - segs[idx].trimIn
        let newIn = max(segs[idx].videoStart, min(segs[idx].videoEnd - span, segs[idx].trimIn + deltaSeconds))
        segs[idx].trimIn = newIn; segs[idx].trimOut = newIn + span
        segmentsByDevice[device] = mergeAdjacentSegments(segs, range: range)
        enforceExclusivity(priorityDevice: device)
    }

    /// 指定タイムライン位置を中心に、そのデバイスの映像範囲内に新しい小さなセグメントを追加する。
    /// 長押しした位置に新規クリップを生成するために使う。
    /// 既存セグメントと重なる部分は既存側を削除し、新規セグメントが優先される（排他制約）。
    /// - Parameters:
    ///   - seconds:     タイムライン上の中心時刻（秒）
    ///   - device:      対象デバイス名
    ///   - spanPixels:  初期幅（ポイント）。タイムライン全体幅 trackWidth との比で秒数に変換される。
    ///   - trackWidth:  タイムラインのピクセル幅（ズームスケール適用済みの値を渡す）
    func addSegment(around seconds: Double, for device: String,
                    spanPixels: CGFloat = 44, trackWidth: CGFloat) {
        guard let range = videoRangeByDevice[device], totalDuration > 0, trackWidth > 0 else { return }
        // ピクセル幅 → 秒数変換
        let span = Double(spanPixels / trackWidth) * totalDuration
        let halfSpan = span / 2.0
        let clampedCenter = max(range.start + halfSpan, min(range.end - halfSpan, seconds))
        let newIn  = max(range.start, clampedCenter - halfSpan)
        let newOut = min(range.end,   newIn + span)

        let newSeg = ClipSegment(
            videoDuration: range.duration,
            videoStart:    range.start,
            videoEnd:      range.end,
            trimIn:        newIn,
            trimOut:       newOut
        )

        // 同デバイスの既存セグメントから新セグメントと重なる部分を除去（排他制約）
        let existing = (segmentsByDevice[device] ?? [])
            .flatMap { subtract(from: $0, excludeStart: newIn, excludeEnd: newOut) }
            .filter { $0.isValid }

        // 追加後に隣接セグメントをマージして連続した青枠をまとめる
        let merged = mergeAdjacentSegments(existing + [newSeg], range: range)
        segmentsByDevice[device] = merged

        // 全デバイス間で排他制約を強制適用（操作中デバイスを最優先）
        enforceExclusivity(priorityDevice: device)
    }

    /// trimIn/trimOut が接触・重複しているセグメントを1つに結合する。
    /// 同一 videoStart/videoEnd を持つセグメントのみマージ対象とする。
    private func mergeAdjacentSegments(
        _ segs: [ClipSegment],
        range: (start: Double, end: Double, duration: Double),
        tolerance: Double = 0.05
    ) -> [ClipSegment] {
        let sorted = segs.filter { $0.isValid }.sorted { $0.trimIn < $1.trimIn }
        var result: [ClipSegment] = []
        for seg in sorted {
            if var last = result.last,
               last.videoStart == seg.videoStart,
               last.videoEnd == seg.videoEnd,
               seg.trimIn <= last.trimOut + tolerance {
                // 隣接または重複 → trimOut を広げてマージ
                last.trimOut = max(last.trimOut, seg.trimOut)
                result[result.count - 1] = last
            } else {
                result.append(seg)
            }
        }
        return result
    }

    func applySelection(trimIn: Double, trimOut: Double, for deviceName: String) {
        guard devices.contains(deviceName), trimOut - trimIn >= 0.1 else { return }
        var result: [String: [ClipSegment]] = [:]
        for device in devices {
            if device == deviceName {
                result[device] = segmentsByDevice[device] ?? []
            } else {
                result[device] = (segmentsByDevice[device] ?? []).flatMap {
                    subtract(from: $0, excludeStart: trimIn, excludeEnd: trimOut)
                }.filter { $0.isValid }
            }
        }
        segmentsByDevice = result
    }

    /// 指定デバイスの全有効セグメントをまとめて確定し、
    /// 他デバイスから重複する範囲を一括削除する。
    func commitAllSegments(for deviceName: String) {
        guard devices.contains(deviceName) else { return }
        let mySegs = (segmentsByDevice[deviceName] ?? []).filter { $0.isValid }
        guard !mySegs.isEmpty else { return }

        var result: [String: [ClipSegment]] = [:]
        for device in devices {
            if device == deviceName {
                result[device] = mySegs
            } else {
                var others = segmentsByDevice[device] ?? []
                for mySeg in mySegs {
                    others = others.flatMap {
                        subtract(from: $0, excludeStart: mySeg.trimIn, excludeEnd: mySeg.trimOut)
                    }.filter { $0.isValid }
                }
                result[device] = others
            }
        }
        segmentsByDevice = result
    }

    /// 全デバイス間で時間軸の排他制約を強制適用する。
    /// `priorityDevice` が指定された場合、そのデバイスを最優先で処理し、
    /// 他デバイスのセグメントをトリムする。未指定時は `devices` 配列順。
    func enforceExclusivity(priorityDevice: String? = nil) {
        // 優先デバイスを先頭にした処理順を構築
        let ordered: [String]
        if let priority = priorityDevice, devices.contains(priority) {
            ordered = [priority] + devices.filter { $0 != priority }
        } else {
            ordered = devices
        }

        // 優先順位順に処理：先に処理されたデバイスのセグメントが勝つ
        var committed: [(trimIn: Double, trimOut: Double)] = []
        var result: [String: [ClipSegment]] = [:]

        for device in ordered {
            let segs = (segmentsByDevice[device] ?? []).filter { $0.isValid }
            // 既に確定済みの範囲を全て除去
            var remaining = segs
            for used in committed {
                remaining = remaining.flatMap {
                    subtract(from: $0, excludeStart: used.trimIn, excludeEnd: used.trimOut)
                }.filter { $0.isValid }
            }
            // このデバイスの残存セグメントを確定済みリストに追加
            for seg in remaining {
                committed.append((seg.trimIn, seg.trimOut))
            }
            result[device] = remaining
        }
        segmentsByDevice = result
    }

    /// セグメントを削除する（ダブルタップで呼ばれる）
    func removeSegment(segmentID: UUID, device: String) {
        guard var segs = segmentsByDevice[device] else { return }
        segs.removeAll { $0.id == segmentID }
        segmentsByDevice[device] = segs
    }

    func activeDevice(at seconds: Double) -> String? {
        devices.first { device in
            (segmentsByDevice[device] ?? []).contains { $0.trimIn <= seconds && seconds < $0.trimOut }
        }
    }

    func segments(for device: String) -> [ClipSegment] { segmentsByDevice[device] ?? [] }

    private func subtract(from seg: ClipSegment, excludeStart: Double, excludeEnd: Double) -> [ClipSegment] {
        if excludeEnd <= seg.trimIn || excludeStart >= seg.trimOut { return [seg] }
        var result: [ClipSegment] = []
        if seg.trimIn < excludeStart {
            result.append(ClipSegment(videoDuration: seg.videoDuration, videoStart: seg.videoStart,
                                      videoEnd: seg.videoEnd, trimIn: seg.trimIn, trimOut: excludeStart))
        }
        if seg.trimOut > excludeEnd {
            result.append(ClipSegment(videoDuration: seg.videoDuration, videoStart: seg.videoStart,
                                      videoEnd: seg.videoEnd, trimIn: excludeEnd, trimOut: seg.trimOut))
        }
        return result
    }
}
