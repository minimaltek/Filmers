//
//  CameraPreviewView.swift
//  Douki
//
//  Phase 2: カメラプレビュー表示
//

import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer
    /// 端末回転時にプレビュー・録画のorientationを更新するためのCameraManager参照
    var cameraManager: CameraManager?

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView(previewLayer: previewLayer)
        view.backgroundColor = .black
        view.cameraManager = cameraManager
        // 端末回転の通知を監視
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.orientationDidChange(_:)),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        context.coordinator.view = view
        context.coordinator.cameraManager = cameraManager
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // プレビューレイヤーが変更された場合のみ更新
        if uiView.previewLayer !== previewLayer {
            uiView.updatePreviewLayer(previewLayer)
        }
        uiView.cameraManager = cameraManager
        context.coordinator.cameraManager = cameraManager
        
        // フレームを即座に更新
        if uiView.bounds != .zero {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = uiView.bounds
            CATransaction.commit()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject {
        weak var view: PreviewUIView?
        weak var cameraManager: CameraManager?
        
        @objc func orientationDidChange(_ notification: Notification) {
            // 端末の向きが変わったら、プレビュー・録画接続のorientationを更新
            cameraManager?.updateOrientationForConnections()
            
            // 回転後にプレビューレイヤーのフレームを強制的に再設定
            // （SwiftUIのレイアウトサイクルとの競合でフレームがずれることがある）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let view = self?.view else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                view.previewLayer.frame = view.bounds
                CATransaction.commit()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let view = self?.view else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                view.previewLayer.frame = view.bounds
                CATransaction.commit()
            }
        }
        
        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
    
    // カスタムUIView
    class PreviewUIView: UIView {
        private(set) var previewLayer: AVCaptureVideoPreviewLayer
        weak var cameraManager: CameraManager?
        
        init(previewLayer: AVCaptureVideoPreviewLayer) {
            self.previewLayer = previewLayer
            super.init(frame: .zero)
            layer.addSublayer(previewLayer)
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        func updatePreviewLayer(_ newLayer: AVCaptureVideoPreviewLayer) {
            previewLayer.removeFromSuperlayer()
            previewLayer = newLayer
            layer.addSublayer(previewLayer)
            layoutSubviews()
        }
        
        override func layoutSubviews() {
            super.layoutSubviews()
            // レイアウト変更時に必ずフレームを更新
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            CATransaction.commit()
            
            // SwiftUIのレイアウト完了後にもう一度フレームを合わせる
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.previewLayer.frame != self.bounds {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.previewLayer.frame = self.bounds
                    CATransaction.commit()
                }
            }
        }
    }
}
