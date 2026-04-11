//
//  MultiCamPreviewView.swift
//  Cinecam
//
//  Dual-camera preview: active camera full-screen + inactive camera PiP
//  Uses a single UIViewRepresentable to avoid CALayer hierarchy issues
//

import SwiftUI
import AVFoundation

struct MultiCamPreviewView: UIViewRepresentable {
    let backPreviewLayer: AVCaptureVideoPreviewLayer
    let frontPreviewLayer: AVCaptureVideoPreviewLayer
    /// 現在操作中のカメラ（メイン表示になる）
    var activePosition: AVCaptureDevice.Position = .back
    /// オリエンテーション更新用 & PiPタップ切替用
    var multiCamManager: MultiCamManager
    
    func makeCoordinator() -> Coordinator {
        Coordinator(multiCamManager: multiCamManager)
    }
    
    func makeUIView(context: Context) -> DualPreviewUIView {
        let view = DualPreviewUIView(
            backLayer: backPreviewLayer,
            frontLayer: frontPreviewLayer
        )
        view.backgroundColor = .black
        view.updateActivePosition(activePosition)
        view.onPipTapped = { [weak multiCamManager] in
            multiCamManager?.switchActiveCamera()
        }
        
        // 端末回転の通知を監視
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.orientationDidChange(_:)),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        context.coordinator.view = view
        
        return view
    }
    
    func updateUIView(_ uiView: DualPreviewUIView, context: Context) {
        // レイヤーが変わった場合は再設定
        if uiView.backLayer !== backPreviewLayer || uiView.frontLayer !== frontPreviewLayer {
            uiView.replaceLayers(back: backPreviewLayer, front: frontPreviewLayer)
        }
        uiView.updateActivePosition(activePosition)
    }
    
    // MARK: - Coordinator
    
    class Coordinator: NSObject {
        weak var view: DualPreviewUIView?
        let multiCamManager: MultiCamManager
        
        init(multiCamManager: MultiCamManager) {
            self.multiCamManager = multiCamManager
        }
        
        @objc func orientationDidChange(_ notification: Notification) {
            // 録画・プレビュー接続のorientationを更新
            multiCamManager.updateOrientationForConnections()
            
            // レイアウト更新
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.view?.setNeedsLayout()
                self?.view?.layoutIfNeeded()
            }
        }
    }
}

// MARK: - Dual Preview UIView

/// 2つのAVCaptureVideoPreviewLayerを直接管理するUIView
/// activePositionに応じてメイン（フルスクリーン）とPiP（右上小窓）を切り替え
class DualPreviewUIView: UIView {
    private(set) var backLayer: AVCaptureVideoPreviewLayer
    private(set) var frontLayer: AVCaptureVideoPreviewLayer
    private var currentActivePosition: AVCaptureDevice.Position = .back
    
    // PiP settings
    private let pipWidth: CGFloat = 120
    private let pipHeight: CGFloat = 160
    private let pipCornerRadius: CGFloat = 12
    
    // PiP border layer
    private let pipBorderLayer = CAShapeLayer()
    
    /// PiPタップ時のコールバック（カメラ切替）
    var onPipTapped: (() -> Void)?
    
    /// 現在の PiP フレーム（タップ判定用）
    private var currentPipFrame: CGRect = .zero
    
    init(backLayer: AVCaptureVideoPreviewLayer, frontLayer: AVCaptureVideoPreviewLayer) {
        self.backLayer = backLayer
        self.frontLayer = frontLayer
        super.init(frame: .zero)
        
        backLayer.videoGravity = .resizeAspectFill
        frontLayer.videoGravity = .resizeAspectFill
        
        // Add both layers — order will be set by updateActivePosition
        layer.addSublayer(backLayer)
        layer.addSublayer(frontLayer)
        
        // PiP border（黒フレームで角丸の隙間を隠す）
        pipBorderLayer.fillColor = UIColor.black.cgColor
        pipBorderLayer.strokeColor = UIColor.clear.cgColor
        pipBorderLayer.lineWidth = 0
        layer.addSublayer(pipBorderLayer)
        
        // PiPタップ用ジェスチャー
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        // PiP エリア内タップならカメラ切替
        if currentPipFrame.contains(point) {
            onPipTapped?()
        }
    }
    
    func replaceLayers(back: AVCaptureVideoPreviewLayer, front: AVCaptureVideoPreviewLayer) {
        backLayer.removeFromSuperlayer()
        frontLayer.removeFromSuperlayer()
        
        self.backLayer = back
        self.frontLayer = front
        
        back.videoGravity = .resizeAspectFill
        front.videoGravity = .resizeAspectFill
        
        layer.addSublayer(back)
        layer.addSublayer(front)
        
        // Keep border on top
        pipBorderLayer.removeFromSuperlayer()
        layer.addSublayer(pipBorderLayer)
        
        updateActivePosition(currentActivePosition)
        setNeedsLayout()
    }
    
    func updateActivePosition(_ position: AVCaptureDevice.Position) {
        let changed = currentActivePosition != position
        currentActivePosition = position
        if changed {
            setNeedsLayout()
            layoutIfNeeded()
        }
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        let mainLayer: AVCaptureVideoPreviewLayer
        let pipLayer: AVCaptureVideoPreviewLayer
        
        if currentActivePosition == .back {
            mainLayer = backLayer
            pipLayer = frontLayer
        } else {
            mainLayer = frontLayer
            pipLayer = backLayer
        }
        
        // Main: full-screen
        mainLayer.frame = bounds
        mainLayer.cornerRadius = 0
        mainLayer.masksToBounds = false
        
        // PiP: 右端寄せ（セーフエリア分だけマージン確保）
        let isLandscape = bounds.width > bounds.height
        let pipTrailing: CGFloat = isLandscape ? 16 : 16
        let pipTop: CGFloat = isLandscape ? 16 : 60
        let pipX = bounds.width - pipWidth - pipTrailing
        let pipY = pipTop
        let pipFrame = CGRect(x: pipX, y: pipY, width: pipWidth, height: pipHeight)
        pipLayer.frame = pipFrame
        pipLayer.cornerRadius = pipCornerRadius
        pipLayer.masksToBounds = true
        currentPipFrame = pipFrame
        
        // PiP border: 角丸の隙間を確実に覆うため、外枠パスから内枠パスを切り抜いたフレーム型にする
        let outerInset: CGFloat = -6  // 外側に6pt広げる
        let outerRect = pipFrame.insetBy(dx: outerInset, dy: outerInset)
        let outerPath = UIBezierPath(roundedRect: outerRect, cornerRadius: pipCornerRadius + abs(outerInset))
        // 内枠を1pt内側に縮めて角丸の隙間を確実に覆う
        let innerRect = pipFrame.insetBy(dx: 1, dy: 1)
        let innerPath = UIBezierPath(roundedRect: innerRect, cornerRadius: pipCornerRadius - 1)
        outerPath.append(innerPath.reversing())
        pipBorderLayer.path = outerPath.cgPath
        pipBorderLayer.fillColor = UIColor.black.cgColor
        pipBorderLayer.strokeColor = UIColor.clear.cgColor
        pipBorderLayer.lineWidth = 0
        pipBorderLayer.frame = bounds
        
        // Z-order: main behind, pip on top, border on very top
        mainLayer.zPosition = 0
        pipLayer.zPosition = 1
        pipBorderLayer.zPosition = 2
        
        CATransaction.commit()
    }
}
