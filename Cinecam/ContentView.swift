//
//  ContentView.swift
//  Cinecam
//
//  Multi-device synchronized camera app
//

import SwiftUI
import Combine
import MultipeerConnectivity

struct ContentView: View {
    @StateObject private var sessionManager = CameraSessionManager()
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var multiCamManager = MultiCamManager()
    @StateObject private var library = SessionLibrary.shared
    @State private var showSettings = false
    @State private var showLibrary = false
    @State private var isSingleMode = false
    
    // 役割選択状態（nilなら未選択）
    @State private var selectedRole: DeviceRole? = nil
    // SEARCHING ビートアニメーション（1個ずつ出て8個でスペース、を繰り返す）
    // Timer ではなく TimelineView + Date で駆動するため、メインスレッドのハングに影響されない
    /// 画面に収まる総ドット数（GeometryReaderで算出、8の倍数）
    @State private var beatGroupCount: Int = 16
    /// ビートの間隔（秒）
    private let beatInterval: Double = 0.5
    
    enum DeviceRole {
        case master
        case slave
    }
    
    var body: some View {
        Group {
            if isSingleMode {
                // シングルモード（前面+背面同時録画）
                singleModeScreen
            } else if selectedRole == nil {
                // 役割選択画面
                roleSelectionScreen
            } else {
                // メイン画面（カメラ or 接続中）
                mainScreen
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            setupCallbacks()
        }
        .onDisappear {
            cameraManager.stopSession()
        }
        // beatPhase は TimelineView から算出するため Timer 不要
        .onChange(of: sessionManager.masterPeerID) { newMasterPeerID in
            if newMasterPeerID != nil,
               !sessionManager.isMaster,
               !sessionManager.connectedPeers.isEmpty {
                // マスターが設定され、かつ実際に接続済みピアがいる場合にスレーブに遷移
                withAnimation {
                    selectedRole = .slave
                }
            } else if newMasterPeerID == nil,
                      selectedRole == .slave,
                      !sessionManager.persistentRole {
                // マスターが切断された → 役割選択画面（SEARCHING状態）に戻る（永続モードでは戻さない）
                withAnimation {
                    selectedRole = nil
                }
            }
        }
        .onChange(of: sessionManager.isMaster) { nowMaster in
            // ★ マスター衝突解決でスレーブに降格された場合
            if !nowMaster && selectedRole == .master && sessionManager.masterPeerID != nil {
                // 接続確立まではmainScreen（slaveWaitingView）で待機
                withAnimation {
                    selectedRole = .slave
                }
            }
        }
        .onChange(of: sessionManager.connectedPeers.count) { _ in
            // ピアが接続された時点で、既にmasterPeerIDが設定済みならスレーブに遷移
            if sessionManager.masterPeerID != nil,
               !sessionManager.isMaster,
               !sessionManager.connectedPeers.isEmpty,
               selectedRole == nil || selectedRole == .master {
                // selectedRole == .master: マスター衝突解決でスレーブに降格された場合
                withAnimation {
                    selectedRole = .slave
                }
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            sessionManager.resumeDiscovery()
        }) {
            SettingsView(cameraManager: cameraManager)
                .onAppear { sessionManager.pauseDiscovery() }
        }
        .sheet(isPresented: $showLibrary, onDismiss: {
            sessionManager.resumeDiscovery()
        }) {
            LibraryView(library: library)
                .onAppear { sessionManager.pauseDiscovery() }
        }
        .fullScreenCover(isPresented: $sessionManager.showPreview, onDismiss: {
            // Single Mode からの復帰
            if isSingleMode {
                multiCamManager.stopSession()
                OrientationLock.isCameraActive = false
                sessionManager.resumeDiscovery()
                withAnimation {
                    isSingleMode = false
                }
                return
            }
            let wasMaster = sessionManager.cleanupSessionAfterPreview()
            if sessionManager.persistentRole {
                // ★ 永続モード: マスターもスレーブも現在の役割画面にとどまる
                if wasMaster {
                    withAnimation {
                        selectedRole = .master
                    }
                    // マスターはカメラを自動起動する
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        sessionManager.startCameraForAll()
                    }
                } else {
                    withAnimation {
                        selectedRole = .slave
                    }
                }
            } else if wasMaster {
                // 非永続: マスター → roleSelectionScreenに戻る
                withAnimation {
                    selectedRole = nil
                }
            } else {
                // 非永続: スレーブ → slaveWaitingView（AWAIT画面）に留まる
                withAnimation {
                    selectedRole = .slave
                }
            }
        }) {
            PreviewView(
                sessionID: sessionManager.previewSessionID,
                videos: sessionManager.previewVideos,
                sessionTitle: library.records.first(where: { $0.id == sessionManager.previewSessionID })?.title ?? "UNTITLED",
                onRename: { newTitle in
                    library.rename(id: sessionManager.previewSessionID, title: newTitle)
                },
                onSaveEditState: { segmentsByDevice, lockedDevices, audioDevice, videoFilter, pitchCents, kaleidoscope, kSize, kCX, kCY, tH, speed, segFilterSettings in
                    library.saveEditState(id: sessionManager.previewSessionID, segmentsByDevice: segmentsByDevice, lockedDevices: lockedDevices, audioDevice: audioDevice, videoFilter: videoFilter, pitchCents: pitchCents, kaleidoscope: kaleidoscope, kaleidoscopeSize: kSize, kaleidoscopeCenterX: kCX, kaleidoscopeCenterY: kCY, tileHeight: tH, playbackSpeed: speed, segmentFilterSettings: segFilterSettings)
                },
                savedEditState: library.records.first(where: { $0.id == sessionManager.previewSessionID })?.editState ?? [:],
                savedLockedDevices: library.records.first(where: { $0.id == sessionManager.previewSessionID })?.lockedDevices ?? [],
                savedAudioDevice: library.records.first(where: { $0.id == sessionManager.previewSessionID })?.selectedAudioDevice,
                savedVideoFilter: library.records.first(where: { $0.id == sessionManager.previewSessionID })?.selectedVideoFilter,
                savedPitchCents: library.records.first(where: { $0.id == sessionManager.previewSessionID })?.pitchShiftCents ?? 0,
                savedKaleidoscope: library.records.first(where: { $0.id == sessionManager.previewSessionID })?.selectedKaleidoscope,
                savedKaleidoscopeSize: library.records.first(where: { $0.id == sessionManager.previewSessionID })?.kaleidoscopeSize ?? 200,
                savedKaleidoscopeCenterX: library.records.first(where: { $0.id == sessionManager.previewSessionID })?.kaleidoscopeCenterX ?? 0.5,
                savedKaleidoscopeCenterY: library.records.first(where: { $0.id == sessionManager.previewSessionID })?.kaleidoscopeCenterY ?? 0.5,
                savedTileHeight: library.records.first(where: { $0.id == sessionManager.previewSessionID })?.tileHeight ?? 200,
                savedPlaybackSpeed: library.records.first(where: { $0.id == sessionManager.previewSessionID })?.playbackSpeed ?? 1.0,
                onDeleteSession: {
                    library.delete(id: sessionManager.previewSessionID)
                },
                desiredOrientation: cameraManager.desiredOrientation
            )
        }
        .onChange(of: sessionManager.showPreview) { isShowing in
            if isShowing {
                library.add(
                    sessionID: sessionManager.previewSessionID,
                    videos: sessionManager.previewVideos,
                    orientation: cameraManager.desiredOrientation
                )
            }
        }
        .alert("Error", isPresented: .constant(cameraManager.error != nil)) {
            Button("OK") {
                cameraManager.error = nil
            }
        } message: {
            if let error = cameraManager.error {
                Text(error)
            }
        }
        .alert("Error", isPresented: .constant(multiCamManager.error != nil)) {
            Button("OK") {
                multiCamManager.error = nil
                if isSingleMode {
                    exitSingleMode()
                }
            }
        } message: {
            if let error = multiCamManager.error {
                Text(error)
            }
        }
    }
    
    // MARK: - Setup
    
    private func setupCallbacks() {
        #if DEBUG
        print("📹 [ContentView] Setting up callbacks")
        #endif
        
        cameraManager.onRecordingCompleted = { [weak sessionManager] videoURL, sessionID in
            #if DEBUG
            print("📹 [ContentView] Recording completed callback")
            #endif
            sessionManager?.handleRecordingCompleted(videoURL: videoURL, sessionID: sessionID)
        }
        
        sessionManager.cameraManager = cameraManager
        #if DEBUG
        print("📹 [ContentView] CameraManager linked to SessionManager")
        #endif
    }
    
    // MARK: - Role Selection Actions
    
    private func selectMasterRole() {
        sessionManager.selectMasterRole()
        withAnimation {
            selectedRole = .master
        }
    }
    
    // MARK: - Role Selection Screen
    
    private let accentGreen = Color(red: 0.0, green: 0.8, blue: 0.4)
    private let cyanTint = Color(red: 0.0, green: 0.7, blue: 0.65)
    private let matrixGreen = Color(red: 0.0, green: 1.0, blue: 0.25)
    private let logoDotWhite = Color.white
    
    /// 現在時刻からビートフェーズを算出（Timer 不要。TimelineView の date から呼ぶ）
    private func beatPhase(at date: Date) -> Int {
        let elapsed = date.timeIntervalSinceReferenceDate
        let totalPhases = beatGroupCount + 1  // 0=空 ～ N=全点灯 → 0にリセット
        guard totalPhases > 0 else { return 0 }
        let phase = Int(elapsed / beatInterval) % totalPhases
        return phase
    }

    /// ビートドット文字列（1個ずつ増え、8個ごとにスペースが入る）
    private func animatedDots(at date: Date) -> String {
        let phase = beatPhase(at: date)
        guard phase > 0 else { return "" }
        var result = ""
        for i in 1...phase {
            result += "."
            if i % 8 == 0 && i < phase {
                result += " "
            }
        }
        return result
    }
    
    /// iPad対応: コンテンツの最大幅（iPhone風のコンパクトなレイアウト）
    private let maxContentWidth: CGFloat = 420
    
    private var roleSelectionScreen: some View {
        VStack(spacing: 0) {
            // ── ヘッダー ──
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        (Text("CINECAM").foregroundColor(.white) + Text(".").foregroundColor(logoDotWhite))
                            .font(.system(size: 32, weight: .black, design: .default))
                            .fontWidth(.compressed)
                            .tracking(-0.5)
                        Text("v040")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    
                    if sessionManager.connectionState == .connected {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(accentGreen)
                                .frame(width: 8, height: 8)
                            Text("SYSTEM READY")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .tracking(2)
                                .foregroundColor(accentGreen)
                        }
                    }
                }
                
                Spacer()
                
                HStack(spacing: 12) {
                    // ライブラリボタン
                    Button(action: { showLibrary = true }) {
                        ZStack {
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: 18))
                                .foregroundColor(.white.opacity(0.6))
                            if !library.records.isEmpty {
                                Text("\(library.records.count)")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.black)
                                    .frame(width: 14, height: 14)
                                    .background(Color.orange)
                                    .clipShape(Circle())
                                    .offset(x: 10, y: -8)
                            }
                        }
                    }
                    
                    // 設定ボタン
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 18))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            
            // ── SEARCHING ドットアニメーション（TimelineView で駆動、メインスレッドハングに強い） ──
            if sessionManager.connectionState != .connected {
                TimelineView(.periodic(from: .now, by: beatInterval)) { context in
                    GeometryReader { geo in
                        let availableWidth = geo.size.width - 48
                        let charWidth: CGFloat = 8.0
                        let searchingWidth = charWidth * 9
                        let dotAreaWidth = availableWidth - searchingWidth - 14
                        let groupWidth = charWidth * 9
                        let groups = max(1, Int((dotAreaWidth + charWidth) / groupWidth))
                        let totalDots = groups * 8
                        let _ = DispatchQueue.main.async {
                            if beatGroupCount != totalDots {
                                beatGroupCount = totalDots
                            }
                        }

                        HStack(spacing: 6) {
                            Circle()
                                .fill(matrixGreen)
                                .frame(width: 8, height: 8)
                            Text("SEARCHING\(animatedDots(at: context.date))")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .tracking(2)
                                .foregroundColor(matrixGreen)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 24)
                    }
                }
                .frame(height: 16)
            }
            
            Spacer().frame(height: 20)
            
            // ── CONNECTED NODES ──
            VStack(spacing: 0) {
                // セクションヘッダー
                HStack {
                    Text("CONNECTED NODES")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(.white.opacity(0.4))
                    Spacer()
                    Text("\(sessionManager.connectedPeers.count + 1) Devices")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
                
                // ノードリスト
                VStack(spacing: 1) {
                    // 自分
                    let myName = UserDefaults.standard.string(forKey: "cinecam.userName")
                        .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                        ?? UIDevice.current.name
                    let selfIsMaster = sessionManager.isMaster
                    nodeRow(name: myName.uppercased(), isSelf: true,
                            score: sessionManager.deviceScore,
                            isMasterNode: selfIsMaster)
                    
                    // iOS接続端末
                    ForEach(sessionManager.connectedPeerNames, id: \.self) { peerName in
                        let peerIsMaster = sessionManager.masterPeerID?.displayName == peerName
                        nodeRow(name: peerName.uppercased(), isSelf: false,
                                score: sessionManager.peerScores[peerName] ?? 0,
                                isMasterNode: peerIsMaster)
                    }
                }
                .background(Color.white.opacity(0.03))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(cyanTint.opacity(0.15), lineWidth: 1)
                )
            }
            .padding(.horizontal, 24)
            
            Spacer().frame(height: 16)
            
            // ── ログ ──
            logView
                .padding(.horizontal, 24)
            
            Spacer()
            
            // ── MASTERボタン（接続済みピアがある時に表示） ──
            if !sessionManager.connectedPeers.isEmpty {
            Text("SELECT OPERATIONAL ROLE")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(3)
                .foregroundColor(.white.opacity(0.3))
                .padding(.bottom, 16)
            
            Button(action: {
                selectMasterRole()
            }) {
                VStack(spacing: 10) {
                    Image(systemName: "scope")
                        .font(.system(size: 30, weight: .light))
                        .foregroundColor(.orange)
                    
                    Text("MASTER")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .tracking(3)
                        .foregroundColor(.orange)
                    
                    Text("GLOBAL CONTROL\n& SEQUENCING")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(1)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white.opacity(0.4))
                }
                .frame(width: 150, height: 150)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(
                            LinearGradient(
                                colors: [Color.orange.opacity(0.15), Color.orange.opacity(0.05)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
                        )
                )
            }
            } // if connectedPeers
            
            Spacer()
            
            // ── SINGLE MODE + REBUILD SESSION（接続がない時に表示） ──
            if sessionManager.connectedPeers.isEmpty {
                // SINGLE MODE
                Button(action: {
                    enterSingleMode()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "camera.on.rectangle.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text("SINGLE MODE")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .tracking(2)
                    }
                    .foregroundColor(.orange.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                    )
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 12)
                
                // REBUILD SESSION
                Button(action: {
                    sessionManager.rebuildSession()
                }) {
                    HStack(spacing: 8) {
                        if sessionManager.isRebuilding {
                            ProgressView()
                                .tint(.cyan.opacity(0.5))
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        Text(sessionManager.isRebuilding ? "REBUILDING..." : "REBUILD SESSION")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .tracking(2)
                    }
                    .foregroundColor(sessionManager.isRebuilding ? .cyan.opacity(0.3) : .cyan.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(sessionManager.isRebuilding ? Color.cyan.opacity(0.1) : Color.cyan.opacity(0.2), lineWidth: 1)
                    )
                }
                .disabled(sessionManager.isRebuilding)
                .padding(.horizontal, 40)
                .padding(.bottom, 30)
            }
            
            // ── DISCONNECT SESSION（他ノードに接続中のみ表示） ──
            if !sessionManager.connectedPeers.isEmpty {
                Button(action: {
                    sessionManager.restartDiscovery()
                }) {
                    Text("DISCONNECT SESSION")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(.red.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.red.opacity(0.2), lineWidth: 1)
                        )
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 30)
            }
        }
        .frame(maxWidth: maxContentWidth)
    }
    
    // ノード行（CONNECTED NODES用）
    private func nodeRow(name: String, isSelf: Bool, score: Int, isMasterNode: Bool) -> some View {
        HStack(spacing: 8) {
            // アイコン: 自端末=人、他端末=スマホ
            Image(systemName: isSelf ? "person.fill" : "iphone")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.4))
                .frame(width: 16)
            
            // 名前（長い場合は truncate）
            Text(name)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.tail)
            
            // スコア表示
            Text("(\(score))")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.25))
                .layoutPriority(1)
            
            Spacer()
            
            // Signal indicator: MASTER確定時は緑、それ以外はオレンジ
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 14))
                .foregroundColor(isMasterNode ? accentGreen : .orange.opacity(0.7))
                .layoutPriority(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    
    // MARK: - Single Mode
    
    private var singleModeScreen: some View {
        ZStack {
            if let backPreview = multiCamManager.backPreviewLayer,
               let frontPreview = multiCamManager.frontPreviewLayer {
                MultiCamPreviewView(
                    backPreviewLayer: backPreview,
                    frontPreviewLayer: frontPreview,
                    activePosition: multiCamManager.activePosition,
                    multiCamManager: multiCamManager
                )
                .ignoresSafeArea()
                
                // クロップガイド（メイン + PiP穴あけ統合）
                GeometryReader { geo in
                    let isLandscape = geo.size.width > geo.size.height
                    let pipTrailing: CGFloat = isLandscape ? 110 : 70
                    let pipTop: CGFloat = isLandscape ? 16 : 60
                    let pipW: CGFloat = 120
                    let pipH: CGFloat = 160
                    let pipX = geo.size.width - pipW - pipTrailing
                    let pipY = pipTop
                    let pipRect = CGRect(x: pipX, y: pipY, width: pipW, height: pipH)
                    
                    CropGuideOverlay(
                        desiredOrientation: multiCamManager.desiredOrientation,
                        pipCutout: pipRect
                    )
                    
                    // クロップガイド（PiP小窓のみ）
                    CropGuideOverlay(desiredOrientation: multiCamManager.desiredOrientation)
                        .frame(width: pipW, height: pipH)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .position(x: pipX + pipW / 2, y: pipY + pipH / 2)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                
                // オーバーレイコントロール（既存UIと同等）
                SingleModeOverlayControls(
                    multiCamManager: multiCamManager,
                    onExit: exitSingleMode
                )
            } else {
                // カメラ初期化中
                VStack(spacing: 12) {
                    DancingLoaderView(size: 80, tint: .white.opacity(0.5))
                    Text("INITIALIZING CAMERAS...")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.ignoresSafeArea())
            }
        }
    }
    
    private func enterSingleMode() {
        // 非対応端末チェック
        guard MultiCamManager.isMultiCamSupported else {
            cameraManager.error = "This device does not support dual-camera recording"
            return
        }
        
        sessionManager.pauseDiscovery()
        
        // CameraManagerから設定を引き継ぎ
        multiCamManager.desiredOrientation = cameraManager.desiredOrientation
        multiCamManager.videoCodec = cameraManager.videoCodec
        
        // 録画完了コールバック
        multiCamManager.onRecordingCompleted = { [self] backURL, frontURL, sessionID in
            handleSingleModeRecordingCompleted(backURL: backURL, frontURL: frontURL, sessionID: sessionID)
        }
        
        // 先に画面遷移（ローディング画面を見せる）
        OrientationLock.isCameraActive = true
        withAnimation {
            isSingleMode = true
        }
        
        // マルチカムセッション起動（非同期で完了 → プレビューレイヤーが公開される）
        multiCamManager.setupAndStart()
    }
    
    private func exitSingleMode() {
        multiCamManager.stopSession()
        OrientationLock.isCameraActive = false
        sessionManager.resumeDiscovery()
        
        withAnimation {
            isSingleMode = false
        }
    }
    
    private func handleSingleModeRecordingCompleted(backURL: URL, frontURL: URL, sessionID: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        let backDest = docs.appendingPathComponent("\(sessionID)_BACK.mov")
        let frontDest = docs.appendingPathComponent("\(sessionID)_FRONT.mov")
        
        do {
            if FileManager.default.fileExists(atPath: backDest.path) {
                try FileManager.default.removeItem(at: backDest)
            }
            try FileManager.default.copyItem(at: backURL, to: backDest)
            
            if FileManager.default.fileExists(atPath: frontDest.path) {
                try FileManager.default.removeItem(at: frontDest)
            }
            try FileManager.default.copyItem(at: frontURL, to: frontDest)
        } catch {
            #if DEBUG
            print("❌ [SingleMode] File copy error: \(error)")
            #endif
            return
        }
        
        let videos: [String: URL] = [
            "BACK": backDest,
            "FRONT": frontDest
        ]
        
        // 既存のプレビューパイプラインに接続
        sessionManager.previewSessionID = sessionID
        sessionManager.previewVideos = videos
        
        // ライブラリに追加
        library.add(sessionID: sessionID, videos: videos, orientation: cameraManager.desiredOrientation)
        
        // プレビュー表示
        sessionManager.showPreview = true
    }
    
    // MARK: - Main Screen
    
    private var mainScreen: some View {
        ZStack {
            // カメラプレビュー（背景）
            if sessionManager.isCameraReady, let previewLayer = cameraManager.previewLayer {
                CameraPreviewView(previewLayer: previewLayer, cameraManager: cameraManager)
                    .ignoresSafeArea()
                
                // クロップガイド表示（desiredOrientationと端末の向きが異なる場合）
                CropGuideOverlay(desiredOrientation: cameraManager.desiredOrientation)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                
                // オーバーレイコントロール（セーフエリア内に配置）
                CameraOverlayControls(
                    cameraManager: cameraManager,
                    sessionManager: sessionManager
                )
                

            } else {
                // カメラ未起動時の画面（roleSelectionScreenと同じレイアウト）
                VStack(spacing: 0) {
                    // ── ヘッダー（roleSelectionScreenと統一） ──
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .lastTextBaseline, spacing: 4) {
                                (Text("CINECAM").foregroundColor(.white) + Text(".").foregroundColor(logoDotWhite))
                                    .font(.system(size: 32, weight: .black, design: .default))
                                    .fontWidth(.compressed)
                                    .tracking(-0.5)
                                Text("v040")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(sessionManager.connectionState == .connected ? accentGreen : matrixGreen)
                                    .frame(width: 8, height: 8)
                                Text(sessionManager.isMaster ? "MASTER MODE" : "SLAVE MODE")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .tracking(2)
                                    .foregroundColor(sessionManager.isMaster ? .orange : accentGreen)
                            }
                        }
                        
                        Spacer()
                        
                        HStack(spacing: 12) {
                            Button(action: { showLibrary = true }) {
                                ZStack {
                                    Image(systemName: "square.grid.2x2")
                                        .font(.system(size: 18))
                                        .foregroundColor(.white.opacity(0.6))
                                    if !library.records.isEmpty {
                                        Text("\(library.records.count)")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundColor(.black)
                                            .frame(width: 14, height: 14)
                                            .background(Color.orange)
                                            .clipShape(Circle())
                                            .offset(x: 10, y: -8)
                                    }
                                }
                            }
                            
                            Button(action: { showSettings = true }) {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 18))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                        }
                        .padding(.top, 8)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    
                    Spacer().frame(height: 20)
                    
                    // ── CONNECTED NODES ──
                    VStack(spacing: 0) {
                        HStack {
                            Text("CONNECTED NODES")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .tracking(2)
                                .foregroundColor(.white.opacity(0.4))
                            Spacer()
                            Text("\(sessionManager.connectedPeers.count + 1) Devices")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white.opacity(0.3))
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                        
                        VStack(spacing: 1) {
                            let myName = UserDefaults.standard.string(forKey: "cinecam.userName")
                                .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                                ?? UIDevice.current.name
                            let selfIsMaster = sessionManager.isMaster
                            nodeRow(name: myName.uppercased(), isSelf: true,
                                    score: sessionManager.deviceScore,
                                    isMasterNode: selfIsMaster)
                            
                            ForEach(sessionManager.connectedPeerNames, id: \.self) { peerName in
                                let peerIsMaster = sessionManager.masterPeerID?.displayName == peerName
                                nodeRow(name: peerName.uppercased(), isSelf: false,
                                        score: sessionManager.peerScores[peerName] ?? 0,
                                        isMasterNode: peerIsMaster)
                            }
                        }
                        .background(Color.white.opacity(0.03))
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(cyanTint.opacity(0.15), lineWidth: 1)
                        )
                    }
                    .padding(.horizontal, 24)
                    
                    Spacer().frame(height: 16)
                    
                    // ── ログ ──
                    logView
                        .padding(.horizontal, 24)
                    
                    Spacer()
                    
                    // ── 中央コンテンツ（Master / Slave 分岐） ──
                    if sessionManager.isMaster {
                        masterControlView
                    } else {
                        slaveWaitingView
                    }
                    
                    Spacer()
                    
                    // ── DISCONNECT ──
                    Button(action: {
                        sessionManager.restartDiscovery()
                        withAnimation { selectedRole = nil }
                    }) {
                        Text("DISCONNECT SESSION")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .tracking(2)
                            .foregroundColor(.red.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.red.opacity(0.2), lineWidth: 1)
                            )
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 30)
                }
                .frame(maxWidth: maxContentWidth)
            }
            
            // 転送中プログレス表示
            if sessionManager.isTransferring {
                transferProgressView
            }
        }
    }
    
    // MARK: - Transfer Progress View
    
    private var transferProgressView: some View {
        ZStack {
            Color.black.opacity(0.9)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                DancingLoaderView(size: 80)
                
                Text("TRANSFERRING")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .tracking(3)
                    .foregroundColor(.white.opacity(0.7))
                
                Text("\(sessionManager.receivedFiles) / \(sessionManager.totalExpectedFiles)")
                    .font(.system(size: 24, weight: .light, design: .monospaced))
                    .foregroundColor(.orange)
                
                // プログレスバー（転送進捗 — 送信 or 受信）
                if sessionManager.currentTransferProgress > 0 {
                    VStack(spacing: 8) {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.white.opacity(0.1))
                                    .frame(height: 6)
                                
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.orange)
                                    .frame(width: geometry.size.width * sessionManager.currentTransferProgress, height: 6)
                                    .animation(.linear(duration: 0.3), value: sessionManager.currentTransferProgress)
                            }
                        }
                        .frame(height: 6)
                        .padding(.horizontal, 40)
                        
                        Text("\(Int(sessionManager.currentTransferProgress * 100))%")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                
                // 残り時間表示
                if !sessionManager.transferETAString.isEmpty {
                    Text(sessionManager.transferETAString)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.orange.opacity(0.8))
                }
                
                Button(action: {
                    sessionManager.isTransferring = false
                }) {
                    Text("CANCEL")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(.red.opacity(0.6))
                        .padding(.horizontal, 30)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.red.opacity(0.2), lineWidth: 1)
                        )
                }
                .padding(.top, 10)
            }
        }
    }
    
    // MARK: - ログ表示（5行、モノクロアイコン、最新が下）
    
    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(sessionManager.logs.enumerated()), id: \.offset) { index, log in
                        let parts = parseLog(log)
                        HStack(spacing: 4) {
                            Text(parts.time)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(.white.opacity(0.35))
                            Image(systemName: getLogIcon(parts.message))
                                .font(.system(size: 8))
                                .foregroundColor(.white.opacity(0.35))
                            Text(parts.message)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                        .id(index)
                    }
                }
            }
            .frame(height: 70)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .onChange(of: sessionManager.logs.count) { _ in
                if let lastIndex = sessionManager.logs.indices.last {
                    withAnimation {
                        proxy.scrollTo(lastIndex, anchor: .bottom)
                    }
                }
            }
        }
    }
    
    // ログの種類に応じたモノクロアイコン
    private func getLogIcon(_ log: String) -> String {
        if log.contains("failed") || log.contains("error") || log.contains("Disconnected") { return "xmark.circle" }
        if log.contains("Connected") || log.contains("Accepted") || log.contains("ready") { return "checkmark.circle" }
        if log.contains("Found") || log.contains("discovery") || log.contains("lost") { return "magnifyingglass.circle" }
        if log.contains("Inviting") || log.contains("Sent") || log.contains("sent") { return "arrow.up.circle" }
        if log.contains("Received") || log.contains("Receiving") || log.contains("Invitation") { return "arrow.down.circle" }
        if log.contains("Connecting") || log.contains("retry") || log.contains("Preview closed") { return "arrow.clockwise.circle" }
        if log.contains("Master") { return "crown" }
        if log.contains("Recording") || log.contains("Fire") { return "video.circle" }
        if log.contains("Stopped") || log.contains("Stop") { return "stop.circle" }
        if log.contains("Slave") { return "iphone.circle" }
        if log.contains("Waiting") || log.contains("timeout") { return "clock" }
        return "circle"
    }
    
    /// ログ文字列を "[HH:mm:ss] メッセージ" → (time, message) に分解
    private func parseLog(_ log: String) -> (time: String, message: String) {
        // "[HH:mm:ss] メッセージ" 形式を分割
        if log.hasPrefix("["), let closeBracket = log.firstIndex(of: "]") {
            let time = String(log[log.startIndex...closeBracket])
            let msg = String(log[log.index(after: closeBracket)...]).trimmingCharacters(in: .whitespaces)
            return (time, msg)
        }
        return ("", log)
    }
    
    // MARK: - Master Control Screen
    
    private var masterControlView: some View {
        VStack(spacing: 16) {
            // Camera start button (status is shown inside the button itself)
            if !sessionManager.isCameraReady {
                let hasPeers = !sessionManager.connectedPeers.isEmpty
                let isWaiting = sessionManager.isWaitingForCameraReady
                
                if isWaiting {
                    // WAITING状態（グレー、ボタンではなく表示のみ）
                    VStack(spacing: 10) {
                        DancingLoaderView(size: 60)
                        
                        Text("WAITING")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .tracking(2)
                            .foregroundColor(.gray)
                        
                        Text("SYNCING ALL NODES")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .tracking(1)
                            .foregroundColor(.gray.opacity(0.5))
                    }
                    .frame(width: 150, height: 150)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color.white.opacity(0.03))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                    )
                } else if !hasPeers && sessionManager.isRetrying {
                    // RECONNECTING状態（リトライ中でピアなし）
                    VStack(spacing: 10) {
                        DancingLoaderView(size: 60)
                        
                        Text("RECONNECTING")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .tracking(2)
                            .foregroundColor(.orange)
                        
                        Text("SEARCHING FOR NODES")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .tracking(1)
                            .foregroundColor(.orange.opacity(0.5))
                    }
                    .frame(width: 150, height: 150)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color.orange.opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                            )
                    )
                } else {
                    // START CAMERAボタン（赤）
                    Button(action: {
                        sessionManager.startCameraForAll()
                    }) {
                        VStack(spacing: 10) {
                            Image(systemName: "camera")
                                .font(.system(size: 30, weight: .light))
                                .foregroundColor(hasPeers ? .red : .red.opacity(0.4))
                            
                            Text("START CAMERA")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .tracking(2)
                                .foregroundColor(hasPeers ? .red : .red.opacity(0.4))
                            
                            Text(hasPeers ? "ACTIVATE ALL NODES" : "NO NODES CONNECTED")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .tracking(1)
                                .foregroundColor(hasPeers ? .white.opacity(0.4) : .red.opacity(0.5))
                        }
                        .frame(width: 150, height: 150)
                        .background(
                            RoundedRectangle(cornerRadius: 18)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.red.opacity(hasPeers ? 0.15 : 0.05),
                                                 Color.red.opacity(hasPeers ? 0.05 : 0.02)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18)
                                        .stroke(Color.red.opacity(hasPeers ? 0.4 : 0.15), lineWidth: 1)
                                )
                        )
                    }
                    .disabled(!hasPeers)
                    .opacity(hasPeers ? 1.0 : 0.35)
                }
            }
            
            // Session ID
            if !sessionManager.sessionID.isEmpty {
                Text("SESSION: \(sessionManager.sessionID)")
                    .font(.system(size: 9, design: .monospaced))
                    .tracking(1)
                    .foregroundColor(.white.opacity(0.25))
            }
        }
    }
    
    // MARK: - Slave Waiting Screen
    
    private var slaveWaitingView: some View {
        VStack(spacing: 16) {
            // Waiting indicator
            if !sessionManager.isCameraReady {
                VStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 30, weight: .light))
                        .foregroundColor(accentGreen)
                    
                    Text("AWAITING")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(accentGreen)
                    
                    Text("MASTER SIGNAL")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(1)
                        .foregroundColor(accentGreen.opacity(0.5))
                }
                .frame(width: 150, height: 150)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(
                            LinearGradient(
                                colors: [accentGreen.opacity(0.1), accentGreen.opacity(0.03)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(accentGreen.opacity(0.3), lineWidth: 1)
                        )
                )
            }
            
            // Session ID
            if !sessionManager.sessionID.isEmpty {
                Text("SESSION: \(sessionManager.sessionID)")
                    .font(.system(size: 9, design: .monospaced))
                    .tracking(1)
                    .foregroundColor(.white.opacity(0.25))
            }
        }
    }
}

// MARK: - Crop Guide Overlay

/// desiredOrientation のアスペクト比に合わせて、
/// クロップされる領域を半透明の黒帯で示すオーバーレイ
struct CropGuideOverlay: View {
    let desiredOrientation: VideoOrientation
    /// PiP小窓を避けるための穴あけ領域（nil = 穴なし）
    var pipCutout: CGRect? = nil
    
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let screenRatio = h > 0 ? w / h : 1.0
            let targetRatio = desiredOrientation.aspectRatio
            
            if targetRatio > screenRatio + 0.05 {
                // ターゲットの方が横長 → 上下に黒帯
                let cropH = w / targetRatio
                let bar = (h - cropH) / 2
                Canvas { ctx, size in
                    let topRect = CGRect(x: 0, y: 0, width: size.width, height: max(bar, 0))
                    let bottomRect = CGRect(x: 0, y: size.height - max(bar, 0), width: size.width, height: max(bar, 0))
                    drawBarsWithCutout(ctx: &ctx, rects: [topRect, bottomRect], pip: pipCutout)
                }
            } else if targetRatio < screenRatio - 0.05 {
                // ターゲットの方が縦長 → 左右に黒帯
                let cropW = h * targetRatio
                let bar = (w - cropW) / 2
                Canvas { ctx, size in
                    let leftRect = CGRect(x: 0, y: 0, width: max(bar, 0), height: size.height)
                    let rightRect = CGRect(x: size.width - max(bar, 0), y: 0, width: max(bar, 0), height: size.height)
                    drawBarsWithCutout(ctx: &ctx, rects: [leftRect, rightRect], pip: pipCutout)
                }
            } else {
                // アスペクト比がほぼ一致 → ガイド不要
                Color.clear
            }
        }
    }

    /// 黒帯矩形からPiP領域を差し引いた残り矩形群を返す（最大4分割）
    private static func subtractRect(bar: CGRect, hole: CGRect) -> [CGRect] {
        let inter = bar.intersection(hole)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else {
            return [bar]  // 交差なし → そのまま
        }
        var pieces: [CGRect] = []
        // 上の残り
        if inter.minY > bar.minY {
            pieces.append(CGRect(x: bar.minX, y: bar.minY,
                                 width: bar.width, height: inter.minY - bar.minY))
        }
        // 下の残り
        if inter.maxY < bar.maxY {
            pieces.append(CGRect(x: bar.minX, y: inter.maxY,
                                 width: bar.width, height: bar.maxY - inter.maxY))
        }
        // 左の残り（交差行の範囲内）
        let midTop = max(bar.minY, inter.minY)
        let midBot = min(bar.maxY, inter.maxY)
        if inter.minX > bar.minX {
            pieces.append(CGRect(x: bar.minX, y: midTop,
                                 width: inter.minX - bar.minX, height: midBot - midTop))
        }
        // 右の残り（交差行の範囲内）
        if inter.maxX < bar.maxX {
            pieces.append(CGRect(x: inter.maxX, y: midTop,
                                 width: bar.maxX - inter.maxX, height: midBot - midTop))
        }
        return pieces
    }

    /// 黒帯を描画し、PiP領域を矩形分割で穴あけする
    private func drawBarsWithCutout(ctx: inout GraphicsContext, rects: [CGRect], pip: CGRect?) {
        let color = Color.black.opacity(0.6)
        for rect in rects {
            if let pip {
                let pieces = Self.subtractRect(bar: rect, hole: pip)
                for piece in pieces {
                    ctx.fill(Path(piece), with: .color(color))
                }
            } else {
                ctx.fill(Path(rect), with: .color(color))
            }
        }
    }
}

#Preview {
    ContentView()
}
