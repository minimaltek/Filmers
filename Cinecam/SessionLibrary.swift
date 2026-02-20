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
}

// MARK: - SessionRecord

struct SessionRecord: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var createdAt: Date
    var videoPaths: [String: String]
    /// デバイスごとのセグメント編集状態（保存ボタン押下時に記録）
    var editState: [String: [SegmentState]]

    /// URL に復元した辞書
    /// パスはサンドボックス相対（ファイル名のみ）で保存し、
    /// 起動ごとに変わる Documents ディレクトリと結合して復元する
    var videos: [String: URL] {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
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

    init(id: String, videos: [String: URL], createdAt: Date = Date()) {
        self.id        = id
        self.title     = "UNTITLED"
        self.createdAt = createdAt
        self.editState = [:]
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
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, videoPaths, editState
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
    func add(sessionID: String, videos: [String: URL]) {
        guard !records.contains(where: { $0.id == sessionID }) else { return }
        let record = SessionRecord(id: sessionID, videos: videos)
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

    /// 編集状態（セグメント）を保存する
    func saveEditState(id: String, segmentsByDevice: [String: [ClipSegment]]) {
        // レコードがまだ存在しない場合（初回撮影直後）は何もしない
        // （ContentView 側で PreviewView 表示前に add() が呼ばれているはずだが念のため）
        guard let idx = records.firstIndex(where: { $0.id == id }) else {
            print("⚠️ [Library] saveEditState: record not found for id=\(id)")
            return
        }
        var newState: [String: [SegmentState]] = [:]
        for (device, segs) in segmentsByDevice {
            let validSegs = segs.filter { $0.isValid }.map {
                SegmentState(id: $0.id, trimIn: $0.trimIn, trimOut: $0.trimOut)
            }
            if !validSegs.isEmpty {
                newState[device] = validSegs
            }
        }
        records[idx].editState = newState
        save()
        print("✅ [Library] Saved edit state for id=\(id), devices=\(newState.keys.sorted())")
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
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
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
            print("🗑️ [Library] Deleted file: \(actualFileName)")
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
