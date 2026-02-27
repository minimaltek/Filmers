# Cinecam 更新ログ

---

## 2026-02-28

### レンズセレクター修正
- **マルチカメラ仮想デバイス除外**: `availableBackCameras()` から `builtInTripleCamera`/`builtInDualCamera`/`builtInDualWideCamera` を除外し、物理カメラ（ultraWide, wideAngle, telephoto）のみ返すよう修正
- 仮想デバイスの zoomLabel が "1×" になり、本物の wideAngleCamera が重複排除で消えていたのが根本原因

### START CAMERA / AWAITING UI重複解消
- `masterControlView`: ステータスHStack（`● WAITING...`）を削除し、待機状態をボタン内に統合。待機中は `ProgressView` スピナーを表示
- `slaveWaitingView`: 冗長なステータスHStackを削除

### 編集タイムライン強化
- **セグメント選択優先度**: `enforceExclusivity()` に `priorityDevice` 引数を追加。操作中のデバイスのセグメントが常に優先されるよう変更
- **iPad単一シーケンス問題**: `handleDeviceTap` 内の `commitAllSegments(for: prev)` を削除。デバイス切替時に前デバイスの優先度が復活してしまうバグを修正
- **iPadセグメントタップ不可**: ZStack上の長押し `DragGesture` を背景 `thumbnailStrip` レイヤーに移動し、上層のセグメント・トリムハンドルのジェスチャーが優先されるよう修正

### 再生ヘッド位置修正
- `effectiveTrackWidth` プロパティを導入。`scaledTrackWidth` からパディングを差し引いた値を使用し、再生ヘッドがトリム位置と正確に一致するよう修正
- トリムハンドルドラッグ中は、raw ドラッグ位置ではなく実際のクランプ済み trimIn/trimOut 値を再生ヘッドに反映

### ライブラリUI改善
- セッション行にAVAssetImageGeneratorによるサムネイル（64×48）を追加
- Select モード追加: チェックボックスで複数選択→一括削除機能
- 「ライブラリ」タイトルと EditButton を削除（スワイプ削除で十分）

### カメラUI整理
- 解像度/FPSバッジ（HD 30）を削除
- フロント/バックカメラトグルをレンズセレクター横に移動
- 録画中カウントアップタイマーを縮小（size 48→28, circle 12→8）

### その他
- `CameraControlPanel.swift` 削除（未使用の孤立コード）
- デバッグ用 print ログを削除

### 変更ファイル
- `CameraUtilities.swift` — マルチカメラ仮想デバイス除外
- `ContentView.swift` — START CAMERA/AWAITING UI重複解消
- `CameraOverlayControls.swift` — レンズセレクター修正、UI配置変更、解像度バッジ削除
- `CinecamExclusiveEditTimeline.swift` — enforceExclusivity に priorityDevice 追加
- `Previewview .swift` — ジェスチャー競合修正、再生ヘッド修正、トリムハンドル改善
- `LibraryView.swift` — サムネイル、Select モード、UI整理
- `CameraManager.swift` — orientation ヘルパー追加
- `CameraSessionManager.swift` — カメラ起動タイミング制御
- `CameraControlPanel.swift` — 削除

---

## 2026-02-25 セッション2

### MultipeerConnectivity 接続安定化
- **招待衝突の解消**: 名前の辞書順で優先度を決定し、片方のみが招待を送信するよう変更
- **fullRestart パターン導入**: MCSession + Advertiser + Browser を完全に再生成するリトライ機構を実装
- **リトライロジック**: 接続失敗時に最大5回、バックオフ付き（1.5s, 3s, 4.5s...）で再接続を試行
- **招待送信遅延**: ピア発見後0.5秒の遅延を設けて安定性を向上

### UI フロー改善
- **プレビュー後の画面遷移**: プレビュー終了後は roleSelectionScreen（MASTER ボタン画面）に戻るよう変更
- **マスターアナウンス時のスレーブ自動遷移**: マスターが次の撮影準備を始めたら、スレーブ側のプレビュー/編集画面を自動で閉じて AWAIT 画面に遷移
- **pendingMasterAnnouncement フラグ**: マスターコマンドによるプレビュー終了時にロールがリセットされない制御を追加
- **スレーブ自動遷移の条件強化**: `masterPeerID` 設定済み AND `connectedPeers` が空でないことを両方チェック
- **MASTER ボタン表示条件**: 接続ピアがいない場合は AWAITING カードを表示、接続ピアがいる場合のみ MASTER ボタンを表示
- **START CAMERA ボタン無効化**: 接続ピアがいない場合はボタンを無効化し「NO NODES CONNECTED」を表示

### iPad レイアウト対応
- `maxContentWidth: 420` を追加し、iPad でもiPhone縦画面と同等の幅で中央配置
- roleSelectionScreen と mainScreen の両方に適用

### デザイン統一
- **CINECAM. ロゴフォント**: `.system(size: 32, weight: .black)` + `.fontWidth(.compressed)` + `.tracking(-0.5)` に変更
- roleSelectionScreen と mainScreen の両ヘッダーで統一

### 変更ファイル
- `ContentView.swift` — UI全画面の変更（レイアウト、フォント、画面遷移ロジック）
- `CameraSessionManager.swift` — 接続ロジック全般（fullRestart、リトライ、招待制御、pendingMasterAnnouncement）

---

## 2026-02-25 セッション1

### リファクタリング
- 共通ユーティリティ作成（CameraUtilities.swift, FrameLayout.swift, DesignConstants.swift）
- コード重複の削除（プレビュー判定、時間フォーマット、カメラ切替ロジック等）
- FrameSetView の改善（Close ボタン修正、ハードコード削除）
- 詳細は `REFACTORING_REPORT.md` を参照

### デザインリニューアル
- roleSelectionScreen を SF/ミリタリー風のダークUIにリデザイン
- 全画面（masterControlView, slaveWaitingView, transferProgressView）のデザインを統一
- ログ表示からemoji を除去、モノクロアイコンに変更
- Canvas Preview サポートを追加
