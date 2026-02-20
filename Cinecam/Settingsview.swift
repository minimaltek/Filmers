//
//  SettingsView.swift
//  Cinecam
//
//  カメラ設定画面
//

import SwiftUI
import AVFoundation

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var cameraManager: CameraManager

    @State private var selectedResolution: VideoResolution = .hd1080p
    @State private var selectedFrameRate: FrameRate = .fps30
    @State private var selectedOrientation: VideoOrientation = .landscape
    @State private var selectedCodec: VideoCodec = .hevc

    /// UserDefaults に永続化するユーザー名
    @AppStorage("cinecam.userName") private var userName: String = UIDevice.current.name
    /// 編集中の一時テキスト
    @State private var userNameDraft: String = ""
    /// 名前変更後に再起動が必要な旨を通知するアラート
    @State private var showRestartAlert = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                Form {
                    // ── ユーザー名設定 ──────────────────────────────
                    Section {
                        HStack {
                            TextField("ユーザー名", text: $userNameDraft)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            if userNameDraft != userName {
                                Button("保存") {
                                    let trimmed = userNameDraft.trimmingCharacters(in: .whitespaces)
                                    guard !trimmed.isEmpty else { return }
                                    userName = trimmed
                                    showRestartAlert = true
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.cyan)
                            }
                        }
                    } header: {
                        Text("ユーザー名")
                    } footer: {
                        Text("他のデバイスのタイムラインでこの名前で表示されます。変更後はアプリを再起動してください。")
                            .font(.caption)
                    }

                    // ── 録画設定 ────────────────────────────────────
                    Section {
                        Picker("解像度", selection: $selectedResolution) {
                            Text("720p HD").tag(VideoResolution.hd720p)
                            Text("1080p Full HD").tag(VideoResolution.hd1080p)
                            Text("4K").tag(VideoResolution.uhd4k)
                        }
                        .pickerStyle(.menu)

                        Picker("フレームレート", selection: $selectedFrameRate) {
                            Text("30 fps").tag(FrameRate.fps30)
                            Text("60 fps").tag(FrameRate.fps60)
                        }
                        .pickerStyle(.menu)

                        Picker("画面の向き", selection: $selectedOrientation) {
                            Text("横向き 📱").tag(VideoOrientation.landscape)
                            Text("縦向き ⬆️").tag(VideoOrientation.portrait)
                        }
                        .pickerStyle(.menu)
                        
                        Picker("ビデオコーデック", selection: $selectedCodec) {
                            Text("H.264 (標準)").tag(VideoCodec.h264)
                            Text("HEVC (高品質)").tag(VideoCodec.hevc)
                            Text("ProRes 422 (プロ向け)").tag(VideoCodec.proRes422)
                            Text("ProRes 4444 (最高品質)").tag(VideoCodec.proRes4444)
                        }
                        .pickerStyle(.menu)
                    } header: {
                        Text("録画設定")
                    } footer: {
                        Text(selectedCodec.description)
                            .font(.caption)
                    }

                    Section {
                        Button("設定を適用") {
                            applySettings()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
            }
            .onAppear {
                userNameDraft = userName
            }
            .alert("再起動が必要です", isPresented: $showRestartAlert) {
                Button("OK") { }
            } message: {
                Text("ユーザー名「\(userName)」を保存しました。次回アプリ起動時から反映されます。")
            }
        }
    }

    private func applySettings() {
        cameraManager.videoOrientation = selectedOrientation.avOrientation
        cameraManager.videoCodec = selectedCodec.avCodec
        print("📹 設定変更: 向き=\(selectedOrientation.rawValue), コーデック=\(selectedCodec.rawValue)")
    }
}

enum VideoResolution: String {
    case hd720p = "1280x720"
    case hd1080p = "1920x1080"
    case uhd4k = "3840x2160"
    
    var preset: AVCaptureSession.Preset {
        switch self {
        case .hd720p: return .hd1280x720
        case .hd1080p: return .hd1920x1080
        case .uhd4k: return .hd4K3840x2160
        }
    }
}

enum FrameRate: Int {
    case fps30 = 30
    case fps60 = 60
}

enum VideoOrientation: String {
    case landscape = "横向き"
    case portrait = "縦向き"
    
    var avOrientation: AVCaptureVideoOrientation {
        switch self {
        case .landscape: return .landscapeRight
        case .portrait: return .portrait
        }
    }
}
enum VideoCodec: String {
    case h264 = "H.264"
    case hevc = "HEVC"
    case proRes422 = "ProRes 422"
    case proRes4444 = "ProRes 4444"
    
    var avCodec: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        case .proRes422: return .proRes422
        case .proRes4444: return .proRes4444
        }
    }
    
    var description: String {
        switch self {
        case .h264:
            return "標準的なコーデック。ファイルサイズと品質のバランスが良い。"
        case .hevc:
            return "H.264より高品質・高圧縮。ファイルサイズが小さく、4K撮影に最適。"
        case .proRes422:
            return "プロ向けコーデック。編集に最適だが、ファイルサイズが非常に大きい。"
        case .proRes4444:
            return "最高品質のProRes。アルファチャンネル対応。ファイルサイズが最大。"
        }
    }
}

