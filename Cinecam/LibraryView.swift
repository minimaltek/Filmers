//
//  LibraryView.swift
//  Cinecam
//
//  撮影済みセッションの一覧画面
//

import SwiftUI
import Combine

struct LibraryView: View {
    @ObservedObject var library: SessionLibrary
    @Environment(\.dismiss) private var dismiss

    /// 編集中のセッション（PreviewView に渡す）
    @State private var selectedRecord: SessionRecord? = nil
    /// インライン名前編集中のレコードID
    @State private var renamingID: String? = nil
    @State private var renameDraft: String = ""

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

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
                            library.delete(at: offsets)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .navigationTitle("ライブラリ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(.white)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                        .foregroundColor(.white)
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
                onSaveEditState: { segmentsByDevice in
                    library.saveEditState(id: record.id, segmentsByDevice: segmentsByDevice)
                },
                savedEditState: record.editState
            )
        }
    }

    // MARK: - Row

    private func sessionRow(_ record: SessionRecord) -> some View {
        Button {
            // タイトル編集中でなければ PreviewView へ
            if renamingID == nil {
                selectedRecord = record
            }
        } label: {
            HStack(spacing: 12) {
                // アイコン（タップで PreviewView へ）
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 48, height: 48)
                    Image(systemName: "film.stack")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.6))
                }

                VStack(alignment: .leading, spacing: 4) {
                    // タイトル（編集中は TextField、それ以外はテキスト表示のみ）
                    if renamingID == record.id {
                        TextField("タイトル", text: $renameDraft, onCommit: {
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
                        // TextField のタップが Button に伝わらないようにする
                        .onTapGesture { }
                    } else {
                        Text(record.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                    }

                    HStack(spacing: 8) {
                        Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.4))
                        Text("·")
                            .foregroundColor(.white.opacity(0.3))
                        Text("\(record.videoPaths.count)台")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.4))
                    }
                }

                Spacer()

                // ペンアイコン：タイトル編集モードに入る
                if renamingID == record.id {
                    // 編集中はチェックマーク（確定ボタン）
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
                    .onTapGesture { }   // 行全体の Button に伝播させない
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
            Text("撮影済みセッションがありません")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.4))
        }
    }
}
