//
//  SettingsView.swift
//  Filmers
//
//  カメラ設定画面
//

import SwiftUI
import AVFoundation
import Combine
import StoreKit

// MARK: - Purchase Manager

/// 課金状態を管理するシングルトン（StoreKit 2 買い切り）
/// Product ID: com.douki.app.pro
@MainActor
class PurchaseManager: ObservableObject {
    static let shared = PurchaseManager()

    /// プロダクトID（App Store Connect で登録したIDに合わせること）
    static let productID = "douki.premium"

    @Published private(set) var isPremium: Bool = false
    @Published private(set) var product: Product? = nil
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String? = nil

    private var transactionListenerTask: Task<Void, Never>?

    init() {
        transactionListenerTask = listenForTransactions()
        Task { await refreshStatus() }
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    // MARK: - 購入

    func purchase() async {
        guard let product else { return }
        isLoading = true
        errorMessage = nil
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                isPremium = true
            case .userCancelled:
                break
            case .pending:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - リストア

    func restore() async {
        isLoading = true
        errorMessage = nil
        do {
            try await AppStore.sync()
            await refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - 状態更新

    func refreshStatus() async {
        // プロダクト情報取得
        if product == nil {
            do {
                let products = try await Product.products(for: [Self.productID])
                product = products.first
            } catch {
                // ネットワーク不可時はスキップ
            }
        }
        // 購入済みトランザクション確認
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.productID,
               transaction.revocationDate == nil {
                isPremium = true
                return
            }
        }
        // デバッグ時は UserDefaults フォールバック
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "douki.isPremium") {
            isPremium = true
        }
        #endif
    }

    // MARK: - トランザクションリスナー

    private func listenForTransactions() -> Task<Void, Never> {
        Task(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = result,
                   transaction.productID == Self.productID,
                   transaction.revocationDate == nil {
                    await MainActor.run { self.isPremium = true }
                    await transaction.finish()
                }
            }
        }
    }

    // MARK: - 検証ヘルパー

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let value):
            return value
        }
    }

    enum StoreError: Error {
        case failedVerification
    }

    // MARK: - DEBUG only

    #if DEBUG
    func debugSetPremium(_ value: Bool) {
        isPremium = value
        UserDefaults.standard.set(value, forKey: "douki.isPremium")
    }
    #endif
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

                    // ── Filmers Pro ──────────────────────────────
                    Section {
                        if purchaseManager.isPremium {
                            HStack {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundColor(.cyan)
                                Text("Filmers Pro")
                                    .foregroundColor(.white)
                                Spacer()
                                Text("Active")
                                    .font(.caption)
                                    .foregroundColor(.cyan)
                            }
                            .listRowBackground(Color.white.opacity(0.08))
                        } else {
                            // 購入ボタン
                            Button(action: {
                                Task { await purchaseManager.purchase() }
                            }) {
                                HStack {
                                    if purchaseManager.isLoading {
                                        ProgressView()
                                            .tint(.white)
                                    } else {
                                        Image(systemName: "star.fill")
                                            .foregroundColor(.yellow)
                                        Text(purchaseManager.product != nil
                                             ? "Upgrade to Filmers Pro  \(purchaseManager.product!.displayPrice)"
                                             : "Upgrade to Filmers Pro")
                                            .foregroundColor(.white)
                                    }
                                    Spacer()
                                }
                            }
                            .disabled(purchaseManager.isLoading || purchaseManager.product == nil)
                            .listRowBackground(Color.white.opacity(0.08))

                            // リストアボタン
                            Button(action: {
                                Task { await purchaseManager.restore() }
                            }) {
                                HStack {
                                    Image(systemName: "arrow.clockwise")
                                        .foregroundColor(.gray)
                                    Text("Restore Purchase")
                                        .foregroundColor(.gray)
                                    Spacer()
                                }
                            }
                            .disabled(purchaseManager.isLoading)
                            .listRowBackground(Color.white.opacity(0.08))
                        }

                        // エラー表示
                        if let err = purchaseManager.errorMessage {
                            Text(err)
                                .font(.caption)
                                .foregroundColor(.red)
                                .listRowBackground(Color.white.opacity(0.08))
                        }
                    } header: {
                        Text("Filmers Pro")
                    } footer: {
                        Text(purchaseManager.isPremium
                             ? "Exporting without watermark."
                             : "Remove the Filmers watermark from exported videos.")
                            .font(.caption)
                    }

                    #if DEBUG
                    // ── Developer ──────────────────────────────
                    Section {
                        Toggle("Premium Mode (Debug)", isOn: Binding(
                            get: { purchaseManager.isPremium },
                            set: { purchaseManager.debugSetPremium($0) }
                        ))
                        .tint(.cyan)
                        .listRowBackground(Color.white.opacity(0.08))
                    } header: {
                        Text("Developer")
                    } footer: {
                        Text(purchaseManager.isPremium
                             ? "Export without watermark"
                             : "Export with Filmers watermark")
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
