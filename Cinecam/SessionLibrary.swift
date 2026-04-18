//
//  SessionLibrary.swift
//  Cinecam
//
//  撮影済みセッションの履歴管理（UserDefaults に永続化）
//

import Foundation
import SwiftUI
import Combine

// MARK: - SegmentState（編集状態の永続化用）

struct SegmentState: Codable, Equatable {
    var id: UUID
    var trimIn: Double
    var trimOut: Double
    /// セグメント単位のフィルタ設定（nil = グローバル設定を使用）
    var filterSettings: SavedSegmentFilterSettings?
}

/// SegmentFilterSettings の永続化用（Codable対応）
struct SavedSegmentFilterSettings: Codable, Equatable {
    var videoFilter: String?
    var kaleidoscopeType: String?
    var kaleidoscopeSize: Float?
    var kaleidoscopeCenterX: Float?
    var kaleidoscopeCenterY: Float?
    var tileHeight: Float?
    var mirrorDirection: Int?
    var rotationAngle: Float?
    var autoRotateSpeed: Float?
    var speedRate: Float?
    var filterIntensity: Float?
    var pitchCents: Float?
    var noSound: Bool?

    init(from settings: SegmentFilterSettings) {
        self.videoFilter = settings.videoFilter
        self.kaleidoscopeType = settings.kaleidoscopeType
        self.kaleidoscopeSize = settings.kaleidoscopeSize
        self.kaleidoscopeCenterX = settings.kaleidoscopeCenterX
        self.kaleidoscopeCenterY = settings.kaleidoscopeCenterY
        self.tileHeight = settings.tileHeight
        self.mirrorDirection = settings.mirrorDirection
        self.rotationAngle = settings.rotationAngle
        self.autoRotateSpeed = settings.autoRotateSpeed
        self.speedRate = settings.speedRate
        self.filterIntensity = settings.filterIntensity
        self.pitchCents = settings.pitchCents != 0 ? settings.pitchCents : nil
        self.noSound = settings.noSound ? true : nil
    }

    func toSegmentFilterSettings() -> SegmentFilterSettings {
        SegmentFilterSettings(
            videoFilter: videoFilter,
            kaleidoscopeType: kaleidoscopeType,
            kaleidoscopeSize: kaleidoscopeSize ?? 200,
            kaleidoscopeCenterX: kaleidoscopeCenterX ?? 0.5,
            kaleidoscopeCenterY: kaleidoscopeCenterY ?? 0.5,
            tileHeight: tileHeight ?? 200,
            mirrorDirection: mirrorDirection ?? 0,
            rotationAngle: rotationAngle ?? 0,
            autoRotateSpeed: autoRotateSpeed ?? 0,
            speedRate: speedRate ?? 1.0,
            filterIntensity: filterIntensity ?? 1.0,
            pitchCents: pitchCents ?? 0,
            noSound: noSound ?? false
        )
    }
}

// MARK: - SessionRecord

struct SessionRecord: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var createdAt: Date
    var videoPaths: [String: String]
    /// デバイスごとのセグメント編集状態（保存ボタン押下時に記録）
    var editState: [String: [SegmentState]]
    /// 撮影時の向き設定（"横向き" or "縦向き"）後方互換のためOptional
    var desiredOrientation: String?
    /// ロックされたデバイス名の一覧
    var lockedDevices: [String]?
    /// 選択中の音声デバイス（nil = 編集に従う）
    var selectedAudioDevice: String?
    /// 選択中の映像フィルタ（CIFilter名、nil = なし）
    var selectedVideoFilter: String?
    /// ピッチシフト値（セント単位: 0 = 無効）
    var pitchShiftCents: Float?
    /// 万華鏡フィルタタイプ（CIFilter名、nil = なし）
    var selectedKaleidoscope: String?
    /// 万華鏡サイズ
    var kaleidoscopeSize: Float?
    /// 万華鏡中心X（0.0〜1.0）
    var kaleidoscopeCenterX: Float?
    /// 万華鏡中心Y（0.0〜1.0）
    var kaleidoscopeCenterY: Float?
    /// TILEフィルタの縦幅（kaleidoscopeSize が横幅）
    var tileHeight: Float?
    /// 再生スピード倍率（1.0 = 通常）
    var playbackSpeed: Float?
    /// フィルタ強度（0.0〜1.0, nil = 1.0）
    var filterIntensity: Float?

    /// URL に復元した辞書
    /// パスはサンドボックス相対（ファイル名のみ）で保存し、
    /// 起動ごとに変わる Documents ディレクトリと結合して復元する
    var videos: [String: URL] {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return [:] }
        return videoPaths.compactMapValues { path -> URL? in
            // 旧形式（file:// 絶対URL文字列）との互換：ファイル名だけ取り出して再構築
            let fileName: String
            if path.hasPrefix("file://") || path.hasPrefix("/") {
                fileName = (path as NSString).lastPathComponent
            } else {
                fileName = path
            }
            let url = docs.appendingPathComponent(fileName)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    init(id: String, videos: [String: URL], createdAt: Date = Date(), orientation: VideoOrientation? = nil) {
        self.id        = id
        self.title     = "UNTITLED"
        self.createdAt = createdAt
        self.editState = [:]
        self.desiredOrientation = orientation?.rawValue
        // ファイル名のみを保存（サンドボックスパスが変わっても復元できる）
        self.videoPaths = videos.compactMapValues { $0.lastPathComponent }
    }

    // 旧データ（editState なし）との互換デコード
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id         = try c.decode(String.self,              forKey: .id)
        title      = try c.decode(String.self,              forKey: .title)
        createdAt  = try c.decode(Date.self,                forKey: .createdAt)
        videoPaths = try c.decode([String: String].self,    forKey: .videoPaths)
        editState  = (try? c.decode([String: [SegmentState]].self, forKey: .editState)) ?? [:]
        desiredOrientation = try? c.decode(String.self, forKey: .desiredOrientation)
        lockedDevices = try? c.decode([String].self, forKey: .lockedDevices)
        selectedAudioDevice = try? c.decode(String.self, forKey: .selectedAudioDevice)
        selectedVideoFilter = try? c.decode(String.self, forKey: .selectedVideoFilter)
        pitchShiftCents = try? c.decode(Float.self, forKey: .pitchShiftCents)
        selectedKaleidoscope = try? c.decode(String.self, forKey: .selectedKaleidoscope)
        kaleidoscopeSize = try? c.decode(Float.self, forKey: .kaleidoscopeSize)
        kaleidoscopeCenterX = try? c.decode(Float.self, forKey: .kaleidoscopeCenterX)
        kaleidoscopeCenterY = try? c.decode(Float.self, forKey: .kaleidoscopeCenterY)
        tileHeight = try? c.decode(Float.self, forKey: .tileHeight)
        playbackSpeed = try? c.decode(Float.self, forKey: .playbackSpeed)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, videoPaths, editState, desiredOrientation, lockedDevices, selectedAudioDevice, selectedVideoFilter, pitchShiftCents, selectedKaleidoscope, kaleidoscopeSize, kaleidoscopeCenterX, kaleidoscopeCenterY, tileHeight, playbackSpeed
    }
}

// MARK: - SessionLibrary

@MainActor
final class SessionLibrary: ObservableObject {
    static let shared = SessionLibrary()

    @Published private(set) var records: [SessionRecord] = []

    private let key = "cinecam.sessionLibrary"

    private init() { load() }

    // MARK: - CRUD

    /// 新しいセッションを追加（同じ ID が既にあればスキップ）
    func add(sessionID: String, videos: [String: URL], orientation: VideoOrientation? = nil) {
        guard !records.contains(where: { $0.id == sessionID }) else { return }
        let record = SessionRecord(id: sessionID, videos: videos, orientation: orientation)
        records.insert(record, at: 0)  // 最新が先頭
        save()
    }

    /// タイトルを更新する
    func rename(id: String, title: String) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        records[idx].title = title.trimmingCharacters(in: .whitespaces).isEmpty
            ? "UNTITLED" : title.trimmingCharacters(in: .whitespaces)
        save()
    }

    /// 編集状態（セグメント + ロック + 音声/フィルタ/万華鏡/速度/ピッチ/セグメントフィルタ）を保存する
    func saveEditState(
        id: String,
        segmentsByDevice: [String: [ClipSegment]],
        lockedDevices: Set<String> = [],
        audioDevice: String? = nil,
        videoFilter: String? = nil,
        pitchCents: Float = 0,
        kaleidoscope: String? = nil,
        kaleidoscopeSize: Float = 200,
        kaleidoscopeCenterX: Float = 0.5,
        kaleidoscopeCenterY: Float = 0.5,
        tileHeight: Float = 200,
        playbackSpeed: Float = 1.0,
        filterIntensity: Float = 1.0,
        segmentFilterSettings: [UUID: SegmentFilterSettings] = [:]
    ) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else {
            #if DEBUG
            print("⚠️ [Library] saveEditState: record not found for id=\(id)")
            #endif
            return
        }
        var newState: [String: [SegmentState]] = [:]
        for (device, segs) in segmentsByDevice {
            let validSegs = segs.filter { $0.isValid }.map { seg in
                var state = SegmentState(id: seg.id, trimIn: seg.trimIn, trimOut: seg.trimOut)
                // セグメント固有のフィルタ設定があれば保存
                if let settings = segmentFilterSettings[seg.id], !settings.isDefault {
                    state.filterSettings = SavedSegmentFilterSettings(from: settings)
                }
                return state
            }
            if !validSegs.isEmpty {
                newState[device] = validSegs
            }
        }
        records[idx].editState = newState
        records[idx].lockedDevices = lockedDevices.isEmpty ? nil : Array(lockedDevices)
        records[idx].selectedAudioDevice = audioDevice
        records[idx].selectedVideoFilter = videoFilter
        records[idx].pitchShiftCents = pitchCents != 0 ? pitchCents : nil
        records[idx].selectedKaleidoscope = kaleidoscope
        records[idx].kaleidoscopeSize = kaleidoscopeSize != 200 ? kaleidoscopeSize : nil
        records[idx].kaleidoscopeCenterX = kaleidoscopeCenterX != 0.5 ? kaleidoscopeCenterX : nil
        records[idx].kaleidoscopeCenterY = kaleidoscopeCenterY != 0.5 ? kaleidoscopeCenterY : nil
        records[idx].tileHeight = tileHeight != 200 ? tileHeight : nil
        records[idx].playbackSpeed = playbackSpeed != 1.0 ? playbackSpeed : nil
        records[idx].filterIntensity = filterIntensity != 1.0 ? filterIntensity : nil
        save()
        #if DEBUG
        print("✅ [Library] Saved edit state for id=\(id), devices=\(newState.keys.sorted()), locked=\(lockedDevices.sorted())")
        #endif
    }

    /// セッションを削除する（ファイルも一緒に削除）
    func delete(id: String) {
        if let record = records.first(where: { $0.id == id }) {
            deleteFiles(for: record)
        }
        records.removeAll { $0.id == id }
        save()
    }

    func delete(at offsets: IndexSet) {
        for index in offsets {
            deleteFiles(for: records[index])
        }
        records.remove(atOffsets: offsets)
        save()
    }

    /// レコードに紐づく動画ファイルを Documents から削除する
    private func deleteFiles(for record: SessionRecord) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        for fileName in record.videoPaths.values {
            // videoPaths の値はファイル名のみで保存されている
            let actualFileName: String
            if fileName.hasPrefix("file://") || fileName.hasPrefix("/") {
                actualFileName = (fileName as NSString).lastPathComponent
            } else {
                actualFileName = fileName
            }
            let url = docs.appendingPathComponent(actualFileName)
            try? FileManager.default.removeItem(at: url)
            #if DEBUG
            print("🗑️ [Library] Deleted file: \(actualFileName)")
            #endif
        }
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SessionRecord].self, from: data)
        else { return }
        records = decoded
    }
}
