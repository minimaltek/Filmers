//
//  ContentView.swift
//  Cinecam
//
//  Multi-device synchronized camera app
//

import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var sessionManager = CameraSessionManager()
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var library = SessionLibrary.shared
    @State private var showSettings = false
    @State private var showLibrary = false
    
    // 役割選択状態（nilなら未選択）
    @State private var selectedRole: DeviceRole? = nil
    // SEARCHING ドットアニメーション（0→1→2→3→0...）
    @State private var dotCount: Int = 0
    
    enum DeviceRole {
        case master
        case slave
    }
    
    var body: some View {
        Group {
            if selectedRole == nil {
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
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            dotCount = (dotCount + 1) % 9
        }
        .onChange(of: sessionManager.masterPeerID) { newMasterPeerID in
            if newMasterPeerID != nil,
               !sessionManager.isMaster,
               !sessionManager.connectedPeers.isEmpty {
                // マスターが設定され、かつ実際に接続済みピアがいる場合にスレーブに遷移
                withAnimation {
                    selectedRole = .slave
                }
            } else if newMasterPeerID == nil,
                      selectedRole == .slave {
                // マスターが切断された → 役割選択画面（SEARCHING状態）に戻る
                withAnimation {
                    selectedRole = nil
                }
            }
        }
        .onChange(of: sessionManager.connectedPeers.count) { _ in
            // ピアが接続された時点で、既にmasterPeerIDが設定済みならスレーブに遷移
            if sessionManager.masterPeerID != nil,
               !sessionManager.isMaster,
               !sessionManager.connectedPeers.isEmpty,
               selectedRole == nil {
                withAnimation {
                    selectedRole = .slave
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(cameraManager: cameraManager)
        }
        .sheet(isPresented: $showLibrary) {
            LibraryView(library: library)
        }
        .fullScreenCover(isPresented: $sessionManager.showPreview, onDismiss: {
            let wasMaster = sessionManager.cleanupSessionAfterPreview()
            if wasMaster {
                // マスター → roleSelectionScreenに戻る（MASTERボタンを再度押す）
                withAnimation {
                    selectedRole = nil
                }
            } else {
                // スレーブ → slaveWaitingView（AWAIT画面）に留まる
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
                onSaveEditState: { segmentsByDevice in
                    library.saveEditState(id: sessionManager.previewSessionID, segmentsByDevice: segmentsByDevice)
                },
                savedEditState: library.records.first(where: { $0.id == sessionManager.previewSessionID })?.editState ?? [:],
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
    }
    
    // MARK: - Setup
    
    private func setupCallbacks() {
        print("📹 [ContentView] Setting up callbacks")
        
        cameraManager.onRecordingCompleted = { [weak sessionManager] videoURL, sessionID in
            print("📹 [ContentView] Recording completed callback")
            sessionManager?.handleRecordingCompleted(videoURL: videoURL, sessionID: sessionID)
        }
        
        sessionManager.cameraManager = cameraManager
        print("📹 [ContentView] CameraManager linked to SessionManager")
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
    private let statusBlue = Color(red: 0.3, green: 0.55, blue: 1.0)
    private let logoDotWhite = Color.white
    
    /// アニメーションドット文字列（""→"."→".."→"..."）
    private var animatedDots: String {
        String(repeating: ".", count: dotCount)
    }
    
    /// iPad対応: コンテンツの最大幅（iPhone風のコンパクトなレイアウト）
    private let maxContentWidth: CGFloat = 420
    
    private var roleSelectionScreen: some View {
        VStack(spacing: 0) {
            // ── ヘッダー ──
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    (Text("CINECAM").foregroundColor(.white) + Text(".").foregroundColor(logoDotWhite))
                        .font(.system(size: 32, weight: .black, design: .default))
                        .fontWidth(.compressed)
                        .tracking(-0.5)
                    
                    HStack(spacing: 6) {
                        Circle()
                            .fill(sessionManager.connectionState == .connected ? accentGreen : statusBlue)
                            .frame(width: 8, height: 8)
                        if sessionManager.connectionState == .connected {
                            Text("SYSTEM READY")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .tracking(2)
                                .foregroundColor(accentGreen)
                        } else {
                            Text("SEARCHING\(animatedDots)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .tracking(2)
                                .foregroundColor(statusBlue)
                                .animation(.none, value: dotCount)
                        }
                    }
                }
                
                Spacer()
                
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
                .padding(.trailing, 12)
                
                // 設定ボタン
                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            
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
                    nodeRow(name: myName.uppercased(), isSelf: true)
                    
                    // 接続端末
                    ForEach(sessionManager.connectedPeerNames, id: \.self) { peerName in
                        nodeRow(name: peerName.uppercased(), isSelf: false)
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
            
            if sessionManager.connectedPeers.isEmpty {
                // ── 接続ピアなし: AWAITING表示 ──
                VStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 30, weight: .light))
                        .foregroundColor(.white.opacity(0.2))
                    
                    Text("AWAITING")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .tracking(3)
                        .foregroundColor(.white.opacity(0.2))
                    
                    Text("SEARCHING FOR\nNODES...")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(1)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white.opacity(0.15))
                }
                .frame(width: 150, height: 150)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.white.opacity(0.02))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
            } else {
                // ── 接続ピアあり: MASTERボタン ──
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
            }
            
            Spacer()
            
            // ── DISCONNECT SESSION ──
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
        .frame(maxWidth: maxContentWidth)
    }
    
    // ノード行（CONNECTED NODES用）
    private func nodeRow(name: String, isSelf: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "display")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.3))
            
            Text(name)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
            
            if isSelf {
                Text("(YOU)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
            }
            
            Spacer()
            
            // Signal indicator
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 14))
                .foregroundColor(.orange.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
                            (Text("CINECAM").foregroundColor(.white) + Text(".").foregroundColor(logoDotWhite))
                                .font(.system(size: 32, weight: .black, design: .default))
                                .fontWidth(.compressed)
                                .tracking(-0.5)
                            
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(sessionManager.connectionState == .connected ? accentGreen : statusBlue)
                                    .frame(width: 8, height: 8)
                                Text(sessionManager.isMaster ? "MASTER MODE" : "SLAVE MODE")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .tracking(2)
                                    .foregroundColor(sessionManager.isMaster ? .orange : accentGreen)
                            }
                        }
                        
                        Spacer()
                        
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
                        .padding(.trailing, 12)
                        
                        Button(action: { showSettings = true }) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 18))
                                .foregroundColor(.white.opacity(0.6))
                        }
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
                            nodeRow(name: myName.uppercased(), isSelf: true)
                            
                            ForEach(sessionManager.connectedPeerNames, id: \.self) { peerName in
                                nodeRow(name: peerName.uppercased(), isSelf: false)
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
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.orange)
                
                Text("TRANSFERRING")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .tracking(3)
                    .foregroundColor(.white.opacity(0.7))
                
                Text("\(sessionManager.receivedFiles) / \(sessionManager.totalExpectedFiles)")
                    .font(.system(size: 24, weight: .light, design: .monospaced))
                    .foregroundColor(.orange)
                
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
                        HStack(spacing: 6) {
                            Image(systemName: getLogIcon(log))
                                .font(.system(size: 8))
                                .foregroundColor(.white.opacity(0.35))
                            
                            Text(log)
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
    
    // MARK: - Master Control Screen
    
    private var masterControlView: some View {
        VStack(spacing: 16) {
            // Camera start button (status is shown inside the button itself)
            if !sessionManager.isCameraReady {
                let hasPeers = !sessionManager.connectedPeers.isEmpty
                let isWaiting = sessionManager.isWaitingForCameraReady
                
                Button(action: {
                    sessionManager.startCameraForAll()
                }) {
                    VStack(spacing: 10) {
                        if isWaiting {
                            ProgressView()
                                .tint(.orange)
                                .scaleEffect(1.2)
                                .frame(height: 30)
                        } else {
                            Image(systemName: "camera")
                                .font(.system(size: 30, weight: .light))
                                .foregroundColor(hasPeers ? .orange : .orange.opacity(0.4))
                        }
                        
                        Text(isWaiting ? "WAITING" : "START CAMERA")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .tracking(2)
                            .foregroundColor(hasPeers || isWaiting ? .orange : .orange.opacity(0.4))
                        
                        Text(isWaiting ? "SYNCING ALL NODES" :
                             hasPeers ? "ACTIVATE ALL NODES" : "NO NODES CONNECTED")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .tracking(1)
                            .foregroundColor(isWaiting ? .orange.opacity(0.5) :
                                             hasPeers ? .white.opacity(0.4) : .red.opacity(0.5))
                    }
                    .frame(width: 150, height: 150)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(
                                LinearGradient(
                                    colors: [Color.orange.opacity(hasPeers ? 0.15 : 0.05),
                                             Color.orange.opacity(hasPeers ? 0.05 : 0.02)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(Color.orange.opacity(hasPeers ? 0.4 : 0.15), lineWidth: 1)
                            )
                    )
                }
                .disabled(isWaiting || !hasPeers)
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
                        .foregroundColor(cyanTint)
                    
                    Text("AWAITING")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(cyanTint)
                    
                    Text("MASTER SIGNAL")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(1)
                        .foregroundColor(.white.opacity(0.4))
                }
                .frame(width: 150, height: 150)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(
                            LinearGradient(
                                colors: [cyanTint.opacity(0.1), cyanTint.opacity(0.03)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(cyanTint.opacity(0.3), lineWidth: 1)
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
                VStack(spacing: 0) {
                    Rectangle().fill(Color.black.opacity(0.6)).frame(height: max(bar, 0))
                    Spacer()
                    Rectangle().fill(Color.black.opacity(0.6)).frame(height: max(bar, 0))
                }
            } else if targetRatio < screenRatio - 0.05 {
                // ターゲットの方が縦長 → 左右に黒帯
                let cropW = h * targetRatio
                let bar = (w - cropW) / 2
                HStack(spacing: 0) {
                    Rectangle().fill(Color.black.opacity(0.6)).frame(width: max(bar, 0))
                    Spacer()
                    Rectangle().fill(Color.black.opacity(0.6)).frame(width: max(bar, 0))
                }
            } else {
                // アスペクト比がほぼ一致 → ガイド不要
                Color.clear
            }
        }
    }
}

#Preview {
    ContentView()
}
