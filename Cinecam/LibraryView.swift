//
//  LibraryView.swift
//  Cinecam
//
//  撮影済みセッションの一覧画面
//

import SwiftUI
import AVFoundation
import Combine

struct LibraryView: View {
    @ObservedObject var library: SessionLibrary
    @Environment(\.dismiss) private var dismiss

    /// 編集中のセッション（PreviewView に渡す）
    @State private var selectedRecord: SessionRecord? = nil
    /// インライン名前編集中のレコードID
    @State private var renamingID: String? = nil
    @State private var renameDraft: String = ""
    /// 複数選択モード
    @State private var isSelectMode = false
    @State private var selectedIDs: Set<String> = []
    /// サムネイルキャッシュ
    @State private var thumbnailCache: [String: UIImage] = [:]

    var body: some View {
        NavigationView {
            Group {
                if library.records.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(library.records) { record in
                            sessionRow(record)
                                .listRowBackground(Color.white.opacity(0.05))
                                .listRowSeparatorTint(Color.white.opacity(0.1))
                        }
                        .onDelete { offsets in
                            if !isSelectMode {
                                library.delete(at: offsets)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(.white)
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if isSelectMode {
                        Button("Delete (\(selectedIDs.count))") {
                            deleteSelected()
                        }
                        .foregroundColor(selectedIDs.isEmpty ? .gray : .red)
                        .disabled(selectedIDs.isEmpty)

                        Button("Done") {
                            isSelectMode = false
                            selectedIDs.removeAll()
                        }
                        .foregroundColor(.white)
                    } else {
                        Button {
                            isSelectMode = true
                            selectedIDs.removeAll()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 15))
                        }
                        .foregroundColor(.white)
                    }
                }
            }
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .fullScreenCover(item: $selectedRecord) { record in
            PreviewView(
                sessionID: record.id,
                videos: record.videos,
                sessionTitle: record.title,
                onRename: { newTitle in
                    library.rename(id: record.id, title: newTitle)
                },
                onSaveEditState: { segmentsByDevice, lockedDevices, audioDevice, videoFilter, pitchCents, kaleidoscope, kSize, kCX, kCY, tH, speed, segFilterSettings in
                    library.saveEditState(id: record.id, segmentsByDevice: segmentsByDevice, lockedDevices: lockedDevices, audioDevice: audioDevice, videoFilter: videoFilter, pitchCents: pitchCents, kaleidoscope: kaleidoscope, kaleidoscopeSize: kSize, kaleidoscopeCenterX: kCX, kaleidoscopeCenterY: kCY, tileHeight: tH, playbackSpeed: speed, segmentFilterSettings: segFilterSettings)
                },
                savedEditState: record.editState,
                savedLockedDevices: record.lockedDevices ?? [],
                savedAudioDevice: record.selectedAudioDevice,
                savedVideoFilter: record.selectedVideoFilter,
                savedPitchCents: record.pitchShiftCents ?? 0,
                savedKaleidoscope: record.selectedKaleidoscope,
                savedKaleidoscopeSize: record.kaleidoscopeSize ?? 200,
                savedKaleidoscopeCenterX: record.kaleidoscopeCenterX ?? 0.5,
                savedKaleidoscopeCenterY: record.kaleidoscopeCenterY ?? 0.5,
                savedTileHeight: record.tileHeight ?? 200,
                savedPlaybackSpeed: record.playbackSpeed ?? 1.0,
                onDeleteSession: {
                    library.delete(id: record.id)
                },
                desiredOrientation: VideoOrientation(rawValue: record.desiredOrientation ?? "横（シネマ）") ?? .cinema
            )
        }
        .onAppear { generateThumbnails() }
        .onChange(of: library.records.count) { _ in generateThumbnails() }
    }

    // MARK: - Row

    private func sessionRow(_ record: SessionRecord) -> some View {
        Button {
            if isSelectMode {
                toggleSelection(record.id)
            } else if renamingID == nil {
                selectedRecord = record
            }
        } label: {
            HStack(spacing: 12) {
                // 選択モード時のチェックボックス
                if isSelectMode {
                    Image(systemName: selectedIDs.contains(record.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundColor(selectedIDs.contains(record.id) ? .blue : .white.opacity(0.4))
                }

                // サムネイル
                if let thumb = thumbnailCache[record.id] {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 64, height: 48)
                        Image(systemName: "film.stack")
                            .font(.system(size: 18))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    if renamingID == record.id {
                        TextField("Title", text: $renameDraft, onCommit: {
                            library.rename(id: record.id, title: renameDraft)
                            renamingID = nil
                        })
                        .foregroundColor(.white)
                        .font(.system(size: 15, weight: .semibold))
                        .autocorrectionDisabled()
                        .onSubmit {
                            library.rename(id: record.id, title: renameDraft)
                            renamingID = nil
                        }
                        .onTapGesture { }
                    } else {
                        Text(record.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text({
                            let c = Calendar.current
                            let y = c.component(.year, from: record.createdAt)
                            let m = c.component(.month, from: record.createdAt)
                            let d = c.component(.day, from: record.createdAt)
                            return "\(y)/\(m)/\(d)"
                        }())
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.4))
                        Text("\(record.videoPaths.count) Clips : \(orientationLabel(record.desiredOrientation))")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.4))
                    }
                }

                Spacer()

                if !isSelectMode {
                    // ペンアイコン：タイトル編集モードに入る
                    if renamingID == record.id {
                        Button {
                            library.rename(id: record.id, title: renameDraft)
                            renamingID = nil
                        } label: {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.white.opacity(0.2))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .onTapGesture { }
                    } else {
                        Button {
                            renameDraft = record.title == "UNTITLED" ? "" : record.title
                            renamingID = record.id
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white.opacity(0.5))
                                .frame(width: 28, height: 28)
                                .background(Color.white.opacity(0.08))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.3))
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 52))
                .foregroundColor(.white.opacity(0.2))
            Text("No sessions recorded")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    // MARK: - Helpers

    private func orientationLabel(_ raw: String?) -> String {
        switch raw {
        case "横（シネマ）": return "Cinema"
        case "横（テレビ）": return "TV"
        case "縦（スマホ）": return "Phone"
        default:            return "—"
        }
    }

    // MARK: - Selection

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func deleteSelected() {
        guard !selectedIDs.isEmpty else { return }
        for id in selectedIDs {
            library.delete(id: id)
            thumbnailCache.removeValue(forKey: id)
        }
        selectedIDs.removeAll()
        isSelectMode = false
    }

    // MARK: - Thumbnails

    private func generateThumbnails() {
        for record in library.records {
            guard thumbnailCache[record.id] == nil else { continue }
            // 最初のビデオURLを取得
            guard let firstURL = record.videos.values.first else { continue }
            let recordID = record.id
            Task.detached {
                let asset = AVAsset(url: firstURL)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 128, height: 128)
                if let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                    let uiImage = UIImage(cgImage: cgImage)
                    await MainActor.run {
                        thumbnailCache[recordID] = uiImage
                    }
                }
            }
        }
    }
}

#Preview("LibraryView") {
    LibraryView(library: SessionLibrary.shared)
        .preferredColorScheme(.dark)
}
