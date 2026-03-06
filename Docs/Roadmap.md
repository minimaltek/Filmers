# Cinecam ロードマップ & 技術設計

## コンセプト
> 「その場にいる全員のデバイスがカメラになる」→「世界中の友達と同時撮影できる」

---

## フェーズ別ロードマップ

### ✅ Phase 1–3（完了）
- 複数iPhone間の同期録画（MultipeerConnectivity）
- マルチアングルプレビュー
- CapCutスタイルタイムラインUI

### 🔧 Phase 4a（次のステップ）：RTSP受信MVP
- VideoToolboxでH.264 RTSPデコード動作確認
- IP Webcam（Android）の映像をiPhoneで表示

### 🔧 Phase 4b：タイムライン統合
- CinecamタイムラインにRTSPストリームを追加
- RTPタイムスタンプ同期

### 🔧 Phase 4c：UX改善
- mDNS（Bonjour）による自動デバイス検出
- QRコードフォールバック
- 参加者向けガイドUI

### 🚀 Phase 5：リモートセッション
- WebRTCによるインターネット越し同時撮影
- 遠隔地の友達をセッションに追加
- シグナリングサーバー構築（Agora / Twilio等）

---

## RTSP技術設計

### デコードライブラリ選定

| | MobileVLCKit | VideoToolbox直接 |
|---|---|---|
| 実装コスト | 低 | 高 |
| AppStore | ⚠️ LGPL問題あり | ✅ 問題なし |
| 安定性 | 高 | 中 |
| 遅延 | 中（300ms前後） | 低（100ms以下） |

**→ 結論：VideoToolbox直接実装**

### 接続方式

| 方式 | UX | 実装コスト |
|---|---|---|
| 手動IP入力 | ❌ 最悪 | 低 |
| QRコード | △ 一手間 | 低 |
| mDNS自動検出 | ✅ 最高 | 中 |

**→ 結論：mDNS自動検出 ＋ QRコードをフォールバック**

### ストリーム受信パイプライン

```
[Android IP Webcam]
    ↓ RTSP over TCP/UDP
[RTSPクライアント（Swift）]
    ↓ RTPパケット受信
[H.264 ナルユニット抽出]
    ↓
[VideoToolbox デコード]
    ↓ CVPixelBuffer
[AVSampleBufferDisplayLayer]
    ↓
[Cinecam タイムラインに統合]
```

### IP Webcam 推奨設定（ユーザー向けガイド内に表示）

```
解像度: 1280x720
FPS: 30
コーデック: H.264
ポート: 8080（デフォルト）
認証: なし（ローカルのみ）
RTSP URL: rtsp://192.168.x.x:8080/h264_ulaw.sdp
```

### タイムスタンプ同期

```swift
// RTPタイムスタンプをCinecamのマスタークロックに同期
let rtpTimestamp: UInt32 = packet.timestamp
let masterClock = CinecamSyncEngine.shared.masterTime
let offset = masterClock - rtpTimestamp.toSeconds()
```

---

## 接続デバイス対応表

| デバイス | 接続方式 | 条件 |
|---|---|---|
| iPhone（Cinecamスレーブ） | MultipeerConnectivity | 同一ネットワーク不要 |
| Android（IP Webcam） | RTSP | 同一Wi-Fi必須 or ホットスポット |
| 家庭用IPカメラ（Reolink等） | RTSP | 同一Wi-Fi必須 |
| リモート参加（Phase 5） | WebRTC | インターネット接続 |

---

## 収益設計

### 価格プラン（欧米含む想定）

| プラン | 価格 | 内容 |
|---|---|---|
| 無料 | $0 | 透かしあり・ローカル2台まで |
| Pro | $4.99 | 透かしなし・ローカル無制限 |
| Team | $9.99 | Pro ＋ RTSPカメラ ＋ リモートセッション |

### 目標：月30万円

```
$4.99（約750円）× 400人 = 約30万円
$9.99（約1,500円）× 200人 = 約30万円
```

### StoreKit 2 実装

```swift
import StoreKit

func checkProStatus() async -> Bool {
    for await result in Transaction.currentEntitlements {
        if case .verified(let transaction) = result {
            if transaction.productID == "com.cinecam.pro" {
                return true
            }
        }
    }
    return false
}

// 機能制限
class ProManager {
    static let shared = ProManager()
    var isPro: Bool = false
}

// 透かし制御
if ProManager.shared.isPro {
    // 透かしなしで録画
} else {
    // 透かしを合成して録画
}

// 台数制限
let maxDevices = ProManager.shared.isPro ? 999 : 2
```

---

## リリース計画

```
今週
  └ 確定申告完了
  └ Pixel（メルカリ）届く
  └ IP Webcamアプリ動作確認

来週
  └ CinecamにRTSP受信実装（Phase 4a）
  └ TestFlightビルド作成

再来週
  └ 5人にTestFlight配布
  └ フィードバック収集

その後
  └ StoreKit実装（Pro版）
  └ App Store申請
  └ Google Play登録（$25 / 約¥3,800・買い切り）
  └ Androidカメラ参加アプリ作成（Flutter）
```

---

## ストア展開

### App Store（iOS）
- 登録費：¥11,800 / 年（既存）
- 対象：日本・欧米

### Google Play（Android）
- 登録費：$25（約¥3,800）**買い切り・年会費なし**
- 対象：Androidカメラ参加アプリのみ（軽量Flutter製）
- GRNTSと同一アカウントで管理可能

---

## Phase 5 WebRTC設計メモ

```
iPhone A（東京）
    ↓ WebRTC
  シグナリングサーバー
    ↓ WebRTC
iPhone B（大阪・海外etc）
```

### サービス候補

| サービス | 特徴 | コスト |
|---|---|---|
| Agora | 実績多・SDK充実 | 従量課金 |
| Twilio | 安定・日本語サポートあり | 従量課金 |
| 自前構築 | 自由度高い | サーバー費のみ |

### 月額コスト目安

| 規模 | 月額 |
|---|---|
| テスト・少人数 | ほぼ無料 |
| 100人同時 | 約¥3,000〜 |
| 1,000人同時 | 約¥30,000〜 |
