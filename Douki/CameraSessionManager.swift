//
//  CameraSessionManager.swift
//  Douki
//
//  Phase 1: MultipeerConnectivity 接続機能
//

import Foundation
import MultipeerConnectivity
import Combine

class CameraSessionManager: NSObject, ObservableObject {
    // MARK: - Properties
    
    private let serviceType = "douki-sync"
    private var myPeerID: MCPeerID
    private let myDisplayName: String
    
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var session: MCSession?
    
    @Published var connectedPeers: [MCPeerID] = []
    @Published var availablePeers: [MCPeerID] = []
    @Published var isMaster = false
    @Published var connectionState: ConnectionState = .disconnected
    @Published var sessionID: String = ""
    @Published var masterPeerID: MCPeerID? = nil  // マスター端末のID
    
    /// 永続的な役割フラグ。true の間は、明示的な DISCONNECT 以外で isMaster / masterPeerID をリセットしない
    @Published var persistentRole: Bool = false
    /// マスターの displayName を記憶する（再接続時の照合用）
    var persistentMasterName: String? = nil
    @Published var isConnecting = false  // 接続処理中フラグ
    
    // ログ表示用
    @Published var logs: [String] = []
    
    // 招待済みピアを記録（displayName で管理。MCPeerID は同一デバイスでもインスタンスが異なるため参照比較が効かない）
    private var invitedPeerNames: Set<String> = []
    // CONNECTING 中のピアを追跡（displayName で管理）。二重招待受け入れを防止する。
    // ★ このDictはMCSessionデリゲートキュー（バックグラウンド）とメインスレッドの両方からアクセスされるため
    //   専用のシリアルキューで保護する
    // value = CONNECTING 状態になった時刻（stale 判定用）
    private var _connectingPeerNames: [String: Date] = [:]
    private let connectingLock = DispatchQueue(label: "douki.connectingLock")
    
    /// CONNECTING のstale判定しきい値（Hang環境では10秒以上CONNECTINGが続くことがある）
    private let connectingStaleThreshold: TimeInterval = 15.0
    
    /// スレッドセーフな connectingPeerNames アクセサ
    private func isConnectingPeer(_ name: String) -> Bool {
        connectingLock.sync { _connectingPeerNames[name] != nil }
    }
    /// CONNECTING 中かつ stale でないかチェック（stale なら false を返す＝新しい招待を受け入れ可能）
    private func isConnectingPeerFresh(_ name: String) -> Bool {
        connectingLock.sync {
            guard let started = _connectingPeerNames[name] else { return false }
            return Date().timeIntervalSince(started) < connectingStaleThreshold
        }
    }
    private func addConnectingPeer(_ name: String) {
        connectingLock.sync { _connectingPeerNames[name] = Date() }
    }
    private func removeConnectingPeer(_ name: String) {
        connectingLock.sync { _ = _connectingPeerNames.removeValue(forKey: name) }
    }
    private func clearConnectingPeers() {
        connectingLock.sync { _connectingPeerNames.removeAll() }
    }
    
    /// outgoing 招待の連続失敗カウント（ピアごと）。閾値以上連続で Connection refused したら
    /// そのピアへの招待を止めて受け身モードに切り替える（相手からの招待を待つ）
    private var outgoingFailuresPerPeer: [String: Int] = [:]
    private let passiveModeThreshold: Int = 3
    
    // 再接続リトライ用カウンタ
    private let maxRetryCount = 5
    private var retryCounts: [String: Int] = [:]
    /// リトライ中フラグ（UI でリトライ中表示に使う）
    @Published var isRetrying: Bool = false
    
    /// 接続直後の猶予期間（デバッガ Hang による即座の切断を無視するため）
    /// key = peerName, value = 接続確立時刻
    /// ★ MCSessionデリゲートキュー（BG）とメインスレッドの両方からアクセスされるため connectingLock で保護
    private var _connectionTimestamps: [String: Date] = [:]
    /// 接続確立後にこの秒数以内の切断は無視してリトライしない（Hang耐性）
    private let connectionGracePeriod: TimeInterval = 20.0
    
    private func setConnectionTimestamp(_ name: String) {
        connectingLock.sync { _connectionTimestamps[name] = Date() }
    }
    private func getConnectionTimestamp(_ name: String) -> Date? {
        connectingLock.sync { _connectionTimestamps[name] }
    }
    private func removeConnectionTimestamp(_ name: String) {
        connectingLock.sync { _ = _connectionTimestamps.removeValue(forKey: name) }
    }
    private func clearConnectionTimestamps() {
        connectingLock.sync { _connectionTimestamps.removeAll() }
    }
    
    // MARK: - Device Score（招待戦略の優先度判定に使用）
    // スコアが高い端末が招待を送る側（initiator）になる
    // スコアが低い端末は受け身で待つ（responder）
    // → スペックの高い端末のソケットに接続しに行く方が Connection refused が起きにくい
    
    /// 自端末のスペックスコア（起動時に一度だけ算出）
    let deviceScore: Int = {
        let info = ProcessInfo.processInfo
        let cores = info.activeProcessorCount
        let memGB = Int(info.physicalMemory / (1024 * 1024 * 1024))
        // コア数 × 1000 + メモリGB でスコア化
        return cores * 1000 + memGB
    }()
    
    /// advertiser の discoveryInfo に載せる辞書
    private var discoveryDict: [String: String] {
        ["score": "\(deviceScore)"]
    }
    
    /// 発見したピアのスコア（UI表示用）
    @Published var peerScores: [String: Int] = [:]
    
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
    /// マスターからのannouncementでプレビューが閉じられた場合のフラグ
    private var pendingMasterAnnouncement = false
    
    // 転送状態管理
    @Published var isTransferring = false
    @Published var transferProgress: [String: Double] = [:]  // [PeerID: fractionCompleted]
    @Published var totalExpectedFiles = 0
    @Published var receivedFiles = 0
    @Published var currentTransferProgress: Double = 0       // 現在の転送進捗 (0.0〜1.0) — 送信 or 受信
    @Published var transferETAString: String = ""             // 残り時間の表示文字列
    private var transferTimeoutWork: DispatchWorkItem?
    private var receiveProgressObservation: NSKeyValueObservation?
    private var transferProgressStartTime: Date?
    private var sendProgressObservations: [NSKeyValueObservation] = []
    private var isReceivingFile: Bool = false                 // 受信中フラグ（受信進捗を優先表示用）
    
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
    
    // MARK: - Recording Disconnect Alert
    /// マスター: 録画中に切断されたピア名（非nil = アラート表示中）
    @Published var recordingDisconnectPeerName: String? = nil
    /// スレーブ: 録画中にマスターとの接続が切れた
    @Published var lostMasterDuringRecording: Bool = false
    
    // MARK: - Multi-Monitor
    /// マルチモニター表示中フラグ
    @Published var isMultiMonitorActive = false
    /// 各デバイスの最新スナップショット [displayName: JPEG Data]
    @Published var peerSnapshots: [String: Data] = [:]
    /// スナップショット送信タイマー
    private var snapshotTimer: Timer?
    
    // デバイス名の配列（UI用）
    var connectedPeerNames: [String] {
        connectedPeers.map { $0.displayName }
    }
    
    // ログ追加
    private func addLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        DispatchQueue.main.async {
            self.logs.append("[\(timestamp)] \(message)")
            if self.logs.count > 20 {
                self.logs.removeFirst()
            }
        }
        #if DEBUG
        print(message)
        #endif
    }
    
    enum ConnectionState {
        case disconnected
        case connecting
        case connected
    }
    
    // MARK: - Preview Support
    
    /// Canvas / Xcode Preview プロセス内かどうかを判定
    private static var isPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
    
    // MARK: - Initialization
    
    override init() {
        // UserDefaults に保存されたユーザー名を使用。未設定ならデバイス名にフォールバック。
        let savedName = UserDefaults.standard.string(forKey: "douki.userName")?.trimmingCharacters(in: .whitespaces)
        let displayName = (savedName?.isEmpty == false) ? savedName! : UIDevice.current.name
        self.myDisplayName = displayName
        self.myPeerID = MCPeerID(displayName: displayName)
        super.init()
        
        // Canvas Preview では MultipeerConnectivity を起動しない
        guard !Self.isPreview else { return }
        
        // セッション作成（暗号化必須）
        session = MCSession(peer: myPeerID,
                           securityIdentity: nil,
                           encryptionPreference: .none)
        session?.delegate = self
        
        // ★ アプリ起動時に Advertise & Browse 両方開始（以前動いていた方式）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startAutoDiscovery()
        }
    }
    
    deinit {
        snapshotTimer?.invalidate()
        snapshotTimer = nil
    }

    // MARK: - Public Methods
    
    /// 自動Discovery開始（アプリ起動時に自動実行）
    private func startAutoDiscovery() {
        guard advertiser == nil, browser == nil else {
            addLog("Auto-discovery already running")
            return
        }
        
        // アドバタイズとブラウズ両方開始
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID,
                                               discoveryInfo: discoveryDict,
                                               serviceType: serviceType)
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()
        
        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()
        
        connectionState = .connecting
        addLog("Auto-discovery started: \(myPeerID.displayName) (score=\(deviceScore))")
    }
    
    /// マスター役を選択（接続済みのピアに宣言を送信）
    func selectMasterRole() {
        isMaster = true
        masterPeerID = myPeerID
        persistentRole = true
        persistentMasterName = myPeerID.displayName
        addLog("Selected as Master (persistent)")

        // 既に接続済みのピアに master_announcement を送信
        for peer in connectedPeers {
            sendMasterAnnouncement(to: peer)
        }
    }

    /// マスター宣言を特定ピアに送信
    private func sendMasterAnnouncement(to peer: MCPeerID) {
        let command: [String: Any] = [
            "action": "master_announcement",
            "masterPeerID": myPeerID.displayName
        ]
        sendCommandTo(peer, command: command)
    }

    /// 接続直後にマスターであれば宣言を送る
    private func announceMasterRoleIfNeeded(to peer: MCPeerID) {
        guard isMaster, masterPeerID == myPeerID else { return }
        
        // チャンネル確立を待つため遅延（MCSession 内部ストリームの安定化に 2 秒必要）
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.connectedPeers.contains(where: { $0.displayName == peer.displayName }) else { return }
            self.sendMasterAnnouncement(to: peer)
            self.addLog("Master announcement sent to \(peer.displayName)")
        }
    }
    
    /// 完全停止（アプリ終了時など）
    func stopHosting() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        // ★ disconnect() はソケットクローズ待ちでメインスレッドをブロックするため、バックグラウンドで実行
        let oldSession = session
        oldSession?.delegate = nil
        if let old = oldSession {
            DispatchQueue.global(qos: .utility).async { old.disconnect() }
        }
        
        connectedPeers.removeAll()
        availablePeers.removeAll()
        invitedPeerNames.removeAll()
        clearConnectingPeers()
        connectionState = .disconnected
        isConnecting = false
        isMaster = false
        masterPeerID = nil
        persistentRole = false
        persistentMasterName = nil

        // リトライ関連をクリア
        retryCounts.removeAll()
        isRetrying = false
        outgoingFailuresPerPeer.removeAll()  // 完全停止時はリセット

        // 同期録画状態リセット
        isWaitingForReady = false
        readyPeers = []
        pendingSessionID = ""
        pendingTimestamp = 0
        pendingMasterAnnouncement = false
        
        // マルチモニターリセット
        isMultiMonitorActive = false
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        peerSnapshots.removeAll()
        cameraManager?.isSnapshotEnabled = false
        
        // セッションを再作成（クリーンな状態にする）
        session = MCSession(peer: myPeerID,
                           securityIdentity: nil,
                           encryptionPreference: .none)
        session?.delegate = self
        
        addLog("Stopped completely")
    }

    /// 切断が確定した後の共通処理（カメラ停止、リトライスケジュール等）
    /// ★ 必ずメインスレッドから呼ぶこと
    private func handleConfirmedDisconnect(peerName: String, peerID: MCPeerID) {
        addLog("Disconnected: \(peerName)")
        
        // 転送中にピアが切断された場合、期待ファイル数を調整する
        // （切断されたピアからのファイルは到着しないため）
        if isTransferring {
            // 切断されたピアのファイルを受信済みか確認
            let sid = sessionID
            let alreadyReceived = recordedVideos[sid]?.keys.contains(peerName) == true
            if !alreadyReceived && totalExpectedFiles > 0 {
                totalExpectedFiles = max(totalExpectedFiles - 1, receivedFiles)
                addLog("Transfer: adjusted expected from disconnected peer \(peerName) → \(receivedFiles)/\(totalExpectedFiles)")
                sessionExpectedCounts[sid] = totalExpectedFiles
                // 調整後に全ファイル揃っているか再チェック
                checkAllVideosReceived(sessionID: sid)
            }
            // 全ピア切断 → 転送をリセット（スタック防止）
            if connectedPeers.isEmpty {
                addLog("Transfer: all peers disconnected – resetting transfer state")
                isTransferring = false
                cleanupTransferProgress()
            }
        }
        
        // ★ 録画中の切断検知 — UI にアラートを表示する
        let isCurrentlyRecording = (cameraManager?.isRecording == true)
        if isCurrentlyRecording {
            if isMaster {
                recordingDisconnectPeerName = peerName
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.error)
                addLog("⚠️ ALERT: \(peerName) disconnected during recording!")
            } else if connectedPeers.isEmpty {
                lostMasterDuringRecording = true
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.error)
                addLog("⚠️ ALERT: Lost master connection during recording!")
            }
        }
        
        let isActive = isCurrentlyRecording
            || isTransferring
            || isWaitingForReady
            || isTransitioningToPreview
            || showPreview
        
        if connectedPeers.isEmpty && !isActive {
            sessionID = ""
            
            isWaitingForCameraReady = false
            cameraReadyPeers.removeAll()
            
            let cameraIsRunning = isCameraReady
                || (cameraManager?.isCameraSessionRunning == true)
            if cameraIsRunning {
                isCameraReady = false
                OrientationLock.isCameraActive = false
                cameraManager?.stopSession()
                enableIdleTimer()
                addLog("Camera stopped – all peers disconnected")
            }
            
            if isMultiMonitorActive {
                isMultiMonitorActive = false
                snapshotTimer?.invalidate()
                snapshotTimer = nil
                peerSnapshots.removeAll()
                cameraManager?.isSnapshotEnabled = false
            }
            
            if persistentRole {
                connectionState = .connecting
                addLog("Persistent mode – will retry (master=\(persistentMasterName ?? "nil"))")
            } else {
                connectionState = .disconnected
                if !isMaster && masterPeerID != nil {
                    masterPeerID = nil
                    addLog("Master disconnected – returning to search")
                } else {
                    addLog("Disconnected – will retry connection")
                }
            }
        } else {
            addLog("Still have \(connectedPeers.count) peer(s) connected")
        }
        
        if !isActive {
            retryConnectionImmediately(for: peerID)
        }
    }
    
    /// ★ イベント駆動リトライ: 切断イベントに即座に反応する
    /// - peer が availablePeers にいればすぐ再招待
    /// - いなければ何もしない（次の foundPeer イベントが自動でトリガーする）
    /// - 連続失敗時は rebuildSession で MCPeerID を再生成
    private func retryConnectionImmediately(for peerID: MCPeerID) {
        let peerName = peerID.displayName
        let currentCount = (retryCounts[peerName] ?? 0) + 1
        retryCounts[peerName] = currentCount
        
        let effectiveMaxRetry = persistentRole ? 30 : maxRetryCount
        
        guard currentCount <= effectiveMaxRetry else {
            addLog("Retry limit reached for \(peerName)")
            retryCounts.removeValue(forKey: peerName)
            if retryCounts.isEmpty { isRetrying = false }
            
            if persistentRole {
                addLog("Persistent mode – resetting retry cycle")
                retryCounts[peerName] = 0
                // 永続モードでは discovery を再起動して foundPeer イベントを待つ
                performLightweightRestart()
            }
            return
        }
        isRetrying = true
        
        addLog("Retry \(currentCount)/\(effectiveMaxRetry)")
        
        // 既に接続済みならスキップ
        guard !self.connectedPeers.contains(where: { $0.displayName == peerName }) else {
            retryCounts.removeValue(forKey: peerName)
            if retryCounts.isEmpty { isRetrying = false }
            return
        }
        
        // Passive mode: advertiser/browser のみ再起動して相手からの招待を待つ
        let peerFailures = outgoingFailuresPerPeer[peerName] ?? 0
        if peerFailures >= passiveModeThreshold {
            addLog("Retry: passive restart for \(peerName) (failures=\(peerFailures))")
            retryCounts.removeValue(forKey: peerName)
            performLightweightRestart()
            return
        }
        
        // ★ 3回以上失敗 → rebuildSession（MCPeerID 再生成で stale ソケットを根絶）
        if currentCount >= 3 {
            addLog("Retry: rebuild session (count=\(currentCount))")
            rebuildSession(preserveRole: true)
            return
        }
        
        // ★ 1-2回目: MCSession の内部ソケットクリーンアップを待ってから再招待
        // 即座に invitePeer すると前回の接続のクリーンアップと衝突して Connection refused になる
        invitedPeerNames.remove(peerName)
        removeConnectingPeer(peerName)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            guard !self.connectedPeers.contains(where: { $0.displayName == peerName }) else { return }
            
            if let visiblePeer = self.availablePeers.first(where: { $0.displayName == peerName }) {
                self.addLog("Retry: peer still visible – re-inviting")
                self.invitedPeerNames.insert(peerName)
                self.invitePeer(visiblePeer)
            } else {
                self.addLog("Retry: peer not visible – waiting for foundPeer event")
            }
        }
    }
    
    /// MCSession + advertiser + browser を完全に再初期化する（接続状態のみリセット、役割は維持）
    /// ★ fullRestart は rebuildSession に統一（MCPeerID を毎回再生成して "we never sent it an invitation" を根絶）
    private func fullRestart() {
        addLog("Full restart → delegating to rebuildSession")
        rebuildSession(preserveRole: true)
    }
    
    /// 軽量リスタート: MCPeerID と MCSession は維持し、advertiser/browser のみ再起動
    /// Xcode REBUILD 後の再接続やデバッガ Hang 後の回復で使用。
    /// MCPeerID を変えないため、相手側が既に持っている PeerID 参照がそのまま有効で、
    /// Connection refused を回避しやすい。
    private func performLightweightRestart() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        
        // 招待状態をクリア（新しい発見サイクルで再招待できるようにする）
        invitedPeerNames.removeAll()
        clearConnectingPeers()
        availablePeers.removeAll()
        
        // ★ 即座に再起動（MCPeerID/MCSession を維持するのでソケット待ち不要）
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID,
                                                discoveryInfo: discoveryDict,
                                                serviceType: serviceType)
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()
        
        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()
        
        connectionState = .connecting
        addLog("Lightweight restart: advertiser/browser restarted (PeerID kept)")
    }
    
    /// リビルド中フラグ（多重実行防止）
    @Published var isRebuilding: Bool = false
    /// リビルド開始時刻（Hang でスタックした場合のタイムアウト判定用）
    private var rebuildStartedAt: Date?
    /// リビルドの遅延再構築 WorkItem（キャンセル可能にするため保持）
    private var rebuildWorkItem: DispatchWorkItem?

    /// セッションを完全に再構築する（アプリを再起動したのと同等の効果）
    /// MCPeerID は維持するが、MCSession / advertiser / browser を全て破棄→再作成する
    /// - Parameter preserveRole: true の場合、isMaster / masterPeerID / persistentRole をリセットしない（自動リトライ用）
    func rebuildSession(preserveRole: Bool = false) {
        // 多重実行ガード（即座にチェック）
        if isRebuilding {
            if let started = rebuildStartedAt, Date().timeIntervalSince(started) > 8.0 {
                addLog("REBUILD: previous rebuild timed out (\(String(format: "%.1f", Date().timeIntervalSince(started)))s) – forcing restart")
                rebuildWorkItem?.cancel()
                rebuildWorkItem = nil
                isRebuilding = false
                // fall through to start new rebuild
            } else {
                addLog("REBUILD: already in progress, ignoring")
                return
            }
        }
        
        // ★ パッシブモード中の自動リトライでは REBUILD を禁止
        // MCPeerID を再生成すると相手からの incoming 招待が切れるため、
        // advertiser/browser の再起動だけで済ませる
        // ★ 全ピアがパッシブモード閾値以上なら REBUILD を抑制
        let allPassive = !outgoingFailuresPerPeer.isEmpty &&
            outgoingFailuresPerPeer.values.allSatisfy { $0 >= passiveModeThreshold }
        if preserveRole && allPassive {
            addLog("REBUILD: blocked in passive mode – doing passive restart instead")
            invitedPeerNames.removeAll()
            clearConnectingPeers()
            availablePeers.removeAll()
            advertiser?.stopAdvertisingPeer()
            browser?.stopBrowsingForPeers()
            advertiser = MCNearbyServiceAdvertiser(peer: myPeerID,
                                                    discoveryInfo: discoveryDict,
                                                    serviceType: serviceType)
            advertiser?.delegate = self
            advertiser?.startAdvertisingPeer()
            browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
            browser?.delegate = self
            browser?.startBrowsingForPeers()
            addLog("Passive restart: advertiser/browser restarted – waiting for invitation")
            return
        }
        
        isRebuilding = true
        rebuildStartedAt = Date()
        addLog("REBUILD: tearing down session...")

        // 前回の遅延 WorkItem が残っていたらキャンセル
        rebuildWorkItem?.cancel()
        rebuildWorkItem = nil

        // 1. 全部停止
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        advertiser = nil
        browser = nil
        
        // ★ disconnect() を同期的に実行し、古いソケットを確実に閉じる
        //    session を nil にしてから新しいセッションを作成することで、内部リソースの競合を防ぐ
        session?.delegate = nil
        session?.disconnect()
        session = nil
        
        // ★ 新しい MCPeerID + MCSession を作成
        myPeerID = MCPeerID(displayName: myDisplayName)
        session = MCSession(peer: myPeerID,
                             securityIdentity: nil,
                             encryptionPreference: .none)
        session?.delegate = self

        // 2. 全ステートをクリア
        connectedPeers.removeAll()
        availablePeers.removeAll()
        invitedPeerNames.removeAll()
        clearConnectingPeers()
        clearConnectionTimestamps()
        connectionState = .disconnected
        isConnecting = false
        if !preserveRole {
            isMaster = false
            masterPeerID = nil
            persistentRole = false
            persistentMasterName = nil
        }

        if !preserveRole {
            retryCounts.removeAll()
            isRetrying = false
            // ★ 手動 REBUILD: outgoingFailuresPerPeer をリセットして積極的に再接続
            outgoingFailuresPerPeer.removeAll()
        } else {
            // 自動リトライ REBUILD: outgoingFailuresPerPeer は維持
            // （接続成功時にそのピアのカウンタのみリセットされる）
        }

        isWaitingForReady = false
        readyPeers = []
        pendingSessionID = ""
        pendingTimestamp = 0
        pendingMasterAnnouncement = false

        isWaitingForCameraReady = false
        cameraReadyPeers = []
        isCameraReady = false

        isMultiMonitorActive = false
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        peerSnapshots.removeAll()
        cameraManager?.isSnapshotEnabled = false

        enableIdleTimer()
        addLog("REBUILD: all state cleared")

        // 3. 古いソケットが完全に解放されるまで待ってから advertiser/browser を再起動
        //    MCPeerID と MCSession は上で即座に作成済み（招待を拒否しないため）
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }

            // Advertise + Browse 両方再開
            self.advertiser = MCNearbyServiceAdvertiser(peer: self.myPeerID,
                                                        discoveryInfo: self.discoveryDict,
                                                        serviceType: self.serviceType)
            self.advertiser?.delegate = self
            self.advertiser?.startAdvertisingPeer()

            self.browser = MCNearbyServiceBrowser(peer: self.myPeerID, serviceType: self.serviceType)
            self.browser?.delegate = self
            self.browser?.startBrowsingForPeers()

            self.connectionState = .connecting
            self.isRebuilding = false
            self.rebuildStartedAt = nil
            self.addLog("REBUILD: session rebuilt (new PeerID) – searching...")
        }
        rebuildWorkItem = workItem
        // ★ MCSession disconnect 後のソケットクリーンアップ待ち（安全弁）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    /// 切断後にDiscoveryを再開始（役割選択画面に戻る時に使用）
    func restartDiscovery() {
        // まず完全停止
        stopHosting()
        
        // 役割をリセット
        isMaster = false
        masterPeerID = nil
        
        // 少し待ってから Advertise + Browse 再開始
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startAutoDiscovery()
        }
    }

    /// ディスカバリーを一時停止（設定画面など、バックグラウンド処理を止めたい時に使用）
    /// advertiser は維持（相手からの招待を受け付けられるように）
    /// browser とリトライだけ停止
    func pauseDiscovery() {
        // リトライを全停止
        retryCounts.removeAll()
        isRetrying = false

        // browser のみ停止（advertiser は相手からの招待受付のため維持）
        browser?.stopBrowsingForPeers()
        browser = nil
        invitedPeerNames.removeAll()
        availablePeers.removeAll()

        addLog("Discovery paused (advertiser kept)")
    }

    /// ディスカバリーを再開（設定画面を閉じた時に使用）
    func resumeDiscovery() {
        // 既に接続済みなら再開不要
        guard connectedPeers.isEmpty else {
            addLog("Already connected, skip resume")
            return
        }
        // browser が動いていなければ再開
        if browser == nil {
            browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
            browser?.delegate = self
            browser?.startBrowsingForPeers()
        }
        // advertiser も念のため起動確認
        if advertiser == nil {
            advertiser = MCNearbyServiceAdvertiser(peer: myPeerID,
                                                   discoveryInfo: discoveryDict,
                                                   serviceType: serviceType)
            advertiser?.delegate = self
            advertiser?.startAdvertisingPeer()
        }
        connectionState = .connecting
        addLog("Discovery resumed")
    }

    /// advertiser/browser を静かに再開する（ログや状態変更は最小限）
    private func resumeDiscoveryQuietly() {
        if advertiser == nil {
            advertiser = MCNearbyServiceAdvertiser(peer: myPeerID,
                                                   discoveryInfo: discoveryDict,
                                                   serviceType: serviceType)
            advertiser?.delegate = self
            advertiser?.startAdvertisingPeer()
        }
        if browser == nil {
            browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
            browser?.delegate = self
            browser?.startBrowsingForPeers()
        }
    }

    /// プレビューを強制的に閉じる（マスターからのコマンド受信時用。役割はリセットしない）
    func dismissPreviewForNextSession() {
        guard showPreview else { return }
        
        // UI状態のみリセット
        sessionID = ""
        isWaitingForReady = false
        readyPeers = []
        pendingSessionID = ""
        pendingTimestamp = 0
        isTransitioningToPreview = false
        showPreview = false
        
        // カメラ関連のフラグもリセット
        isCameraReady = false
        OrientationLock.isCameraActive = false
        
        // 録画データをクリア
        recordedVideos.removeAll()
        sessionExpectedCounts.removeAll()
        
        // ★ 役割はリセットしない（master_announcement / start_camera から呼ばれるため）
        // cleanupSessionAfterPreview の onDismiss で役割がリセットされないようにフラグを立てる
        pendingMasterAnnouncement = true
        addLog("Preview dismissed – preparing for next session")
    }
    
    /// プレビューを閉じた後のクリーンアップ（接続は維持）
    /// - Returns: trueならマスターだった（roleSelectionScreenに戻す）、falseならスレーブだった（AWAIT維持）
    @discardableResult
    func cleanupSessionAfterPreview() -> Bool {
        // ★ advertiser/browser は停止しない（接続を維持）
        // ★ session も切断しない
        // ★ connectedPeers もクリアしない
        
        // マスターだったかどうかを先に保存（リセット前に判定するため）
        let wasMaster = isMaster
        
        // UI状態のみリセット
        sessionID = ""
        isWaitingForReady = false
        readyPeers = []
        pendingSessionID = ""
        pendingTimestamp = 0
        isTransitioningToPreview = false
        showPreview = false
        
        // カメラ関連のフラグもリセット
        isCameraReady = false
        OrientationLock.isCameraActive = false

        // Documents/ のファイルはライブラリ用に保持する（削除しない）
        // メモリ上の recordedVideos・sessionExpectedCounts だけクリアする
        recordedVideos.removeAll()
        sessionExpectedCounts.removeAll()

        // ★ 役割のリセット
        // dismissPreviewForNextSessionから呼ばれた場合、既にmasterPeerIDが新しい値にセットされている
        // ので、リセットしない（pendingMasterAnnouncementフラグで判定）
        if pendingMasterAnnouncement {
            // マスターからのannouncementでプレビューが閉じられた → 役割はリセットしない
            pendingMasterAnnouncement = false
            addLog("Preview closed – slave role maintained (master=\(masterPeerID?.displayName ?? "nil"))")
        } else if persistentRole {
            // ★ 永続モード: マスターもスレーブも役割をリセットしない
            if wasMaster {
                addLog("Preview closed – master role persisted")
            } else {
                addLog("Preview closed – slave role persisted (master=\(masterPeerID?.displayName ?? "nil"))")
            }
        } else if wasMaster {
            // マスターがプレビューを閉じた → マスター役のみリセット（roleSelectionScreenに戻す）
            isMaster = false
            masterPeerID = nil
            addLog("Preview closed – master returning to role selection")
        } else {
            // スレーブがプレビューを閉じた → スレーブ役は維持（AWAIT画面に戻る）
            isMaster = false
            masterPeerID = nil
            addLog("Preview closed – slave returning to await")
        }
        
        // ★ 接続は維持
        if connectedPeers.isEmpty {
            if persistentRole {
                // 永続モード: 切断しても即リトライ、SEARCHING には戻さない
                addLog("No peers – persistent mode, will retry connection")
                resumeDiscoveryQuietly()
            } else {
                connectionState = .disconnected
                isWaitingForCameraReady = false
                cameraReadyPeers.removeAll()
                addLog("No peers remaining – returning to search")
            }
        } else {
            // ピアが残っている場合、advertiser/browser を再開する
            resumeDiscoveryQuietly()
        }
        
        enableIdleTimer()
        
        #if DEBUG
        print("📹 [SessionManager] Cleaned up after preview – connection maintained")
        #endif
        
        return wasMaster
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
                #if DEBUG
                print("🗑️ [Cleanup] Deleted: \(file.lastPathComponent)")
                #endif
            } catch {
                #if DEBUG
                print("❌ [Cleanup] Failed to delete \(file.lastPathComponent): \(error.localizedDescription)")
                #endif
            }
        }
        recordedVideos.removeAll()
        #if DEBUG
        print("🗑️ [Cleanup] Deleted \(deletedCount) file(s) from Documents/")
        #endif
    }
    
    /// 特定のピアに接続招待を送る
    func invitePeer(_ peer: MCPeerID) {
        guard let browser = browser,
              let currentSession = session else {
            addLog("Skip invite: browser or session is nil")
            return
        }
        
        // 既に接続済み or CONNECTING 中はSkip
        let peerName = peer.displayName
        if connectedPeers.contains(where: { $0.displayName == peerName }) {
            addLog("Skip: \(peerName) already connected")
            return
        }
        if currentSession.connectedPeers.contains(where: { $0.displayName == peerName }) {
            addLog("Skip: \(peerName) already in session.connectedPeers")
            return
        }
        if isConnectingPeerFresh(peerName) {
            addLog("Skip: \(peerName) already CONNECTING (fresh)")
            return
        }
        // stale な CONNECTING をクリアして再招待
        removeConnectingPeer(peerName)
        
        #if DEBUG
        print("📡 [Invite] Session peers: \(currentSession.connectedPeers.map { $0.displayName })")
        print("📡 [Invite] Session myPeerID: \(currentSession.myPeerID.displayName)")
        print("📡 [Invite] Target peer: \(peer.displayName)")
        #endif
        
        // ★ invite 送信と同時に connectingPeerNames に追加（.connecting コールバックより先にガードを有効化）
        addConnectingPeer(peerName)
        // timeout を短くして早く失敗判定する（Connection refused は数秒で判明する）
        // 長い timeout は MCSession 内部のリトライで帯域を占有し、相手からの incoming 招待と干渉する
        browser.invitePeer(peer,
                          to: currentSession,
                          withContext: nil,
                          timeout: 10)
        
        addLog("Inviting: \(peer.displayName)")
    }
    
    // MARK: - Recording Commands
    
    /// カメラ起動コマンドを送信（マスターのみ）
    func startCameraForAll() {
        guard isMaster else {
            addLog("Only master can start camera")
            return
        }
        guard !connectedPeers.isEmpty else {
            addLog("No peers connected — cannot start camera")
            return
        }
        
        addLog("Starting camera for all devices...")
        
        // カメラ起動待機モードに入る
        isWaitingForCameraReady = true
        cameraReadyPeers = []
        
        // カメラ起動 → 撮影画面は傾きに追従（回転許可）
        OrientationLock.isCameraActive = true
        
        // 先に自分のカメラを起動（完了後にコマンド送信）
        cameraManager?.setupCamera()
        
        // MCSessionチャンネルが確実に確立するまで待ってからコマンドを送信
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            
            // 既に切断済みならカメラ起動フローを中止
            guard self.connectionState != .disconnected else {
                self.addLog("Camera start cancelled – already disconnected")
                return
            }
            
            #if DEBUG
            print("📷 [SessionManager] Sending start_camera commands to \(self.connectedPeers.count) peer(s)")
            #endif
            
            // スレーブが1台もいない場合はカメラを停止してメイン画面に戻る
            if self.connectedPeers.isEmpty {
                self.isWaitingForCameraReady = false
                self.isCameraReady = false
                self.addLog("No peers connected — command 'start_camera' aborted")
                self.addLog("Stopping camera and returning to menu")
                self.cameraManager?.stopSession()
                OrientationLock.isCameraActive = false
                return
            }
            
            // 全スレーブにカメラ起動コマンドを送信
            for peer in self.connectedPeers {
                self.sendCameraStartCommand(to: peer)
            }
            
            self.addLog("Waiting for camera_ready from \(self.connectedPeers.count) peer(s)...")
            
            // タイムアウト: 15秒以内に全員から camera_ready が来なければキャンセル
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
                guard let self, self.isWaitingForCameraReady else { return }
                self.isWaitingForCameraReady = false
                self.cameraReadyPeers = []
                self.addLog("Camera ready timeout – some peers did not respond")
                // タイムアウトしても続行（応答したピアとだけ録画）
                self.isCameraReady = true
                self.disableIdleTimer()
            }
        }
    }
    
    /// カメラを停止してメニューに戻る
    func stopCameraAndReturnToMenu() {
        addLog("Stopping camera and returning to menu...")
        
        // カメラ停止 → 接続画面に戻るので縦固定に（notifyOrientationChange で縦に戻る）
        OrientationLock.isCameraActive = false
        
        // カメラを停止
        cameraManager?.stopSession()
        isCameraReady = false
        
        // 全ピアにカメラ停止コマンドを送信
        if isMaster {
            let command: [String: Any] = ["action": "stop_camera"]
            sendCommandToAll(command)
        }
        
        addLog("Camera stopped")
    }
    
    // MARK: - Multi-Monitor
    
    /// マルチモニター開始（マスターから全デバイスにスナップショット送信を指示）
    func startMultiMonitor() {
        isMultiMonitorActive = true
        peerSnapshots.removeAll()
        
        // 自分のスナップショット取得を有効化
        cameraManager?.isSnapshotEnabled = true
        
        // 全スレーブにマルチモニター開始コマンドを送信
        let command: [String: Any] = ["action": "start_multi_monitor"]
        sendCommandToAll(command)
        
        // 0.5秒間隔でスナップショットを送信するタイマーを開始
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.sendSnapshotToPeers()
        }
        
        addLog("Multi-monitor started")
    }
    
    /// マルチモニター停止
    func stopMultiMonitor() {
        isMultiMonitorActive = false
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        peerSnapshots.removeAll()
        
        // 自分のスナップショット取得を無効化
        cameraManager?.isSnapshotEnabled = false
        
        // 全スレーブにマルチモニター停止コマンドを送信
        let command: [String: Any] = ["action": "stop_multi_monitor"]
        sendCommandToAll(command)
        
        addLog("Multi-monitor stopped")
    }
    
    /// 自分のスナップショットを全ピアに送信（バイナリプレフィックスプロトコル）
    private func sendSnapshotToPeers() {
        guard isMultiMonitorActive,
              let session = session,
              let jpegData = cameraManager?.latestSnapshot else { return }
        
        // 自分のスナップショットもpeerSnapshotsに登録
        let myName = myPeerID.displayName
        DispatchQueue.main.async {
            self.peerSnapshots[myName] = jpegData
        }
        
        // バイナリプレフィックス: 0x01 + deviceName(UTF8) + 0x00(null terminator) + JPEG data
        var payload = Data([0x01])
        payload.append(Data(myName.utf8))
        payload.append(0x00) // null terminator
        payload.append(jpegData)
        
        let peers = connectedPeers
        guard !peers.isEmpty else { return }
        
        do {
            try session.send(payload, toPeers: peers, with: .unreliable)
        } catch {
            // unreliable送信の失敗は無視（次のフレームで再送される）
        }
    }
    
    /// 受信したスナップショットバイナリを処理
    private func handleReceivedSnapshot(_ data: Data) {
        // フォーマット: 0x01 + deviceName(UTF8) + 0x00 + JPEG data
        guard data.count > 2 else { return }
        
        // 先頭の0x01をスキップしてnull terminatorを探す
        let payload = data.dropFirst() // 0x01をスキップ
        guard let nullIndex = payload.firstIndex(of: 0x00) else { return }
        
        let nameData = payload[payload.startIndex..<nullIndex]
        guard let deviceName = String(data: Data(nameData), encoding: .utf8) else { return }
        
        let jpegStart = payload.index(after: nullIndex)
        guard jpegStart < payload.endIndex else { return }
        let jpegData = Data(payload[jpegStart...])
        
        DispatchQueue.main.async {
            self.peerSnapshots[deviceName] = jpegData
        }
    }
    
    /// カメラ起動コマンドを送信（向き設定を含む）
    private func sendCameraStartCommand(to peer: MCPeerID) {
        let command: [String: Any] = [
            "action": "start_camera",
            "orientation": cameraManager?.desiredOrientation.rawValue ?? VideoOrientation.cinema.rawValue
        ]
        
        guard let data = try? JSONSerialization.data(withJSONObject: command) else {
            addLog("Failed to serialize start_camera command")
            return
        }
        
        guard let session = session else { return }
        
        do {
            try session.send(data, toPeers: [peer], with: .reliable)
            addLog("Sent start_camera to \(peer.displayName)")
        } catch {
            addLog("Failed to send start_camera: \(error.localizedDescription)")
        }
    }
    
    /// 全員からcamera_readyを受信したかチェック
    private func checkAllCamerasReady() {
        guard isWaitingForCameraReady else { return }
        let expectedNames = Set(connectedPeers.map(\.displayName))
        let readyNames = Set(cameraReadyPeers.map(\.displayName))
        guard !expectedNames.isEmpty, expectedNames.isSubset(of: readyNames) else { return }
        
        isWaitingForCameraReady = false
        isCameraReady = true
        disableIdleTimer()
        addLog("All cameras ready! Recording mode enabled.")
    }
    
    /// 全端末でRecording（マスターのみ）― フェーズ1: ready コマンドを送信
    func startRecordingAll() {
        guard isMaster else {
            addLog("Only master can start recording")
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

        // iOS スレーブが1台もいない場合（ソロ）
        if connectedPeers.isEmpty {
            isWaitingForReady = false
            sessionID = pendingSessionID
            sessionExpectedCounts[pendingSessionID] = 1  // self only
            
            handleStartRecording(timestamp: pendingTimestamp, sessionID: pendingSessionID)
            addLog("Recording started: SessionID=\(pendingSessionID) (1 device(s))")
            return
        }

        addLog("Ensuring camera ready before sending recording_ready…")

        // マスター自身のカメラが起動済みであることを確認してから recording_ready を送信
        // （カメラ未起動のまま fire すると、マスター側だけ録画開始が遅れてズレる）
        cameraManager?.startSession { [weak self] in
            guard let self else { return }
            // カメラ起動完了時点で、まだ同じセッションの待機中か確認
            // （起動に時間がかかってユーザーがキャンセルした場合に誤送信しない）
            guard self.isWaitingForReady,
                  self.pendingSessionID == newSessionID else {
                self.addLog("Camera ready but session already cancelled – skip")
                return
            }
            // カメラ起動完了 → recording_ready を全スレーブに送信
            let command: [String: Any] = [
                "action": "recording_ready",
                "sessionID": newSessionID
            ]
            self.sendCommandToAll(command)
            self.addLog("Waiting for ready from \(self.connectedPeers.count) peer(s)…")

            // タイムアウト: 10秒以内に全員から ready_ack が来なければキャンセル
            let waitingSessionID = newSessionID
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                guard let self, self.isWaitingForReady,
                      self.pendingSessionID == waitingSessionID else { return }
                self.isWaitingForReady = false
                self.readyPeers = []
                self.pendingSessionID = ""
                self.pendingTimestamp = 0
                self.addLog("Ready timeout – recording cancelled")
            }
        }
    }

    /// 全員 ready_ack を返したら fire（フェーズ2）
    private func fireRecordingIfAllReady() {
        guard isWaitingForReady else { return }
        // 接続中の全ピアが ready_ack を返したか確認（displayNameベース）
        let expectedNames = Set(connectedPeers.map(\.displayName))
        let ackNames = Set(readyPeers.map(\.displayName))
        guard !expectedNames.isEmpty, expectedNames.isSubset(of: ackNames) else { return }

        isWaitingForReady = false

        // ★ 録画開始の瞬間の台数を確定して記録する。
        // 転送フェーズ中に誰かが切断しても expectedCount が変わらないようにするため。
        let participantCount = connectedPeers.count + 1  // iOS slaves + master
        sessionExpectedCounts[pendingSessionID] = participantCount
        addLog("Session \(pendingSessionID): \(participantCount)台で録画開始")

        let command: [String: Any] = [
            "action": "recording_fire",
            "timestamp": pendingTimestamp,
            "sessionID": pendingSessionID
        ]
        sendCommandToAll(command)
        addLog("Fire! Starting sync recording: SessionID=\(pendingSessionID)")

        // マスター自身も録画開始
        handleStartRecording(timestamp: pendingTimestamp, sessionID: pendingSessionID)
    }
    
    /// 全端末でStopped（マスターのみ）
    func stopRecordingAll() {
        guard isMaster else {
            addLog("Only master can stop recording")
            return
        }
        
        #if DEBUG
        print("📹 [SessionManager] stopRecordingAll called")
        print("📹 [SessionManager] Current SessionID: '\(sessionID)'")
        #endif
        
        let command: [String: Any] = [
            "action": "stop_recording",
            "timestamp": Date().timeIntervalSince1970,
            "sessionID": sessionID  // SessionIDを含める
        ]
        
        sendCommandToAll(command)
        addLog("Recording stopped")
        
        // 自分もStopped
        handleStopRecording()
        
        // SessionIDはクリアしない（録画完了コールバックで使用するため）
        #if DEBUG
        print("📹 [SessionManager] SessionID will be cleared after video transfer")
        #endif
    }
    
    // MARK: - Idle Timer Management
    
    /// スリープ防止を有効にする（カメラ起動時〜プレビュー終了まで維持）
    private func disableIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = true
    }
    
    /// スリープ防止を解除する（プレビュー終了・セッション完全終了時のみ）
    private func enableIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = false
    }
    
    // MARK: - Recording Disconnect Alert Actions
    
    /// 切断アラートから全台録画停止
    func stopRecordingFromDisconnectAlert() {
        recordingDisconnectPeerName = nil
        lostMasterDuringRecording = false
        stopRecordingAll()
    }
    
    /// 切断アラートを閉じて録画続行
    func dismissDisconnectAlert() {
        recordingDisconnectPeerName = nil
        lostMasterDuringRecording = false
    }
    
    /// スレーブ: マスター切断時にローカル録画停止
    func stopRecordingLocally() {
        lostMasterDuringRecording = false
        handleStopRecording()
    }
    
    // MARK: - Private Methods
    
    /// 全ピアにコマンド送信
    private func sendCommandToAll(_ command: [String: Any]) {
        guard let session = session else {
            addLog("No session")
            return
        }
        guard !connectedPeers.isEmpty else {
            addLog("No peers connected – command '\(command["action"] ?? "")' not sent")
            return
        }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: command)
            // 全ピアへ一括送信を試みる
            do {
                try session.send(jsonData, toPeers: connectedPeers, with: .reliable)
                addLog("Command sent: \(command["action"] ?? "")")
            } catch {
                // 一括送信失敗時は個別にリトライ（一部ピアが切断状態でも他には届けるため）
                addLog("Bulk send failed (\(error.localizedDescription)) – retrying individually")
                for peer in connectedPeers {
                    do {
                        try session.send(jsonData, toPeers: [peer], with: .reliable)
                        addLog("Command sent to \(peer.displayName): \(command["action"] ?? "")")
                    } catch {
                        addLog("Send to \(peer.displayName) failed: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            addLog("Serialize failed: \(error.localizedDescription)")
        }
    }

    /// 特定ピアにコマンド送信
    private func sendCommandTo(_ peer: MCPeerID, command: [String: Any]) {
        guard let session = session else { return }
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: command)
            try session.send(jsonData, toPeers: [peer], with: .reliable)
        } catch {
            addLog("Send to \(peer.displayName) failed: \(error.localizedDescription)")
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
            
            self.addLog("Received from \(peer.displayName): \(action)")
            
            switch action {
            case "start_recording":
                if let timestamp = command["timestamp"] as? TimeInterval,
                   let sessionID = command["sessionID"] as? String {
                    self.handleStartRecording(timestamp: timestamp, sessionID: sessionID)
                }

            case "master_announcement":
                // スレーブ: マスターからの宣言を受信したら自動的にスレーブになる
                if let masterPeerName = command["masterPeerID"] as? String {
                    self.handleMasterAnnouncement(masterPeerID: peer, masterPeerName: masterPeerName)
                }

            case "recording_ready":
                // スレーブ: カメラセッションが起動済みであることを確認してから ready_ack を返す
                if let sid = command["sessionID"] as? String {
                    self.addLog("recording_ready received – ensuring camera ready")
                    self.cameraManager?.startSession {
                        // startSession は既に起動済みなら即コールバックされる
                        self.addLog("Camera confirmed ready – sending ready_ack")
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
                    self.addLog("Ready from \(peer.displayName) (\(self.readyPeers.count)/\(self.connectedPeers.count))")
                    self.fireRecordingIfAllReady()
                }

            case "recording_fire":
                // スレーブ: 録画を一斉開始
                if let timestamp = command["timestamp"] as? TimeInterval,
                   let sessionID = command["sessionID"] as? String {
                    self.addLog("Fire received – starting recording")
                    self.handleStartRecording(timestamp: timestamp, sessionID: sessionID)
                }

            case "stop_recording":
                // スレーブ: マスターからの停止コマンドを受信
                // sessionID が一致する場合のみ処理（古いセッションの誤受信を防ぐ）
                let incomingSessionID = command["sessionID"] as? String ?? ""
                if incomingSessionID.isEmpty || incomingSessionID == self.sessionID {
                    self.addLog("Stop received from \(peer.displayName)")
                    self.handleStopRecording()
                } else {
                    self.addLog("stop_recording sessionID mismatch: got \(incomingSessionID), current \(self.sessionID)")
                }
                
            case "start_camera":
                // スレーブ: マスターからのカメラ起動コマンドを受信
                self.addLog("start_camera received from \(peer.displayName)")
                
                // マスターの向き設定を適用
                if let orientationRaw = command["orientation"] as? String,
                   let orientation = VideoOrientation(rawValue: orientationRaw) {
                    self.cameraManager?.desiredOrientation = orientation
                    self.addLog("Orientation synced: \(orientationRaw)")
                }
                
                // ★ プレビュー/編集画面を表示中なら閉じる
                if self.showPreview {
                    self.addLog("Closing preview – master starting camera")
                    self.dismissPreviewForNextSession()
                }
                
                // Add delay before starting camera to ensure MCSession channel stability
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self else { return }
                    self.handleStartCamera(fromPeer: peer)
                }
                
            case "camera_ready":
                // マスター: スレーブからのカメラ準備完了通知を受け取る
                if let peerName = command["peerName"] as? String {
                    self.cameraReadyPeers.insert(peer)
                    self.addLog("Camera ready from \(peerName) (\(self.cameraReadyPeers.count)/\(self.connectedPeers.count))")
                    self.checkAllCamerasReady()
                }
            
            case "stop_camera":
                // スレーブ: マスターからのカメラ停止コマンドを受信
                self.addLog("stop_camera received from \(peer.displayName)")
                OrientationLock.isCameraActive = false  // 画面回転制限を解除
                self.cameraManager?.stopSession()
                self.isCameraReady = false
                
            case "start_multi_monitor":
                // スレーブ: マルチモニター開始
                self.addLog("start_multi_monitor received")
                self.isMultiMonitorActive = true
                self.cameraManager?.isSnapshotEnabled = true
                // スレーブも0.5秒間隔でスナップショットを送信
                self.snapshotTimer?.invalidate()
                self.snapshotTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    self?.sendSnapshotToPeers()
                }
                
            case "stop_multi_monitor":
                // スレーブ: マルチモニター停止
                self.addLog("stop_multi_monitor received")
                self.isMultiMonitorActive = false
                self.snapshotTimer?.invalidate()
                self.snapshotTimer = nil
                self.cameraManager?.isSnapshotEnabled = false
                
            default:
                self.addLog("Unknown command: \(action)")
            }
            
        } catch {
            self.addLog("Parse error: \(error.localizedDescription)")
        }
        }
    }
    
    /// マスター宣言の処理（スレーブ側）
    private func handleMasterAnnouncement(masterPeerID: MCPeerID, masterPeerName: String) {
        // 既にマスター役を選択済みの場合は無視（衝突防止）
        guard !isMaster else {
            addLog("Already master – ignoring announcement from \(masterPeerName)")
            return
        }
        
        // ★ プレビュー/編集画面を表示中なら閉じる
        if showPreview {
            addLog("Closing preview – master announced new session")
            dismissPreviewForNextSession()
        }
        
        // 自動的にスレーブになる
        self.masterPeerID = masterPeerID
        isMaster = false
        persistentRole = true
        persistentMasterName = masterPeerName
        
        addLog("Auto-assigned as Slave (persistent) – Master: \(masterPeerName)")
        addLog("Camera startup deferred to start_camera command")
    }
    
    /// カメラ起動処理（スレーブ用）
    private func handleStartCamera(fromPeer peer: MCPeerID) {
        addLog("Starting camera for slave...")
        
        // カメラ起動 → 撮影画面は傾きに追従（回転許可）
        OrientationLock.isCameraActive = true
        
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
            self.addLog("Sent camera_ready to \(peer.displayName)")
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
        
        addLog("Recording: SessionID=\(sessionID)")
    }
    
    /// Stopped処理
    private func handleStopRecording() {
        // 切断アラートをクリア
        recordingDisconnectPeerName = nil
        lostMasterDuringRecording = false
        
        #if DEBUG
        print("📹 [SessionManager] handleStopRecording called")
        print("📹 [SessionManager] Current SessionID: '\(sessionID)'")
        #endif
        
        // カメラの録画を停止
        cameraManager?.stopRecording()
        
        addLog("Stopped")
        
        // SessionIDはクリアしない（録画完了コールバックで使用するため）
        #if DEBUG
        print("📹 [SessionManager] Waiting for recording completion callback...")
        #endif
    }
    
    // MARK: - Video Transfer
    
    /// Recording completion handler (public method)
    public func handleRecordingCompleted(videoURL: URL, sessionID: String) {
        #if DEBUG
        print("📹 [SessionManager] ========== HANDLE RECORDING COMPLETED ==========")
        print("📹 [SessionManager] Called from: \(Thread.isMainThread ? "Main" : "Background") thread")
        print("📹 [SessionManager] SessionID: '\(sessionID)'")
        print("📹 [SessionManager] Device: \(myPeerID.displayName)")
        print("📹 [SessionManager] File path: \(videoURL.path)")
        print("📹 [SessionManager] File exists: \(FileManager.default.fileExists(atPath: videoURL.path))")
        print("📹 [SessionManager] Connected peers: \(connectedPeers.count)")
        #endif

        // ✅ Stop camera when recording ends (transfer continues in background)
        cameraManager?.stopSession()
        addLog("Camera stopped – recording completed, starting transfer")
        
        #if DEBUG
        if let fileSize = try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? UInt64 {
            print("📹 [SessionManager] File size: \(fileSize) bytes")
        }
        #endif
        
        #if DEBUG
        for peer in connectedPeers {
            print("📹 [SessionManager]   - Peer: \(peer.displayName)")
        }
        #endif
        
        addLog("Recording completed: \(videoURL.lastPathComponent)")
        
        // Copy own video to Documents (persist)
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileName = "\(sessionID)_\(myPeerID.displayName).mov"
        let destinationURL = documentsPath.appendingPathComponent(fileName)
        
        #if DEBUG
        print("📹 [SessionManager] Copying to: \(destinationURL.path)")
        #endif
        
        do {
            // Remove existing file if exists
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
                #if DEBUG
                print("📹 [SessionManager] Removed existing file")
                #endif
            }
            
            // Copy file
            try FileManager.default.copyItem(at: videoURL, to: destinationURL)
            #if DEBUG
            print("✅ [SessionManager] Copied successfully")
            #endif
            
            // Record own video (save destination URL)
            let myDeviceName = myPeerID.displayName
            if recordedVideos[sessionID] == nil {
                recordedVideos[sessionID] = [:]
                #if DEBUG
                print("📹 [SessionManager] Created new session entry")
                #endif
            }
            recordedVideos[sessionID]?[myDeviceName] = destinationURL
            
            #if DEBUG
            print("📹 [SessionManager] Stored own video for \(myDeviceName)")
            print("📹 [SessionManager] Current video count for session: \(recordedVideos[sessionID]?.count ?? 0)")
            #endif
            
            // Send video to other devices (from original URL)
            #if DEBUG
            print("📹 [SessionManager] Starting video transfer to peers...")
            #endif
            sendVideoToAllPeers(videoURL: videoURL, sessionID: sessionID)
            
            // Check if all videos received
            checkAllVideosReceived(sessionID: sessionID)
            
        } catch {
            let errorMsg = "Copy error: \(error.localizedDescription)"
            addLog(errorMsg)
            #if DEBUG
            print("❌ [SessionManager] \(errorMsg)")
            print("❌ [SessionManager] Error details: \(error)")
            #endif
        }
        
        #if DEBUG
        print("📹 [SessionManager] =======================================================")
        #endif
    }
    
    /// 転送進捗のクリーンアップ
    private func cleanupTransferProgress() {
        receiveProgressObservation?.invalidate()
        receiveProgressObservation = nil
        transferProgressStartTime = nil
        sendProgressObservations.forEach { $0.invalidate() }
        sendProgressObservations.removeAll()
        transferProgress.removeAll()
        currentTransferProgress = 0
        transferETAString = ""
        isReceivingFile = false
    }
    
    /// ETA計算の更新
    private func updateTransferETA(fraction: Double) {
        guard fraction > 0.02, let startTime = transferProgressStartTime else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        let totalEstimated = elapsed / fraction
        let remaining = totalEstimated - elapsed
        
        // 残りファイル数を考慮した全体ETA
        let filesRemaining = totalExpectedFiles - receivedFiles
        let perFileTime = totalEstimated
        // 現在のファイルの残り + 残りファイル分の推定
        let totalRemaining = remaining + (Double(max(filesRemaining - 1, 0)) * perFileTime)
        
        if totalRemaining > 0 && totalRemaining < 3600 {
            let minutes = Int(totalRemaining) / 60
            let seconds = Int(totalRemaining) % 60
            if minutes > 0 {
                transferETAString = "About \(minutes)m \(seconds)s left"
            } else {
                transferETAString = "About \(seconds)s left"
            }
        }
    }
    
    /// Send video file to all peers
    private func sendVideoToAllPeers(videoURL: URL, sessionID: String) {
        guard let session = session else {
            #if DEBUG
            print("❌ [VideoTransfer] Session is nil")
            #endif
            return
        }
        
        let fileName = "\(sessionID)_\(myPeerID.displayName).mov"
        
        #if DEBUG
        print("📹 [VideoTransfer] ========== SENDING VIDEO ==========")
        print("📹 [VideoTransfer] Source: \(videoURL.path)")
        print("📹 [VideoTransfer] File exists: \(FileManager.default.fileExists(atPath: videoURL.path))")
        print("📹 [VideoTransfer] File name: \(fileName)")
        print("📹 [VideoTransfer] Peers count: \(connectedPeers.count)")
        #endif
        
        #if DEBUG
        if let fileSize = try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? UInt64 {
            print("📹 [VideoTransfer] File size: \(fileSize) bytes (\(Double(fileSize) / 1_000_000.0) MB)")
        }
        #endif
        
        DispatchQueue.main.async {
            self.isTransferring = true
            self.cleanupTransferProgress()  // 前回のデータをリセット
            // Use count determined at recording start (prevents value fluctuation due to disconnection during transfer)
            let expectedCount = self.sessionExpectedCounts[sessionID] ?? (self.connectedPeers.count + 1)
            self.totalExpectedFiles = expectedCount
            self.receivedFiles = 1  // Own file
            #if DEBUG
            print("📹 [VideoTransfer] Transfer state updated: \(self.receivedFiles)/\(self.totalExpectedFiles)")
            #endif
            
            // 転送タイムアウト（3分）: スタック防止
            self.transferTimeoutWork?.cancel()
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.isTransferring else { return }
                self.addLog("Transfer timeout – resetting transfer state")
                self.isTransferring = false
                self.cleanupTransferProgress()
                // タイムアウト後に全ファイル揃っていればプレビューへ遷移
                self.checkAllVideosReceived(sessionID: sessionID)
            }
            self.transferTimeoutWork = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: timeout)
        }
        
        for (index, peer) in connectedPeers.enumerated() {
            #if DEBUG
            print("📹 [VideoTransfer] [\(index+1)/\(connectedPeers.count)] Sending to: \(peer.displayName)")
            #endif
            
            // Use sendResource to transfer large files
            let sendProgress = session.sendResource(at: videoURL,
                                withName: fileName,
                                toPeer: peer) { error in
                if let error = error {
                    let errorMsg = "Send failed to \(peer.displayName): \(error.localizedDescription)"
                    self.addLog(errorMsg)
                    #if DEBUG
                    print("❌ [VideoTransfer] \(errorMsg)")
                    #endif
                } else {
                    let successMsg = "Sent to \(peer.displayName)"
                    self.addLog(successMsg)
                    #if DEBUG
                    print("✅ [VideoTransfer] \(successMsg)")
                    #endif
                }
            }
            
            // 送信進捗の監視
            if let sendProgress = sendProgress {
                let observation = sendProgress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        let fraction = progress.fractionCompleted
                        self.transferProgress[peer.displayName] = fraction
                        
                        // 受信中でなければ送信進捗を表示に使う
                        if !self.isReceivingFile {
                            self.currentTransferProgress = fraction
                            self.updateTransferETA(fraction: fraction)
                        }
                    }
                }
                DispatchQueue.main.async {
                    self.sendProgressObservations.append(observation)
                    // 送信開始時刻を記録（まだ未設定の場合）
                    if self.transferProgressStartTime == nil {
                        self.transferProgressStartTime = Date()
                    }
                }
            }
        }
        
        #if DEBUG
        print("📹 [VideoTransfer] ==========================================")
        #endif
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

            #if DEBUG
            print("📹 [VideoCheck] Session: \(sessionID)")
            print("📹 [VideoCheck] Expected: \(expectedCount), Got: \(videos.count)")
            print("📹 [VideoCheck] Videos: \(videos.keys.joined(separator: ", "))")

            for (device, url) in videos {
                let exists = FileManager.default.fileExists(atPath: url.path)
                print("📹 [VideoCheck] \(device): \(exists ? "✅" : "❌") \(url.path)")
            }
            #endif

            if videos.count >= expectedCount {
                self.addLog("All videos received for session: \(sessionID)")

                // Transfer complete flag
                self.isTransferring = false
                self.cleanupTransferProgress()
                self.transferTimeoutWork?.cancel()
                self.transferTimeoutWork = nil

                // Clear session expected count (release memory)
                self.sessionExpectedCounts.removeValue(forKey: sessionID)

                // ★ Set transition confirmed flag first
                self.isTransitioningToPreview = true

                // Set preview data
                self.previewSessionID = sessionID
                self.previewVideos = videos
                #if DEBUG
                print("📹 [VideoCheck] Showing preview with \(videos.count) videos")
                #endif

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
        // ★ MCSession デリゲートキュー（バックグラウンド）で即座に処理する
        // DispatchQueue.main.async に包むと、メインスレッドがデバッガー等でハングしている間に
        // MCSession 内部のハンドシェイクがタイムアウトして Connection refused になる
        let peerName = peerID.displayName
        
        #if DEBUG
        print("🔍 [MCSession] State change for \(peerName): \(state.rawValue)")
        #endif
        
        switch state {
        case .connected:
            #if DEBUG
            print("✅ [MCSession] CONNECTED to \(peerName)")
            #endif
            removeConnectingPeer(peerName)
            
            // ★ 接続確立時刻を記録（Hang 切断耐性用）— スレッドセーフ
            setConnectionTimestamp(peerName)
            
            // UI更新はメインスレッドで
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.connectedPeers.contains(where: { $0.displayName == peerName }) {
                    self.connectedPeers.append(peerID)
                }
                self.connectionState = .connected
                self.addLog("Connected: \(peerName)")
                
                // ★ 接続成功 → そのピアの outgoing 失敗カウンタをリセット
                self.outgoingFailuresPerPeer.removeValue(forKey: peerName)
                
                // リトライカウンタをクリア
                self.retryCounts.removeValue(forKey: peerName)
                if self.retryCounts.isEmpty { self.isRetrying = false }
                
                // マスターであれば新しく接続したピアに宣言を送る
                self.announceMasterRoleIfNeeded(to: peerID)
                
                // ★ 永続モード: スレーブ側で再接続したマスターを認識
                if self.persistentRole && !self.isMaster {
                    if peerName == self.persistentMasterName {
                        self.masterPeerID = peerID
                        self.addLog("Reconnected to persistent master: \(peerName)")
                    }
                }
                
                // ★ 永続モード: マスターが既にカメラ起動済みなら、再接続したスレーブに start_camera を送る
                if self.persistentRole && self.isMaster && self.isCameraReady {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        guard let self,
                              self.connectedPeers.contains(where: { $0.displayName == peerName }) else { return }
                        self.sendCameraStartCommand(to: peerID)
                        self.addLog("Resent start_camera to reconnected peer: \(peerName)")
                    }
                }
            }
            
        case .connecting:
            #if DEBUG
            print("🔄 [MCSession] CONNECTING to \(peerName)")
            #endif
            addConnectingPeer(peerName)
            
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.connectionState = .connecting
                self.addLog("Connecting: \(peerName)")
            }
            
        case .notConnected:
            #if DEBUG
            print("❌ [MCSession] NOT CONNECTED to \(peerName)")
            #endif
            
            // ★ MCSession の実際の connectedPeers を確認して、偽の切断通知を無視する
            if let currentSession = self.session,
               currentSession.connectedPeers.contains(where: { $0.displayName == peerName }) {
                self.addLog("Ignoring false disconnect for \(peerName) – still in session.connectedPeers")
                #if DEBUG
                print("⚠️ [MCSession] False disconnect ignored for \(peerName)")
                #endif
                return
            }
            
            // ★ 接続確立直後の切断を無視（デバッガ Hang によるキープアライブ途切れ対策）
            // connectionGracePeriod 以内の切断は、MCSession 内部の一時的な不安定として扱い、
            // 即座にリトライせず数秒待ってから再確認する
            let connectedAt = getConnectionTimestamp(peerName)
            if let ts = connectedAt, Date().timeIntervalSince(ts) < connectionGracePeriod {
                let elapsed = String(format: "%.1f", Date().timeIntervalSince(ts))
                DispatchQueue.main.async { [weak self] in
                    self?.addLog("Grace period: disconnect \(peerName) after \(elapsed)s – will re-check in 5s")
                }
                // 5秒後に本当に切断されているか再確認
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                    guard let self else { return }
                    if let s = self.session,
                       s.connectedPeers.contains(where: { $0.displayName == peerName }) {
                        self.addLog("Grace re-check: \(peerName) is still connected – ignoring")
                    } else if self.connectedPeers.contains(where: { $0.displayName == peerName }) {
                        // ローカルでは接続中だが MCSession では切断 → 本当の切断
                        self.addLog("Grace re-check: \(peerName) confirmed disconnected")
                        self.removeConnectionTimestamp(peerName)
                        self.connectedPeers.removeAll { $0.displayName == peerName }
                        self.handleConfirmedDisconnect(peerName: peerName, peerID: peerID)
                    }
                }
                return
            }
            
            removeConnectingPeer(peerName)
            removeConnectionTimestamp(peerName)
            
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // ★ outgoing 招待の失敗をカウント（ピアごと、passive モード判定用）
                //   ただし、自分から招待を送っていないピア（incoming accept のみ）の失敗はカウントしない
                //   相手の REBUILD/Hang による一時的な失敗で passive mode に入るのを防ぐ
                if self.invitedPeerNames.contains(peerName) {
                    let newCount = (self.outgoingFailuresPerPeer[peerName] ?? 0) + 1
                    self.outgoingFailuresPerPeer[peerName] = newCount
                    if newCount >= self.passiveModeThreshold {
                        self.addLog("Passive mode for \(peerName): \(newCount) consecutive failures – will only accept incoming invites")
                    }
                }
                self.connectedPeers.removeAll { $0.displayName == peerName }
                self.handleConfirmedDisconnect(peerName: peerName, peerID: peerID)
            }
            
        @unknown default:
            #if DEBUG
            print("⚠️ [MCSession] Unknown state for \(peerName)")
            #endif
            break
        }
    }
    
    /// Data received
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        // バイナリプレフィックスで分岐: 0x01 = スナップショット, それ以外 = JSONコマンド
        if let firstByte = data.first, firstByte == 0x01 {
            handleReceivedSnapshot(data)
        } else {
            handleReceivedCommand(data, from: peerID)
        }
    }
    
    /// Stream received (not used)
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        // Not used
    }
    
    /// Resource receive started
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        addLog("Receiving: \(resourceName) from \(peerID.displayName)")
        
        // 受信進捗の監視開始
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isReceivingFile = true
            self.transferProgressStartTime = Date()
            self.currentTransferProgress = 0
            self.transferETAString = ""
            
            // KVO で fractionCompleted を監視（受信は送信より優先）
            self.receiveProgressObservation?.invalidate()
            self.receiveProgressObservation = progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let fraction = progress.fractionCompleted
                    self.currentTransferProgress = fraction
                    self.transferProgress[peerID.displayName] = fraction
                    self.updateTransferETA(fraction: fraction)
                }
            }
        }
    }
    
    /// Resource receive completed
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        DispatchQueue.main.async { [weak self] in
            self?.isReceivingFile = false
            self?.receiveProgressObservation?.invalidate()
            self?.receiveProgressObservation = nil
        }
        
        #if DEBUG
        print("📹 [VideoReceive] ========== RECEIVED RESOURCE ==========")
        print("📹 [VideoReceive] From: \(peerID.displayName)")
        print("📹 [VideoReceive] Resource name: \(resourceName)")
        print("📹 [VideoReceive] Local URL: \(localURL?.path ?? "nil")")
        #endif
        
        if let error = error {
            let errorMsg = "Receive error: \(error.localizedDescription)"
            addLog(errorMsg)
            #if DEBUG
            print("❌ [VideoReceive] \(errorMsg)")
            #endif
            return
        }
        
        guard let localURL = localURL else {
            addLog("No URL received")
            #if DEBUG
            print("❌ [VideoReceive] localURL is nil")
            #endif
            return
        }
        
        #if DEBUG
        print("📹 [VideoReceive] File exists at localURL: \(FileManager.default.fileExists(atPath: localURL.path))")
        
        if let fileSize = try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? UInt64 {
            print("📹 [VideoReceive] File size: \(fileSize) bytes (\(Double(fileSize) / 1_000_000.0) MB)")
        }
        #endif
        
        // Extract SessionID and device name from filename
        // Filename format: SessionID_DeviceName.mov
        let fileName = resourceName.replacingOccurrences(of: ".mov", with: "")
        let components = fileName.split(separator: "_")
        
        guard components.count >= 2 else {
            addLog("Invalid filename format: \(resourceName)")
            #if DEBUG
            print("❌ [VideoReceive] Invalid filename format")
            #endif
            return
        }
        
        let sessionID = String(components[0])
        let deviceName = components.dropFirst().joined(separator: "_")
        
        #if DEBUG
        print("📹 [VideoReceive] Extracted SessionID: '\(sessionID)'")
        print("📹 [VideoReceive] Extracted DeviceName: '\(deviceName)'")
        #endif
        
        // ★ ファイル I/O を専用キューで実行し、MCSession の内部デリゲートキューをブロックしない
        // デリゲートキューが詰まるとキープアライブが途切れて接続が切断される
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destinationURL = documentsPath.appendingPathComponent(resourceName)
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            
            #if DEBUG
            print("📹 [VideoReceive] Moving to: \(destinationURL.path)")
            #endif
            
            do {
                // Remove existing file if exists
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                
                // ★ copyItem → moveItem に変更（同一ボリューム内はほぼ瞬時）
                try FileManager.default.moveItem(at: localURL, to: destinationURL)
                
                self.addLog("Received: \(resourceName)")
                #if DEBUG
                print("✅ [VideoReceive] File moved successfully")
                #endif
                
                // Record received video, update count, check if all received - on main thread
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }

                    // ★ Failsafe: If still recording when master video arrives, force stop
                    if self.cameraManager?.isRecording == true && !self.isMaster {
                        #if DEBUG
                        print("⚠️ [VideoReceive] Received master video but still recording – force stopping")
                        #endif
                        self.addLog("Force stop: stop_recording was not received in time")
                        self.handleStopRecording()
                    }

                    if self.recordedVideos[sessionID] == nil {
                        self.recordedVideos[sessionID] = [:]
                    }
                    self.recordedVideos[sessionID]?[deviceName] = destinationURL

                    #if DEBUG
                    print("📹 [VideoReceive] Stored video for device: \(deviceName)")
                    print("📹 [VideoReceive] Current video count: \(self.recordedVideos[sessionID]?.count ?? 0)")
                    #endif

                    self.receivedFiles += 1
                    #if DEBUG
                    print("📹 [VideoReceive] Updated received count: \(self.receivedFiles)/\(self.totalExpectedFiles)")
                    #endif

                    self.checkAllVideosReceived(sessionID: sessionID)
                }
                
            } catch {
                let errorMsg = "Save error: \(error.localizedDescription)"
                self.addLog(errorMsg)
                #if DEBUG
                print("❌ [VideoReceive] \(errorMsg)")
                #endif
            }
        }
        
        #if DEBUG
        print("📹 [VideoReceive] ==========================================")
        #endif
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension CameraSessionManager: MCNearbyServiceAdvertiserDelegate {
    /// When invitation received
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // ★ MCSession のデリゲートキュー（バックグラウンド）で即座に処理する
        // メインスレッドへの dispatch を挟むと、Hang 中に invitationHandler の応答が遅れ、
        // 相手側の接続試行がタイムアウトする
        let peerName = peerID.displayName
        
        addLog("Invitation from \(peerName)")
        
        // セッションが nil なら拒否（fullRestart の途中で届いた古い招待）
        guard let currentSession = session else {
            addLog("Rejected: session is nil (restarting)")
            invitationHandler(false, nil)
            return
        }
        
        // ★ MCSession の内部状態で接続済みチェック（スレッドセーフ）
        //    ただし、MCSession の connectedPeers にいるピアの PeerID と招待元の PeerID が異なる場合は
        //    相手が REBUILD/再起動した可能性が高い → stale 接続を無視して受け入れる
        let sessionConnected = currentSession.connectedPeers.first(where: { $0.displayName == peerName })
        if let existingPeer = sessionConnected, existingPeer == peerID {
            addLog("Rejected: \(peerName) already in session.connectedPeers (same PeerID)")
            invitationHandler(false, nil)
            return
        }
        if sessionConnected != nil {
            // 異なる PeerID で招待が来た → 相手が再起動した。古い接続は stale なので受け入れる
            addLog("Invitation from \(peerName) with new PeerID – accepting (old connection is stale)")
            DispatchQueue.main.async { [weak self] in
                self?.connectedPeers.removeAll { $0.displayName == peerName }
                self?.removeConnectionTimestamp(peerName)
            }
        }
        
        // ★ CONNECTING チェックを廃止:
        // 自分からの outgoing invite が CONNECTING 状態でも、相手からの incoming invite を受け入れる。
        // Connection refused で outgoing が失敗しても、incoming は成功する可能性が高い。
        // MCSession は内部で重複接続を処理するため、両方 accept しても問題ない。
        
        // ★ accept と同時に connectingPeerNames に追加（スレッドセーフ）
        addConnectingPeer(peerName)
        invitationHandler(true, currentSession)
        addLog("Accepted: \(peerName)")
    }
    
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        addLog("Advertise failed: \(error.localizedDescription)")
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension CameraSessionManager: MCNearbyServiceBrowserDelegate {
    /// When peer discovered
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        DispatchQueue.main.async {
            let peerName = peerID.displayName
            
            guard peerName != self.myPeerID.displayName else { return }
            
            // displayName ベースで重複チェック（MCPeerID はインスタンスが毎回異なるため参照比較は無効）
            // ★ REBUILD で MCPeerID が変わった場合は古いエントリを差し替え、招待状態もリセット
            let existingIndex = self.availablePeers.firstIndex(where: { $0.displayName == peerName })
            if let idx = existingIndex {
                let oldPeer = self.availablePeers[idx]
                if oldPeer != peerID {
                    // PeerID が変わった → 相手が REBUILD した（Xcode REBUILD やアプリ再起動）
                    self.availablePeers[idx] = peerID
                    self.invitedPeerNames.remove(peerName)
                    self.removeConnectingPeer(peerName)
                    self.outgoingFailuresPerPeer.removeValue(forKey: peerName)
                    
                    // ★ 相手が REBUILD した場合、connectedPeers に古い PeerID が残っている可能性がある
                    //    新しい PeerID で発見されたということは、旧プロセスは確実に終了している
                    //    → stale な接続状態を即座にクリアして、新しい接続を受け入れる
                    if self.connectedPeers.contains(where: { $0.displayName == peerName }) {
                        self.connectedPeers.removeAll { $0.displayName == peerName }
                        self.removeConnectionTimestamp(peerName)
                        self.addLog("Evicted stale connection for \(peerName) – peer restarted with new PeerID")
                        
                        // 接続ピアがゼロになった場合の状態更新
                        if self.connectedPeers.isEmpty {
                            self.connectionState = .connecting
                        }
                    }
                    
                    self.addLog("Peer re-appeared with new ID: \(peerName) – reset invite state")
                } else {
                    return  // 同じ PeerID → 重複なので無視
                }
            } else {
                // ★ 新規ピアでも、connectedPeers に同名の古い PeerID が残っていたらクリア
                //    （availablePeers から消えた後に再発見された場合）
                if self.connectedPeers.contains(where: { $0.displayName == peerName }) {
                    self.connectedPeers.removeAll { $0.displayName == peerName }
                    self.removeConnectionTimestamp(peerName)
                    self.invitedPeerNames.remove(peerName)
                    self.removeConnectingPeer(peerName)
                    self.outgoingFailuresPerPeer.removeValue(forKey: peerName)
                    self.addLog("Evicted stale connection for \(peerName) – rediscovered as new peer")
                    
                    if self.connectedPeers.isEmpty {
                        self.connectionState = .connecting
                    }
                }
                self.availablePeers.append(peerID)
            }
            
            // ★ 相手の discoveryInfo からスコアを取得・保存
            let peerScore = Int(info?["score"] ?? "") ?? 0
            self.peerScores[peerName] = peerScore
            self.addLog("Found: \(peerName) (score=\(peerScore), mine=\(self.deviceScore))")
            
            // ★ イベント駆動: ピア発見 → 即座に招待判定（ディレイなし）
            let alreadyConnected = self.connectedPeers.contains(where: { $0.displayName == peerName })
            guard !alreadyConnected else { return }
            
            let alreadyInvited = self.invitedPeerNames.contains(peerName)
            guard !alreadyInvited else { return }
            self.invitedPeerNames.insert(peerName)
            
            // Passive mode: そのピアへの outgoing が連続失敗したら受け身に徹する
            let peerFailures = self.outgoingFailuresPerPeer[peerName] ?? 0
            if peerFailures >= self.passiveModeThreshold {
                self.addLog("Passive mode: waiting for \(peerName) to invite us (failures=\(peerFailures))")
                // 安全弁: 10秒後に接続できていなければ passive mode を解除
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                    guard let self else { return }
                    guard !self.connectedPeers.contains(where: { $0.displayName == peerName }) else { return }
                    if let s = self.session, s.connectedPeers.contains(where: { $0.displayName == peerName }) { return }
                    self.outgoingFailuresPerPeer.removeValue(forKey: peerName)
                    self.invitedPeerNames.remove(peerName)
                    self.addLog("Passive mode timeout for \(peerName) – resetting to active mode")
                    self.performLightweightRestart()
                }
                return
            }
            
            // ★ スコア比較: 高い方が initiator（招待を送る側）
            let iAmInitiator: Bool
            if self.deviceScore != peerScore {
                iAmInitiator = self.deviceScore > peerScore
            } else {
                iAmInitiator = self.myPeerID.displayName > peerName
            }
            
            if iAmInitiator {
                // ★ initiator: 即座に招待を送る（ディレイなし）
                self.invitePeer(peerID)
            } else {
                // ★ responder: 相手（initiator）からの招待を待つ
                // 安全弁: 10秒以内に招待が来なければ自分から送る
                self.addLog("Lower score – waiting for \(peerName) to invite us")
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                    guard let self else { return }
                    guard !self.connectedPeers.contains(where: { $0.displayName == peerName }) else { return }
                    if let s = self.session, s.connectedPeers.contains(where: { $0.displayName == peerName }) { return }
                    guard !self.isConnectingPeerFresh(peerName) else { return }
                    guard (self.outgoingFailuresPerPeer[peerName] ?? 0) < self.passiveModeThreshold else { return }
                    self.addLog("Fallback: no invite from \(peerName) after 10s – sending our own")
                    self.invitePeer(peerID)
                }
            }
        }
    }
    
    /// When peer lost
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            let peerName = peerID.displayName
            self.availablePeers.removeAll { $0.displayName == peerName }
            self.invitedPeerNames.remove(peerName)
            // ★ CONNECTING 状態もクリア（次の foundPeer で即座に再招待できるようにする）
            self.removeConnectingPeer(peerName)
            self.addLog("Peer lost: \(peerName)")
        }
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        addLog("Browse failed: \(error.localizedDescription)")
    }
}
