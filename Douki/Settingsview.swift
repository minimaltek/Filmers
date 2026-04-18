//
//  SettingsView.swift
//  Douki
//
//  カメラ設定画面
//

import SwiftUI
import AVFoundation
import Combine

// MARK: - Purchase Manager

/// 課金状態を管理するシングルトン
/// 開発中は UserDefaults で管理、リリース時は StoreKit に移行
class PurchaseManager: ObservableObject {
    static let shared = PurchaseManager()

    @Published var isPremium: Bool {
        didSet { UserDefaults.standard.set(isPremium, forKey: "douki.isPremium") }
    }

    init() {
        isPremium = UserDefaults.standard.bool(forKey: "douki.isPremium")
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var cameraManager: CameraManager
    @ObservedObject private var purchaseManager = PurchaseManager.shared

    @State private var selectedResolution: VideoResolution = .hd1080p
    @State private var selectedFrameRate: FrameRate = .fps30
    @State private var selectedOrientation: VideoOrientation = .cinema
    @State private var selectedCodec: VideoCodec = .hevc

    /// UserDefaults に永続化するユーザー名
    @AppStorage("douki.userName") private var userName: String = UIDevice.current.name
    /// 編集中の一時テキスト
    @State private var userNameDraft: String = ""


    var body: some View {
        NavigationView {
            Form {
                    // ── User Name ──────────────────────────────
                    Section {
                        HStack {
                            TextField("User Name", text: $userNameDraft)
                                .foregroundColor(.white)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            if userNameDraft != userName {
                                Button("Save") {
                                    let trimmed = userNameDraft.trimmingCharacters(in: .whitespaces)
                                    guard !trimmed.isEmpty else { return }
                                    userName = trimmed
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.blue)
                            }
                        }
                        .listRowBackground(Color.white.opacity(0.08))
                    } header: {
                        Text("User Name")
                    } footer: {
                        Text("This name will be shown on other devices' timelines.")
                            .font(.caption)
                    }

                    // ── Recording Settings ────────────────────────────────────
                    Section {
                        Picker("Resolution", selection: $selectedResolution) {
                            Text("720p HD").tag(VideoResolution.hd720p)
                            Text("1080p Full HD").tag(VideoResolution.hd1080p)
                            Text("4K").tag(VideoResolution.uhd4k)
                        }
                        .pickerStyle(.menu)
                        .listRowBackground(Color.white.opacity(0.08))

                        Picker("Frame Rate", selection: $selectedFrameRate) {
                            Text("30 fps").tag(FrameRate.fps30)
                            Text("60 fps").tag(FrameRate.fps60)
                        }
                        .pickerStyle(.menu)
                        .listRowBackground(Color.white.opacity(0.08))

                        Picker("Aspect Ratio", selection: $selectedOrientation) {
                            Text("Landscape - Cinema (2.39:1)").tag(VideoOrientation.cinema)
                            Text("Landscape - TV (16:9)").tag(VideoOrientation.landscape)
                            Text("Portrait - Phone (9:16)").tag(VideoOrientation.portrait)
                        }
                        .pickerStyle(.menu)
                        .listRowBackground(Color.white.opacity(0.08))
                        
                        Picker("Video Codec", selection: $selectedCodec) {
                            Text("H.264 (Standard)").tag(VideoCodec.h264)
                            Text("HEVC (High Quality)").tag(VideoCodec.hevc)
                            Text("ProRes 422 (Professional)").tag(VideoCodec.proRes422)
                            Text("ProRes 4444 (Highest Quality)").tag(VideoCodec.proRes4444)
                        }
                        .pickerStyle(.menu)
                        .listRowBackground(Color.white.opacity(0.08))
                    } header: {
                        Text("Recording Settings")
                    } footer: {
                        Text(selectedCodec.description)
                            .font(.caption)
                    }

                    #if DEBUG
                    // ── Developer ──────────────────────────────
                    Section {
                        Toggle("Premium Mode", isOn: $purchaseManager.isPremium)
                            .tint(.cyan)
                            .listRowBackground(Color.white.opacity(0.08))
                    } header: {
                        Text("Developer")
                    } footer: {
                        Text(purchaseManager.isPremium
                             ? "Export without watermark"
                             : "Export with Douki watermark")
                            .font(.caption)
                    }
                    #endif
                }
                .scrollContentBackground(.hidden)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
            }
            .onAppear {
                userNameDraft = userName
                selectedOrientation = cameraManager.desiredOrientation
                selectedCodec = VideoCodec.from(avCodec: cameraManager.videoCodec)
            }
            .onDisappear {
                applySettings()
            }

        }
        .preferredColorScheme(.dark)
    }

    private func applySettings() {
        cameraManager.desiredOrientation = selectedOrientation
        cameraManager.videoOrientation = selectedOrientation.avOrientation
        cameraManager.videoCodec = selectedCodec.avCodec
        #if DEBUG
        print("📹 Settings changed: orientation=\(selectedOrientation.rawValue), codec=\(selectedCodec.rawValue)")
        #endif
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

enum VideoOrientation: String, Codable {
    case cinema   = "横（シネマ）"    // 2.39:1
    case landscape = "横（テレビ）"   // 16:9  ← 旧 "横向き" との後方互換
    case portrait  = "縦（スマホ）"   // 9:16  ← 旧 "縦向き" との後方互換

    /// クロップ時のアスペクト比
    var aspectRatio: CGFloat {
        switch self {
        case .cinema:    return 2.39
        case .landscape: return 16.0 / 9.0
        case .portrait:  return 9.0 / 16.0
        }
    }
    
    /// 横向き系か（端末が縦持ちの場合にクロップが必要）
    var isLandscape: Bool {
        switch self {
        case .cinema, .landscape: return true
        case .portrait:           return false
        }
    }

    var avOrientation: AVCaptureVideoOrientation {
        switch self {
        case .cinema, .landscape: return .landscapeRight
        case .portrait:           return .portrait
        }
    }

    /// 旧rawValue（"横向き"/"縦向き"）からのデコード互換
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "横向き":  self = .landscape
        case "縦向き":  self = .portrait
        default:       self = VideoOrientation(rawValue: raw) ?? .cinema
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

    static func from(avCodec: AVVideoCodecType) -> VideoCodec {
        switch avCodec {
        case .h264:       return .h264
        case .hevc:       return .hevc
        case .proRes422:  return .proRes422
        case .proRes4444: return .proRes4444
        default:          return .hevc
        }
    }
    
    var description: String {
        switch self {
        case .h264:
            return "Standard codec. Good balance of file size and quality."
        case .hevc:
            return "Higher quality & compression than H.264. Smaller files, ideal for 4K."
        case .proRes422:
            return "Professional codec. Best for editing, but very large file size."
        case .proRes4444:
            return "Highest quality ProRes. Alpha channel support. Largest file size."
        }
    }
}

#Preview("SettingsView") {
    SettingsView(cameraManager: .previewMock)
        .preferredColorScheme(.dark)
}
