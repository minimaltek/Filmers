//
//  ContentView.swift
//  Cinecam
//
//  Phase 2: カメラ録画機能付き
//

import SwiftUI

struct ContentView: View {
    @StateObject private var sessionManager = CameraSessionManager()
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var library = SessionLibrary.shared
    @State private var showLogs = true
    @State private var showSettings = false
    @State private var showLibrary = false
    
    var body: some View {
        ZStack {
            // カメラプレビュー（役割決定後、previewLayer が準備できていれば表示）
            if let previewLayer = cameraManager.previewLayer,
               (sessionManager.masterPeerID != nil || sessionManager.isMaster) {
                ZStack {
                    CameraPreviewView(previewLayer: previewLayer)
                        .ignoresSafeArea()
                        // previewLayer が後から届いたときに再描画を確実にトリガー
                        .id(ObjectIdentifier(previewLayer))
                    
                    // カメラコントロールのオーバーレイ（カメラ起動後のみ）
                    if sessionManager.isCameraReady {
                        CameraOverlayControls(
                            cameraManager: cameraManager,
                            sessionManager: sessionManager
                        )
                        .ignoresSafeArea()
                    }
                }
            } else {
                Color.black
                    .ignoresSafeArea()
            }
            
            VStack(spacing: 10) {
                // カメラ起動後はヘッダー・ログ・コントロールを非表示
                if !sessionManager.isCameraReady {
                    // ヘッダー
                    headerView
                    
                    // 接続状態表示
                    connectionStatusView
                    
                    // ログ表示エリア（5行）
                    logView
                    
                    // メインコンテンツ（間を詰める）
                    mainContent
                        .padding(.top, 5)
                    
                    Spacer()
                }
            }
            .padding()
        }
        .onAppear {
            print("📹 [ContentView] ========== ON APPEAR ==========")
            print("📹 [ContentView] Setting up callback")
            
            // カメラマネージャーの録画完了コールバックを設定
            cameraManager.onRecordingCompleted = { [weak sessionManager] videoURL, sessionID in
                print("📹 [ContentView] ========== CALLBACK TRIGGERED ==========")
                print("📹 [ContentView] VideoURL: \(videoURL.path)")
                print("📹 [ContentView] SessionID: \(sessionID)")
                print("📹 [ContentView] SessionManager exists: \(sessionManager != nil)")
                
                sessionManager?.handleRecordingCompleted(videoURL: videoURL, sessionID: sessionID)
                
                print("📹 [ContentView] Callback processing completed")
            }
            
            print("📹 [ContentView] Callback set: \(cameraManager.onRecordingCompleted != nil)")
            
            sessionManager.cameraManager = cameraManager
            print("📹 [ContentView] CameraManager linked to SessionManager")

            // ⚠️ onAppear でのカメラセットアップを廃止。
            // AVCaptureSession の初期化はメインスレッドと競合し、
            // MultipeerConnectivity のチャンネル確立タイムアウトを引き起こす。
            // カメラの準備は役割確定後（selectMasterRole / selectSlaveRole）に行う。
            print("📹 [ContentView] Camera setup deferred to role selection")
            print("📹 [ContentView] ==========================================")
        }
        .onDisappear {
            cameraManager.stopSession()
        }
        .onChange(of: sessionManager.connectionState) { newState in
            // 接続が切れたらカメラを停止
            if newState == .disconnected {
                cameraManager.stopSession()
            }
        }
        .alert("エラー", isPresented: .constant(cameraManager.error != nil)) {
            Button("OK") {
                cameraManager.error = nil
            }
        } message: {
            if let error = cameraManager.error {
                Text(error)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(cameraManager: cameraManager)
        }
        .sheet(isPresented: $showLibrary) {
            LibraryView(library: library)
        }
        .fullScreenCover(isPresented: $sessionManager.showPreview, onDismiss: {
            // プレビューを閉じたら MCSession をクリーンアップ
            sessionManager.cleanupSessionAfterPreview()
            
            // カメラは起動しない（接続画面に戻る）
            // カメラは必要に応じて再度「Start Camera」ボタンで起動する
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
                savedEditState: library.records.first(where: { $0.id == sessionManager.previewSessionID })?.editState ?? [:]
            )
        }
        // showPreview が true になった瞬間（描画外）にライブラリへ先行登録する
        // ViewBuilder 内で @Published を変更すると "Publishing changes from within view updates" 警告が出るため
        .onChange(of: sessionManager.showPreview) { isShowing in
            if isShowing {
                library.add(
                    sessionID: sessionManager.previewSessionID,
                    videos: sessionManager.previewVideos
                )
            }
        }
        .overlay(
            Group {
                if sessionManager.isTransferring {
                    transferProgressView
                }
            }
        )
    }
    
    // MARK: - Transfer Progress View
    
    private var transferProgressView: some View {
        ZStack {
            Color.black.opacity(0.8)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
                
                Text("Transferring videos...")
                    .font(.headline)
                    .foregroundColor(.white)
                
                Text("\(sessionManager.receivedFiles) / \(sessionManager.totalExpectedFiles)")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
                
                Button("Cancel") {
                    sessionManager.isTransferring = false
                }
                .foregroundColor(.red)
                .padding()
            }
        }
    }
    
    // MARK: - ヘッダー
    
    private var headerView: some View {
        HStack {
            Text("Cinecam")
                .font(.system(size: 27, weight: .ultraLight, design: .default))
                .foregroundColor(.white)

            Spacer()

            // ライブラリボタン
            Button(action: { showLibrary = true }) {
                ZStack {
                    Image(systemName: "square.grid.2x2")
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.7))
                    // バッジ（セッション数）
                    if !library.records.isEmpty {
                        Text("\(library.records.count)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.black)
                            .frame(width: 16, height: 16)
                            .background(Color.white)
                            .clipShape(Circle())
                            .offset(x: 10, y: -10)
                    }
                }
            }
            .padding(.trailing, 8)

            // 設定アイコン（右上）
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
    }
    
    // MARK: - 接続状態表示
    
    private var connectionStatusView: some View {
        VStack(spacing: 10) {
            // 接続状態インジケーター
            HStack {
                Circle()
                    .fill(connectionStateColor)
                    .frame(width: 12, height: 12)
                
                Text(connectionStateText)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
            }
            
            // Connected device count
            if !sessionManager.connectedPeers.isEmpty {
                Text("Connected: \(sessionManager.connectedPeers.count + 1) devices")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                
                // Connected device list
                VStack(alignment: .leading, spacing: 5) {
                    // Self (configured user name or device name)
                    let myName = UserDefaults.standard.string(forKey: "cinecam.userName")
                        .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                        ?? UIDevice.current.name
                    deviceRow(name: myName, isSelf: true)
                    
                    // Connected devices
                    ForEach(sessionManager.connectedPeerNames, id: \.self) { peerName in
                        deviceRow(name: peerName, isSelf: false)
                    }
                }
                .padding()
                .background(Color.white.opacity(0.1))
                .cornerRadius(15)
            }
        }
    }
    
    private func deviceRow(name: String, isSelf: Bool) -> some View {
        HStack {
            Image(systemName: "iphone")
                .foregroundColor(.white.opacity(0.7))
            Text(name)
                .font(.subheadline)
                .foregroundColor(.white)
            if isSelf {
                Text("(You)")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }
    
    private var connectionStateColor: Color {
        switch sessionManager.connectionState {
        case .disconnected: return .gray
        case .connecting: return .orange
        case .connected: return .green
        }
    }
    
    private var connectionStateText: String {
        switch sessionManager.connectionState {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        }
    }
    
    // MARK: - ログ表示（5行、モノクロアイコン、最新が下）
    
    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(sessionManager.logs.enumerated()), id: \.offset) { index, log in
                        HStack(spacing: 6) {
                            // モノクロアイコン
                            Image(systemName: getLogIcon(log))
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.5))
                            
                            Text(log)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(0.8))
                        }
                        .id(index)
                    }
                }
            }
            .frame(height: 60)
            .padding(8)
            .background(Color.white.opacity(0.05))
            .cornerRadius(10)
            .onChange(of: sessionManager.logs.count) { _ in
                // 最新ログまでスクロール
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
        if log.contains("✅") || log.contains("Connected") || log.contains("Accepted") { return "checkmark.circle" }
        if log.contains("❌") || log.contains("Stopped") || log.contains("Rejected") { return "xmark.circle" }
        if log.contains("🔍") || log.contains("Found") { return "magnifyingglass.circle" }
        if log.contains("📤") || log.contains("Inviting") || log.contains("sent") { return "arrow.up.circle" }
        if log.contains("📥") || log.contains("📨") || log.contains("Received") { return "arrow.down.circle" }
        if log.contains("🔄") || log.contains("Connecting") { return "arrow.clockwise.circle" }
        if log.contains("👑") || log.contains("Master") { return "crown" }
        if log.contains("🎥") || log.contains("🎬") || log.contains("Recording") { return "video.circle" }
        if log.contains("⏹️") || log.contains("Stop") { return "stop.circle" }
        if log.contains("🛑") { return "xmark.octagon" }
        if log.contains("📱") || log.contains("Slave") { return "iphone.circle" }
        return "circle"
    }
    
    // MARK: - ログ表示（削除 - 使わない）
    
    // MARK: - メインコンテンツ
    
    private var mainContent: some View {
        Group {
            if !sessionManager.isConnecting {
                // 状態1: 接続開始前
                connectButton
            } else if sessionManager.connectedPeers.isEmpty {
                // 状態2: 接続中（相手待ち）
                waitingView
            } else if sessionManager.masterPeerID == nil {
                // 状態3: 接続済み（役割未選択）
                roleSelectionView
            } else if sessionManager.isMaster {
                // 状態4: マスターモード
                masterControlView
            } else {
                // 状態5: スレーブモード
                slaveWaitingView
            }
        }
    }
    
    // MARK: - Connect Button
    
    private var connectButton: some View {
        VStack(spacing: 20) {
            Text("Connect with Other Devices")
                .font(.headline)
                .foregroundColor(.white.opacity(0.7))
            
            Button(action: {
                sessionManager.startConnecting()
            }) {
                VStack(spacing: 15) {
                    Image(systemName: "wave.3.right")
                        .font(.system(size: 50, weight: .ultraLight))
                    Text("Start Connection")
                        .font(.system(size: 24, weight: .ultraLight))
                }
                .frame(width: 200, height: 200)
                .foregroundColor(.white)
                .background(
                    RoundedRectangle(cornerRadius: 30)
                        .fill(Color.blue)
                )
            }
        }
    }
    
    // MARK: - Waiting for Connection
    
    private var waitingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)
            
            Text("Searching for other devices...")
                .font(.headline)
                .foregroundColor(.white.opacity(0.7))
            
            Button(action: {
                sessionManager.stopHosting()
            }) {
                Text("Cancel")
                    .foregroundColor(.red)
                    .padding()
            }
        }
    }
    
    // MARK: - Role Selection
    
    private var roleSelectionView: some View {
        VStack(spacing: 30) {
            Text("Select Role")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            HStack(spacing: 20) {
                // Master button
                Button(action: {
                    sessionManager.selectMasterRole()
                }) {
                    VStack(spacing: 15) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 40))
                        Text("Master")
                            .font(.headline)
                        Text("Control recording")
                            .font(.caption)
                            .opacity(0.7)
                    }
                    .frame(width: 150, height: 150)
                    .foregroundColor(.white)
                    .background(
                        RoundedRectangle(cornerRadius: 25)
                            .fill(Color.orange)
                    )
                }
                .disabled(sessionManager.masterPeerID != nil)
                .opacity(sessionManager.masterPeerID != nil ? 0.3 : 1.0)
                
                // Slave button
                Button(action: {
                    sessionManager.selectSlaveRole()
                }) {
                    VStack(spacing: 15) {
                        Image(systemName: "iphone")
                            .font(.system(size: 40))
                        Text("Slave")
                            .font(.headline)
                        Text("Follow master")
                            .font(.caption)
                            .opacity(0.7)
                    }
                    .frame(width: 150, height: 150)
                    .foregroundColor(.white)
                    .background(
                        RoundedRectangle(cornerRadius: 25)
                            .fill(Color.green)
                    )
                }
            }
            
            Button(action: {
                sessionManager.stopHosting()
            }) {
                Text("Disconnect")
                    .foregroundColor(.red)
                    .padding()
            }
        }
    }
    
    // MARK: - Master Control Screen
    
    private var masterControlView: some View {
        VStack(spacing: 4) {
            Text("👑 Master Mode")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.orange)
            
            // Recording status display
            if cameraManager.isRecording {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("🔴 Recording")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            } else if sessionManager.isWaitingForCameraReady {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("⏳ Waiting for all cameras...")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            } else {
                Text("⚪ Standby")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            
            Spacer()
            
            // Camera start button (shown only when camera not started)
            if !sessionManager.isCameraReady {
                Button(action: {
                    sessionManager.startCameraForAll()
                }) {
                    VStack(spacing: 12) {
                        Image(systemName: sessionManager.isWaitingForCameraReady ? "hourglass" : "camera.fill")
                            .font(.system(size: 50, weight: .ultraLight))
                        Text(sessionManager.isWaitingForCameraReady ? "Waiting..." : "Start Camera")
                            .font(.system(size: 24, weight: .ultraLight))
                    }
                    .frame(width: 200, height: 200)
                    .foregroundColor(.white)
                    .background(
                        RoundedRectangle(cornerRadius: 30)
                            .fill(sessionManager.isWaitingForCameraReady ? Color.orange : Color.blue)
                    )
                }
                .disabled(sessionManager.isWaitingForCameraReady)
            }
            
            Spacer()
            
            // Session ID display
            if !sessionManager.sessionID.isEmpty {
                Text("Session: \(sessionManager.sessionID)")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.top, 4)
            }
            
            Spacer()
            
            // Disconnect button (fixed width of 180)
            Button(action: {
                sessionManager.stopHosting()
            }) {
                Text("disconnect")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(width: 180)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.blue)
                    )
            }
        }
        .padding(.vertical, 10)
    }
    
    // 録画時間フォーマット
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    // MARK: - Slave Waiting Screen
    
    private var slaveWaitingView: some View {
        VStack(spacing: 4) {
            Text("📱 Slave Mode")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.green)
            
            // Recording status display
            if cameraManager.isRecording {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("🔴 Recording")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            } else {
                Text("⚪ Standby")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            
            Spacer()
            
            // Show waiting message when camera not started
            if !sessionManager.isCameraReady {
                VStack(spacing: 15) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 50))
                        .foregroundColor(.white.opacity(0.5))
                    
                    Text("Waiting for master to start camera...")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(width: 200, height: 200)
                .background(
                    RoundedRectangle(cornerRadius: 30)
                        .fill(Color.white.opacity(0.05))
                )
            }
            
            Spacer()
            
            // Session ID display
            if !sessionManager.sessionID.isEmpty {
                Text("Session: \(sessionManager.sessionID)")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.top, 4)
            }
            
            Spacer()
            
            // Disconnect button (fixed width of 180)
            Button(action: {
                sessionManager.stopHosting()
            }) {
                Text("disconnect")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(width: 180)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.blue)
                    )
            }
        }
        .padding(.vertical, 10)
    }
}

#Preview {
    ContentView()
}
