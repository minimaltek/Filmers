//
//  CameraSessionManager.swift
//  Cinecam
//
//  Phase 1: MultipeerConnectivity 接続機能
//

import Foundation
import MultipeerConnectivity
import Combine

class CameraSessionManager: NSObject, ObservableObject {
    // MARK: - Properties
    
    private let serviceType = "cinecam-sync"
    private let myPeerID: MCPeerID
    
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var session: MCSession?
    
    @Published var connectedPeers: [MCPeerID] = []
    @Published var availablePeers: [MCPeerID] = []
    @Published var isMaster = false
    @Published var connectionState: ConnectionState = .disconnected
    @Published var sessionID: String = ""
    @Published var masterPeerID: MCPeerID? = nil  // マスター端末のID
    @Published var isConnecting = false  // 接続処理中フラグ
    
    // ログ表示用
    @Published var logs: [String] = []
    
    // 招待済みピアを記録
    private var invitedPeers: Set<MCPeerID> = []
    
    // カメラマネージャー（外部から注入）
    weak var cameraManager: CameraManager?
    
    // 録画済み動画ファイル管理
    private var recordedVideos: [String: [String: URL]] = [:]  // [SessionID: [DeviceName: VideoURL]]

    // 録画開始時に確定した参加台数を保持する（転送中の切断で台数が変わっても判定がぶれない）
    // [SessionID: expectedCount]
    private var sessionExpectedCounts: [String: Int] = [:]
    
    // プレビュー画面表示用
    @Published var showPreview = false
    @Published var previewSessionID: String = ""
    @Published var previewVideos: [String: URL] = [:]
    /// 全動画が揃いプレビューへ遷移確定〜showPreview = true になるまでのガードフラグ
    private var isTransitioningToPreview = false
    
    // 転送状態管理
    @Published var isTransferring = false
    @Published var transferProgress: [String: Double] = [:]  // [PeerID: Progress]
    @Published var totalExpectedFiles = 0
    @Published var receivedFiles = 0
    
    // カメラ起動状態
    @Published var isCameraReady = false                // カメラが起動済みかどうか

    // 同期録画開始用
    @Published var isWaitingForReady = false            // 準備待ち中フラグ（UI用）
    private var pendingSessionID: String = ""           // fire前に保持するセッションID
    private var pendingTimestamp: TimeInterval = 0      // fire前に保持するタイムスタンプ
    private var readyPeers: Set<MCPeerID> = []          // ready_ack を返してきたピア集合
    
    // カメラ起動同期用
    @Published var isWaitingForCameraReady = false      // カメラ起動待機中フラグ
    private var cameraReadyPeers: Set<MCPeerID> = []    // camera_ready を返してきたピア集合
    
    // デバイス名の配列（UI用）
    var connectedPeerNames: [String] {
        connectedPeers.map { $0.displayName }
    }
    
    // ログ追加
    private func addLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        DispatchQueue.main.async {
            self.logs.insert("[\(timestamp)] \(message)", at: 0)
            if self.logs.count > 20 {
                self.logs.removeLast()
            }
        }
        print(message)
    }
    
    enum ConnectionState {
        case disconnected
        case connecting
        case connected
    }
    
    // MARK: - Initialization
    
    override init() {
        // UserDefaults に保存されたユーザー名を使用。未設定ならデバイス名にフォールバック。
        let savedName = UserDefaults.standard.string(forKey: "cinecam.userName")?.trimmingCharacters(in: .whitespaces)
        let displayName = (savedName?.isEmpty == false) ? savedName! : UIDevice.current.name
        self.myPeerID = MCPeerID(displayName: displayName)
        super.init()
        
        // セッション作成（暗号化必須）
        session = MCSession(peer: myPeerID,
                           securityIdentity: nil,
                           encryptionPreference: .required)
        session?.delegate = self
    }
    
    // MARK: - Public Methods
    
    /// 接続開始（マスター/スレーブ未決定）
    func startConnecting() {
        isConnecting = true
        
        // アドバタイズとブラウズ両方開始
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID,
                                               discoveryInfo: nil,
                                               serviceType: serviceType)
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()
        
        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()
        
        connectionState = .connecting
        addLog("🔍 Connecting: \(myPeerID.displayName)")
    }
    
    /// マスター役を選択
    func selectMasterRole() {
        isMaster = true
        masterPeerID = myPeerID
        addLog("👑 Selected as Master")

        // role_selected を全ピアに送信。
        // カメラ起動はここでは行わず、RECボタンを押したとき（startRecordingAll）の
        // startSession() に完全に委ねる。
        // 役割選択直後に AVCaptureSession を起動すると MCSession チャンネルの
        // 確立・維持と競合して切断が起きるため。
        for peer in connectedPeers {
            sendRoleSelectedCommand(to: peer)
        }

        addLog("📷 Camera startup deferred to REC button press")
    }

    /// スレーブ役を選択
    func selectSlaveRole() {
        isMaster = false
        addLog("📱 Selected as Slave")

        // カメラはここでは起動しない。
        // recording_ready を受信したときに初めて起動することで、
        // MCSession の接続維持と AVCaptureSession 起動の競合を防ぐ。
        addLog("📱 Camera startup deferred to recording_ready")

        for peer in connectedPeers {
            sendRoleSelectedCommand(to: peer)
        }
    }

    /// role_selected コマンドを特定ピアに送信
    private func sendRoleSelectedCommand(to peer: MCPeerID) {
        var command: [String: Any] = ["action": "role_selected"]
        if isMaster {
            command["role"] = "master"
            command["peerID"] = myPeerID.displayName
        } else {
            command["role"] = "slave"
        }
        sendCommandTo(peer, command: command)
    }

    /// 接続直後に役割が確定していれば再送する（チャンネル確立を待つため少し遅延）
    private func scheduleRoleResend(to peer: MCPeerID) {
        guard masterPeerID != nil else { return }  // 役割未確定なら不要
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.connectedPeers.contains(peer) else { return }
            self.sendRoleSelectedCommand(to: peer)
            self.addLog("🔁 Role re-sent to \(peer.displayName) after connect")
        }
    }
    
    /// Stopped
    func stopHosting() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        
        connectedPeers.removeAll()
        availablePeers.removeAll()
        invitedPeers.removeAll()
        connectionState = .disconnected
        isConnecting = false
        isMaster = false
        masterPeerID = nil

        // 同期録画状態リセット
        isWaitingForReady = false
        readyPeers = []
        pendingSessionID = ""
        pendingTimestamp = 0
        
        // セッションを再作成（クリーンな状態にする）
        session = MCSession(peer: myPeerID,
                           securityIdentity: nil,
                           encryptionPreference: .required)
        session?.delegate = self
        
        addLog("🛑 Stopped")
    }

    /// プレビューを閉じた後に MCSession をクリーンアップして再接続可能な状態に戻す
    func cleanupSessionAfterPreview() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()

        connectedPeers.removeAll()
        availablePeers.removeAll()
        invitedPeers.removeAll()
        connectionState = .disconnected
        isConnecting = false
        isMaster = false
        masterPeerID = nil
        isWaitingForReady = false
        readyPeers = []
        pendingSessionID = ""
        pendingTimestamp = 0
        isTransitioningToPreview = false
        
        // カメラ関連のフラグもリセット
        isCameraReady = false
        OrientationLock.isCameraActive = false

        // Documents/ のファイルはライブラリ用に保持する（削除しない）
        // メモリ上の recordedVideos・sessionExpectedCounts だけクリアする
        recordedVideos.removeAll()
        sessionExpectedCounts.removeAll()

        // セッションを再作成（クリーンな状態にする）
        session = MCSession(peer: myPeerID,
                           securityIdentity: nil,
                           encryptionPreference: .required)
        session?.delegate = self

        print("📹 [SessionManager] Session cleaned up after preview")
    }

    /// Documents/ 内の .mov ファイルをすべて削除する
    private func deleteAllDocumentMovFiles() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: docs, includingPropertiesForKeys: nil
        ) else { return }

        var deletedCount = 0
        for file in files where file.pathExtension.lowercased() == "mov" {
            do {
                try FileManager.default.removeItem(at: file)
                deletedCount += 1
                print("🗑️ [Cleanup] Deleted: \(file.lastPathComponent)")
            } catch {
                print("❌ [Cleanup] Failed to delete \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        recordedVideos.removeAll()
        print("🗑️ [Cleanup] Deleted \(deletedCount) file(s) from Documents/")
    }
    
    /// 特定のピアに接続招待を送る
    func invitePeer(_ peer: MCPeerID) {
        guard let browser = browser,
              let session = session else { return }
        
        // 既にConnectingまたは接続済みの場合はSkip
        if connectedPeers.contains(peer) {
            addLog("⏭️ Skip: \(peer.displayName) already connected")
            return
        }
        
        browser.invitePeer(peer,
                          to: session,
                          withContext: nil,
                          timeout: 30)
        
        addLog("📤 Inviting: \(peer.displayName)")
    }
    
    // MARK: - Recording Commands
    
    /// カメラ起動コマンドを送信（マスターのみ）
    func startCameraForAll() {
        guard isMaster else {
            addLog("⚠️ Only master can start camera")
            return
        }
        
        addLog("📷 Starting camera for all devices...")
        
        // カメラ起動待機モードに入る
        isWaitingForCameraReady = true
        cameraReadyPeers = []
        
        // カメラ起動時に画面回転を縦固定にする
        OrientationLock.isCameraActive = true
        
        // 画面の向きを強制的に更新
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        }
        
        // 先に自分のカメラを起動（完了後にコマンド送信）
        cameraManager?.setupCamera()
        
        // MCSessionチャンネルが確実に確立するまで待ってからコマンドを送信
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            print("📷 [SessionManager] Sending start_camera commands to \(self.connectedPeers.count) peer(s)")
            
            // スレーブが1台もいない場合は即座にカメラ準備完了
            if self.connectedPeers.isEmpty {
                self.isWaitingForCameraReady = false
                self.isCameraReady = true
                self.addLog("📷 Camera ready (solo mode)")
                return
            }
            
            // 全スレーブにカメラ起動コマンドを送信
            for peer in self.connectedPeers {
                self.sendCameraStartCommand(to: peer)
            }
            
            self.addLog("⏳ Waiting for camera_ready from \(self.connectedPeers.count) peer(s)...")
            
            // タイムアウト: 15秒以内に全員から camera_ready が来なければキャンセル
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
                guard let self, self.isWaitingForCameraReady else { return }
                self.isWaitingForCameraReady = false
                self.cameraReadyPeers = []
                self.addLog("⚠️ Camera ready timeout – some peers did not respond")
                // タイムアウトしても続行（応答したピアとだけ録画）
                self.isCameraReady = true
            }
        }
    }
    
    /// カメラを停止してメニューに戻る
    func stopCameraAndReturnToMenu() {
        addLog("📷 Stopping camera and returning to menu...")
        
        // カメラ停止時に画面回転の制限を解除
        OrientationLock.isCameraActive = false
        
        // カメラを停止
        cameraManager?.stopSession()
        isCameraReady = false
        
        // 全ピアにカメラ停止コマンドを送信
        if isMaster {
            let command: [String: Any] = ["action": "stop_camera"]
            sendCommandToAll(command)
        }
        
        addLog("✅ Camera stopped")
    }
    
    /// カメラ起動コマンドを送信
    private func sendCameraStartCommand(to peer: MCPeerID) {
        let command: [String: Any] = [
            "action": "start_camera"
        ]
        
        guard let data = try? JSONSerialization.data(withJSONObject: command) else {
            addLog("❌ Failed to serialize start_camera command")
            return
        }
        
        guard let session = session else { return }
        
        do {
            try session.send(data, toPeers: [peer], with: .reliable)
            addLog("📤 Sent start_camera to \(peer.displayName)")
        } catch {
            addLog("❌ Failed to send start_camera: \(error.localizedDescription)")
        }
    }
    
    /// 全員からcamera_readyを受信したかチェック
    private func checkAllCamerasReady() {
        guard isWaitingForCameraReady else { return }
        let expected = Set(connectedPeers)
        guard !expected.isEmpty, expected.isSubset(of: cameraReadyPeers) else { return }
        
        isWaitingForCameraReady = false
        isCameraReady = true
        addLog("✅ All cameras ready! Recording mode enabled.")
    }
    
    /// 全端末でRecording（マスターのみ）― フェーズ1: ready コマンドを送信
    func startRecordingAll() {
        guard isMaster else {
            addLog("⚠️ Only master can start recording")
            return
        }

        // 新しいセッションID生成
        let newSessionID = UUID().uuidString.prefix(8).uppercased().description
        pendingSessionID = newSessionID
        pendingTimestamp = Date().timeIntervalSince1970
        readyPeers = []

        // ★ ボタンを押した瞬間に isWaitingForReady を立てる
        // → UIが即座に「準備中...」スピナーに切り替わりユーザーに応答を伝える
        isWaitingForReady = true

        // スレーブが1台もいない場合はそのまま自分だけ開始
        if connectedPeers.isEmpty {
            isWaitingForReady = false
            sessionID = pendingSessionID
            sessionExpectedCounts[pendingSessionID] = 1  // 自分だけ
            handleStartRecording(timestamp: pendingTimestamp, sessionID: pendingSessionID)
            addLog("🎬 Solo recording started: SessionID=\(pendingSessionID)")
            return
        }

        addLog("⏳ Ensuring camera ready before sending recording_ready…")

        // マスター自身のカメラが起動済みであることを確認してから recording_ready を送信
        // （カメラ未起動のまま fire すると、マスター側だけ録画開始が遅れてズレる）
        cameraManager?.startSession { [weak self] in
            guard let self else { return }
            // カメラ起動完了時点で、まだ同じセッションの待機中か確認
            // （起動に時間がかかってユーザーがキャンセルした場合に誤送信しない）
            guard self.isWaitingForReady,
                  self.pendingSessionID == newSessionID else {
                self.addLog("⚠️ Camera ready but session already cancelled – skip")
                return
            }
            // カメラ起動完了 → recording_ready を全スレーブに送信
            let command: [String: Any] = [
                "action": "recording_ready",
                "sessionID": newSessionID
            ]
            self.sendCommandToAll(command)
            self.addLog("⏳ Waiting for ready from \(self.connectedPeers.count) peer(s)…")

            // タイムアウト: 10秒以内に全員から ready_ack が来なければキャンセル
            let waitingSessionID = newSessionID
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                guard let self, self.isWaitingForReady,
                      self.pendingSessionID == waitingSessionID else { return }
                self.isWaitingForReady = false
                self.readyPeers = []
                self.pendingSessionID = ""
                self.pendingTimestamp = 0
                self.addLog("⚠️ Ready timeout – recording cancelled")
            }
        }
    }

    /// 全員 ready_ack を返したら fire（フェーズ2）
    private func fireRecordingIfAllReady() {
        guard isWaitingForReady else { return }
        // 接続中の全ピアが ready_ack を返したか確認
        let expected = Set(connectedPeers)
        guard !expected.isEmpty, expected.isSubset(of: readyPeers) else { return }

        isWaitingForReady = false

        // ★ 録画開始の瞬間の台数を確定して記録する。
        // 転送フェーズ中に誰かが切断しても expectedCount が変わらないようにするため。
        let participantCount = connectedPeers.count + 1  // スレーブ全員 + マスター自身
        sessionExpectedCounts[pendingSessionID] = participantCount
        addLog("📊 Session \(pendingSessionID): \(participantCount)台で録画開始")

        let command: [String: Any] = [
            "action": "recording_fire",
            "timestamp": pendingTimestamp,
            "sessionID": pendingSessionID
        ]
        sendCommandToAll(command)
        addLog("🔥 Fire! Starting sync recording: SessionID=\(pendingSessionID)")

        // マスター自身も録画開始
        handleStartRecording(timestamp: pendingTimestamp, sessionID: pendingSessionID)
    }
    
    /// 全端末でStopped（マスターのみ）
    func stopRecordingAll() {
        guard isMaster else {
            addLog("⚠️ Only master can stop recording")
            return
        }
        
        print("📹 [SessionManager] stopRecordingAll called")
        print("📹 [SessionManager] Current SessionID: '\(sessionID)'")
        
        let command: [String: Any] = [
            "action": "stop_recording",
            "timestamp": Date().timeIntervalSince1970,
            "sessionID": sessionID  // SessionIDを含める
        ]
        
        sendCommandToAll(command)
        addLog("🛑 Recording stopped")
        
        // 自分もStopped
        handleStopRecording()
        
        // SessionIDはクリアしない（録画完了コールバックで使用するため）
        print("📹 [SessionManager] SessionID will be cleared after video transfer")
    }
    
    // MARK: - Private Methods
    
    /// 全ピアにコマンド送信
    private func sendCommandToAll(_ command: [String: Any]) {
        guard let session = session else {
            addLog("⚠️ No session")
            return
        }
        guard !connectedPeers.isEmpty else {
            addLog("⚠️ No peers connected – command '\(command["action"] ?? "")' not sent")
            return
        }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: command)
            // 全ピアへ一括送信を試みる
            do {
                try session.send(jsonData, toPeers: connectedPeers, with: .reliable)
                addLog("✅ Command sent: \(command["action"] ?? "")")
            } catch {
                // 一括送信失敗時は個別にリトライ（一部ピアが切断状態でも他には届けるため）
                addLog("⚠️ Bulk send failed (\(error.localizedDescription)) – retrying individually")
                for peer in connectedPeers {
                    do {
                        try session.send(jsonData, toPeers: [peer], with: .reliable)
                        addLog("✅ Command sent to \(peer.displayName): \(command["action"] ?? "")")
                    } catch {
                        addLog("❌ Send to \(peer.displayName) failed: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            addLog("❌ Serialize failed: \(error.localizedDescription)")
        }
    }

    /// 特定ピアにコマンド送信
    private func sendCommandTo(_ peer: MCPeerID, command: [String: Any]) {
        guard let session = session else { return }
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: command)
            try session.send(jsonData, toPeers: [peer], with: .reliable)
        } catch {
            addLog("❌ Send to \(peer.displayName) failed: \(error.localizedDescription)")
        }
    }
    
    /// 受信したコマンドを処理
    private func handleReceivedCommand(_ data: Data, from peer: MCPeerID) {
        // すべての処理をメインスレッドで行う
        // （pendingSessionID 等の状態変数へのアクセスをスレッドセーフにするため）
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
        do {
            guard let command = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let action = command["action"] as? String else {
                return
            }
            
            self.addLog("📥 Received from \(peer.displayName): \(action)")
            
            switch action {
            case "start_recording":
                if let timestamp = command["timestamp"] as? TimeInterval,
                   let sessionID = command["sessionID"] as? String {
                    self.handleStartRecording(timestamp: timestamp, sessionID: sessionID)
                }

            case "recording_ready":
                // スレーブ: カメラセッションが起動済みであることを確認してから ready_ack を返す
                if let sid = command["sessionID"] as? String {
                    self.addLog("📡 recording_ready received – ensuring camera ready")
                    self.cameraManager?.startSession {
                        // startSession は既に起動済みなら即コールバックされる
                        self.addLog("📷 Camera confirmed ready – sending ready_ack")
                        let ack: [String: Any] = [
                            "action": "ready_ack",
                            "sessionID": sid,
                            "peerName": self.myPeerID.displayName
                        ]
                        self.sendCommandTo(peer, command: ack)
                    }
                }

            case "ready_ack":
                // マスター: スレーブからの準備完了通知を受け取る
                if let sid = command["sessionID"] as? String, sid == self.pendingSessionID {
                    self.readyPeers.insert(peer)
                    self.addLog("✅ Ready from \(peer.displayName) (\(self.readyPeers.count)/\(self.connectedPeers.count))")
                    self.fireRecordingIfAllReady()
                }

            case "recording_fire":
                // スレーブ: 録画を一斉開始
                if let timestamp = command["timestamp"] as? TimeInterval,
                   let sessionID = command["sessionID"] as? String {
                    self.addLog("🔥 Fire received – starting recording")
                    self.handleStartRecording(timestamp: timestamp, sessionID: sessionID)
                }

            case "stop_recording":
                // スレーブ: マスターからの停止コマンドを受信
                // sessionID が一致する場合のみ処理（古いセッションの誤受信を防ぐ）
                let incomingSessionID = command["sessionID"] as? String ?? ""
                if incomingSessionID.isEmpty || incomingSessionID == self.sessionID {
                    self.addLog("📥 Stop received from \(peer.displayName)")
                    self.handleStopRecording()
                } else {
                    self.addLog("⚠️ stop_recording sessionID mismatch: got \(incomingSessionID), current \(self.sessionID)")
                }
                
            case "role_selected":
                if let role = command["role"] as? String {
                    self.handleRoleSelection(role: role, peerID: peer)
                }
                
            case "start_camera":
                // スレーブ: マスターからのカメラ起動コマンドを受信
                self.addLog("📥 start_camera received from \(peer.displayName)")
                // Add delay before starting camera to ensure MCSession channel stability
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self else { return }
                    self.handleStartCamera(fromPeer: peer)
                }
                
            case "camera_ready":
                // マスター: スレーブからのカメラ準備完了通知を受け取る
                if let peerName = command["peerName"] as? String {
                    self.cameraReadyPeers.insert(peer)
                    self.addLog("✅ Camera ready from \(peerName) (\(self.cameraReadyPeers.count)/\(self.connectedPeers.count))")
                    self.checkAllCamerasReady()
                }
            
            case "stop_camera":
                // スレーブ: マスターからのカメラ停止コマンドを受信
                self.addLog("📥 stop_camera received from \(peer.displayName)")
                OrientationLock.isCameraActive = false  // 画面回転制限を解除
                self.cameraManager?.stopSession()
                self.isCameraReady = false
                
            default:
                self.addLog("⚠️ Unknown command: \(action)")
            }
            
        } catch {
            self.addLog("❌ Parse error: \(error.localizedDescription)")
        }
        }
    }
    
    /// 役割選択処理
    private func handleRoleSelection(role: String, peerID: MCPeerID) {
        guard role == "master" else { return }
        guard masterPeerID != peerID else { return }
        masterPeerID = peerID
        addLog("👑 \(peerID.displayName) is master")

        // ⚠️ ここではカメラを起動しない。
        // AVCaptureSession の startRunning() は内部で大量の XPC 通信を発生させるため、
        // MCSession のチャンネル確立・維持と競合して切断を引き起こす。
        // カメラ起動は start_camera コマンドを受信したタイミングまで遅らせる。
        addLog("📱 Slave role confirmed – camera startup deferred to start_camera")
    }
    
    /// カメラ起動処理（スレーブ用）
    private func handleStartCamera(fromPeer peer: MCPeerID) {
        addLog("📷 Starting camera for slave...")
        
        // カメラ起動時に画面回転を縦固定にする
        OrientationLock.isCameraActive = true
        
        // 画面の向きを強制的に更新
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        }
        
        // カメラをセットアップして、完了後にcamera_readyを送信
        cameraManager?.setupCamera()
        
        // カメラが完全に起動するまで少し待つ
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.isCameraReady = true
            
            // マスターにcamera_ready通知を送信
            let command: [String: Any] = [
                "action": "camera_ready",
                "peerName": self.myPeerID.displayName
            ]
            self.sendCommandTo(peer, command: command)
            self.addLog("📤 Sent camera_ready to \(peer.displayName)")
        }
    }
    
    /// Recording処理
    private func handleStartRecording(timestamp: TimeInterval, sessionID: String) {
        DispatchQueue.main.async {
            // 録画が実際に始まるタイミングで sessionID をセット
            // （fireRecordingIfAllReady では早すぎるためここで行う）
            self.sessionID = sessionID
        }
        
        // カメラで実際の録画を開始
        cameraManager?.startRecording(timestamp: timestamp, sessionID: sessionID)
        
        addLog("🎥 Recording: SessionID=\(sessionID)")
    }
    
    /// Stopped処理
    private func handleStopRecording() {
        print("📹 [SessionManager] handleStopRecording called")
        print("📹 [SessionManager] Current SessionID: '\(sessionID)'")
        
        // カメラの録画を停止
        cameraManager?.stopRecording()
        
        addLog("⏹️ Stopped")
        
        // SessionIDはクリアしない（録画完了コールバックで使用するため）
        print("📹 [SessionManager] Waiting for recording completion callback...")
    }
    
    // MARK: - Video Transfer
    
    /// Recording completion handler (public method)
    public func handleRecordingCompleted(videoURL: URL, sessionID: String) {
        print("📹 [SessionManager] ========== HANDLE RECORDING COMPLETED ==========")
        print("📹 [SessionManager] Called from: \(Thread.isMainThread ? "Main" : "Background") thread")
        print("📹 [SessionManager] SessionID: '\(sessionID)'")
        print("📹 [SessionManager] Device: \(myPeerID.displayName)")
        print("📹 [SessionManager] File path: \(videoURL.path)")
        print("📹 [SessionManager] File exists: \(FileManager.default.fileExists(atPath: videoURL.path))")
        print("📹 [SessionManager] Connected peers: \(connectedPeers.count)")

        // ✅ Stop camera when recording ends (transfer continues in background)
        cameraManager?.stopSession()
        addLog("🛑 Camera stopped – recording completed, starting transfer")
        
        if let fileSize = try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? UInt64 {
            print("📹 [SessionManager] File size: \(fileSize) bytes")
        }
        
        for peer in connectedPeers {
            print("📹 [SessionManager]   - Peer: \(peer.displayName)")
        }
        
        addLog("📹 Recording completed: \(videoURL.lastPathComponent)")
        
        // Copy own video to Documents (persist)
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileName = "\(sessionID)_\(myPeerID.displayName).mov"
        let destinationURL = documentsPath.appendingPathComponent(fileName)
        
        print("📹 [SessionManager] Copying to: \(destinationURL.path)")
        
        do {
            // Remove existing file if exists
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
                print("📹 [SessionManager] Removed existing file")
            }
            
            // Copy file
            try FileManager.default.copyItem(at: videoURL, to: destinationURL)
            print("✅ [SessionManager] Copied successfully")
            
            // Record own video (save destination URL)
            let myDeviceName = myPeerID.displayName
            if recordedVideos[sessionID] == nil {
                recordedVideos[sessionID] = [:]
                print("📹 [SessionManager] Created new session entry")
            }
            recordedVideos[sessionID]?[myDeviceName] = destinationURL
            
            print("📹 [SessionManager] Stored own video for \(myDeviceName)")
            print("📹 [SessionManager] Current video count for session: \(recordedVideos[sessionID]?.count ?? 0)")
            
            // Send video to other devices (from original URL)
            print("📹 [SessionManager] Starting video transfer to peers...")
            sendVideoToAllPeers(videoURL: videoURL, sessionID: sessionID)
            
            // Check if all videos received
            checkAllVideosReceived(sessionID: sessionID)
            
        } catch {
            let errorMsg = "❌ Copy error: \(error.localizedDescription)"
            addLog(errorMsg)
            print("❌ [SessionManager] \(errorMsg)")
            print("❌ [SessionManager] Error details: \(error)")
        }
        
        print("📹 [SessionManager] =======================================================")
    }
    
    /// Send video file to all peers
    private func sendVideoToAllPeers(videoURL: URL, sessionID: String) {
        guard let session = session else {
            print("❌ [VideoTransfer] Session is nil")
            return
        }
        
        let fileName = "\(sessionID)_\(myPeerID.displayName).mov"
        
        print("📹 [VideoTransfer] ========== SENDING VIDEO ==========")
        print("📹 [VideoTransfer] Source: \(videoURL.path)")
        print("📹 [VideoTransfer] File exists: \(FileManager.default.fileExists(atPath: videoURL.path))")
        print("📹 [VideoTransfer] File name: \(fileName)")
        print("📹 [VideoTransfer] Peers count: \(connectedPeers.count)")
        
        if let fileSize = try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? UInt64 {
            print("📹 [VideoTransfer] File size: \(fileSize) bytes (\(Double(fileSize) / 1_000_000.0) MB)")
        }
        
        DispatchQueue.main.async {
            self.isTransferring = true
            // Use count determined at recording start (prevents value fluctuation due to disconnection during transfer)
            let expectedCount = self.sessionExpectedCounts[sessionID] ?? (self.connectedPeers.count + 1)
            self.totalExpectedFiles = expectedCount
            self.receivedFiles = 1  // Own file
            print("📹 [VideoTransfer] Transfer state updated: \(self.receivedFiles)/\(self.totalExpectedFiles)")
        }
        
        for (index, peer) in connectedPeers.enumerated() {
            print("📹 [VideoTransfer] [\(index+1)/\(connectedPeers.count)] Sending to: \(peer.displayName)")
            
            // Use sendResource to transfer large files
            session.sendResource(at: videoURL,
                                withName: fileName,
                                toPeer: peer) { error in
                if let error = error {
                    let errorMsg = "❌ Send failed to \(peer.displayName): \(error.localizedDescription)"
                    self.addLog(errorMsg)
                    print("❌ [VideoTransfer] \(errorMsg)")
                } else {
                    let successMsg = "✅ Sent to \(peer.displayName)"
                    self.addLog(successMsg)
                    print("✅ [VideoTransfer] \(successMsg)")
                }
            }
        }
        
        print("📹 [VideoTransfer] ==========================================")
    }
    
    /// Check if all videos received
    private func checkAllVideosReceived(sessionID: String) {
        // All read/write to recordedVideos on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let videos = self.recordedVideos[sessionID] else { return }

            // Use count determined at recording start.
            // Using connectedPeers.count would cause misjudgment if someone disconnects during transfer.
            // Fall back to current connection count if no record in sessionExpectedCounts.
            let expectedCount = self.sessionExpectedCounts[sessionID] ?? (self.connectedPeers.count + 1)

            print("📹 [VideoCheck] Session: \(sessionID)")
            print("📹 [VideoCheck] Expected: \(expectedCount), Got: \(videos.count)")
            print("📹 [VideoCheck] Videos: \(videos.keys.joined(separator: ", "))")

            for (device, url) in videos {
                let exists = FileManager.default.fileExists(atPath: url.path)
                print("📹 [VideoCheck] \(device): \(exists ? "✅" : "❌") \(url.path)")
            }

            if videos.count == expectedCount {
                self.addLog("✅ All videos received for session: \(sessionID)")

                // Transfer complete flag
                self.isTransferring = false

                // Clear session expected count (release memory)
                self.sessionExpectedCounts.removeValue(forKey: sessionID)

                // ★ Set transition confirmed flag first
                self.isTransitioningToPreview = true

                // Set preview data
                self.previewSessionID = sessionID
                self.previewVideos = videos
                print("📹 [VideoCheck] Showing preview with \(videos.count) videos")

                // Stop advertiser/browser only to prevent new connections
                self.advertiser?.stopAdvertisingPeer()
                self.browser?.stopBrowsingForPeers()

                // Transition to preview
                self.showPreview = true
                self.isTransitioningToPreview = false
            }
        }
    }
}

// MARK: - MCSessionDelegate

extension CameraSessionManager: MCSessionDelegate {
    /// Peer connection state change
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                if !self.connectedPeers.contains(peerID) {
                    self.connectedPeers.append(peerID)
                }
                self.connectionState = .connected
                self.addLog("✅ Connected: \(peerID.displayName)")
                // MCSession may not complete internal channel establishment immediately after .connected
                // Wait a bit before resending to prevent "Not in connected state"
                self.scheduleRoleResend(to: peerID)
                
            case .connecting:
                self.connectionState = .connecting
                self.addLog("🔄 Connecting: \(peerID.displayName)")
                
            case .notConnected:
                self.connectedPeers.removeAll { $0 == peerID }
                self.addLog("❌ Disconnected: \(peerID.displayName)")

                // Don't reset during recording/transfer/waiting/preview transition/preview display
                // (MultipeerConnectivity may briefly fire notConnected during recording or right after transfer completion)
                let isActive = (self.cameraManager?.isRecording == true)
                    || self.isTransferring
                    || self.isWaitingForReady
                    || self.isTransitioningToPreview  // Between all videos received ~ showPreview=true
                    || self.showPreview               // During preview display

                if self.connectedPeers.isEmpty && !isActive {
                    self.connectionState = .disconnected
                    self.isConnecting = false
                    self.masterPeerID = nil
                    self.isMaster = false
                    self.sessionID = ""
                    
                    // カメラ起動状態をリセット
                    self.isWaitingForCameraReady = false
                    self.isCameraReady = false
                    self.cameraReadyPeers.removeAll()
                    
                    // Reset to avoid duplicate invitations on reconnect
                    self.invitedPeers.removeAll()
                    self.addLog("🔄 Session reset")

                    // Stop advertiser/browser once to return to clean state.
                    // If not stopped, old invitation remnants remain and double invitations easily occur on next connection.
                    // Also recreate MCSession to clear channel residual state.
                    self.advertiser?.stopAdvertisingPeer()
                    self.browser?.stopBrowsingForPeers()
                    self.session?.disconnect()
                    self.session = MCSession(peer: self.myPeerID,
                                            securityIdentity: nil,
                                            encryptionPreference: .required)
                    self.session?.delegate = self
                }
                
            @unknown default:
                break
            }
        }
    }
    
    /// Data received
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        handleReceivedCommand(data, from: peerID)
    }
    
    /// Stream received (not used)
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        // Not used
    }
    
    /// Resource receive started
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        addLog("📥 Receiving: \(resourceName) from \(peerID.displayName)")
    }
    
    /// Resource receive completed
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        print("📹 [VideoReceive] ========== RECEIVED RESOURCE ==========")
        print("📹 [VideoReceive] From: \(peerID.displayName)")
        print("📹 [VideoReceive] Resource name: \(resourceName)")
        print("📹 [VideoReceive] Local URL: \(localURL?.path ?? "nil")")
        
        if let error = error {
            let errorMsg = "❌ Receive error: \(error.localizedDescription)"
            addLog(errorMsg)
            print("❌ [VideoReceive] \(errorMsg)")
            return
        }
        
        guard let localURL = localURL else {
            addLog("❌ No URL received")
            print("❌ [VideoReceive] localURL is nil")
            return
        }
        
        print("📹 [VideoReceive] File exists at localURL: \(FileManager.default.fileExists(atPath: localURL.path))")
        
        if let fileSize = try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? UInt64 {
            print("📹 [VideoReceive] File size: \(fileSize) bytes (\(Double(fileSize) / 1_000_000.0) MB)")
        }
        
        // Extract SessionID and device name from filename
        // Filename format: SessionID_DeviceName.mov
        let fileName = resourceName.replacingOccurrences(of: ".mov", with: "")
        let components = fileName.split(separator: "_")
        
        guard components.count >= 2 else {
            addLog("❌ Invalid filename format: \(resourceName)")
            print("❌ [VideoReceive] Invalid filename format")
            return
        }
        
        let sessionID = String(components[0])
        let deviceName = components.dropFirst().joined(separator: "_")
        
        print("📹 [VideoReceive] Extracted SessionID: '\(sessionID)'")
        print("📹 [VideoReceive] Extracted DeviceName: '\(deviceName)'")
        
        // Copy to persistent location
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destinationURL = documentsPath.appendingPathComponent(resourceName)
        
        print("📹 [VideoReceive] Copying to: \(destinationURL.path)")
        
        do {
            // Remove existing file if exists
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
                print("📹 [VideoReceive] Removed existing file")
            }
            
            // Copy file
            try FileManager.default.copyItem(at: localURL, to: destinationURL)
            
            addLog("✅ Received: \(resourceName)")
            print("✅ [VideoReceive] File copied successfully")
            
            // Record received video, update count, check if all received - all on main thread
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                // ★ Failsafe: If still recording when master video arrives, force stop
                // (Countermeasure for when stop_recording command wasn't received due to network instability)
                if self.cameraManager?.isRecording == true && !self.isMaster {
                    print("⚠️ [VideoReceive] Received master video but still recording – force stopping")
                    self.addLog("⚠️ Force stop: stop_recording was not received in time")
                    self.handleStopRecording()
                }

                if self.recordedVideos[sessionID] == nil {
                    self.recordedVideos[sessionID] = [:]
                    print("📹 [VideoReceive] Created new session entry for: \(sessionID)")
                }
                self.recordedVideos[sessionID]?[deviceName] = destinationURL

                print("📹 [VideoReceive] Stored video for device: \(deviceName)")
                print("📹 [VideoReceive] Current video count: \(self.recordedVideos[sessionID]?.count ?? 0)")

                self.receivedFiles += 1
                print("📹 [VideoReceive] Updated received count: \(self.receivedFiles)/\(self.totalExpectedFiles)")

                // Check if all videos received (already on main thread so call directly)
                self.checkAllVideosReceived(sessionID: sessionID)
            }
            
        } catch {
            let errorMsg = "❌ Save error: \(error.localizedDescription)"
            addLog(errorMsg)
            print("❌ [VideoReceive] \(errorMsg)")
        }
        
        print("📹 [VideoReceive] ==========================================")
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension CameraSessionManager: MCNearbyServiceAdvertiserDelegate {
    /// When invitation received
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        
        addLog("📨 Invitation from \(peerID.displayName)")
        
        // Reject if already connected
        if connectedPeers.contains(peerID) {
            addLog("⏭️ Rejected: \(peerID.displayName) already connected")
            invitationHandler(false, nil)
            return
        }

        // Prevent collision where both devices discover and invite each other simultaneously.
        // If we already invited the peer, the one with the "smaller" display name in dictionary order
        // accepts the received invitation, while the "larger" one rejects it and keeps their own invitation.
        // This ensures only one invitation succeeds.
        if invitedPeers.contains(peerID) {
            if myPeerID.displayName < peerID.displayName {
                // Our name is smaller in dictionary order → accept their invitation, discard ours
                invitedPeers.remove(peerID)
                addLog("📨 Bi-directional: accepting \(peerID.displayName)'s invitation")
            } else {
                // Our name is larger → reject their invitation and prioritize ours
                addLog("⏭️ Bi-directional: rejecting \(peerID.displayName)'s invitation")
                invitationHandler(false, nil)
                return
            }
        }
        
        // Accept
        invitationHandler(true, session)
        addLog("✅ Accepted: \(peerID.displayName)")
    }
    
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        addLog("❌ Advertise failed: \(error.localizedDescription)")
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension CameraSessionManager: MCNearbyServiceBrowserDelegate {
    /// When peer discovered
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        DispatchQueue.main.async {
            if !self.availablePeers.contains(peerID) && peerID != self.myPeerID {
                self.availablePeers.append(peerID)
                self.addLog("🔍 Found: \(peerID.displayName)")
                
                // Invite only if not already invited
                if !self.invitedPeers.contains(peerID) && !self.connectedPeers.contains(peerID) {
                    self.invitedPeers.insert(peerID)
                    self.invitePeer(peerID)
                }
            }
        }
    }
    
    /// When peer lost
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.availablePeers.removeAll { $0 == peerID }
            self.addLog("🔍 Peer lost: \(peerID.displayName)")
        }
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        addLog("❌ Browse failed: \(error.localizedDescription)")
    }
}
