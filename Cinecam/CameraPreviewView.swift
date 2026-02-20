//
//  CameraPreviewView.swift
//  Cinecam
//
//  Phase 2: カメラプレビュー表示
//

import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView(previewLayer: previewLayer)
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // プレビューレイヤーが変更された場合のみ更新
        if uiView.previewLayer !== previewLayer {
            uiView.updatePreviewLayer(previewLayer)
        }
        
        // フレームを即座に更新
        if uiView.bounds != .zero {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = uiView.bounds
            CATransaction.commit()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject {}
    
    // カスタムUIView
    class PreviewUIView: UIView {
        private(set) var previewLayer: AVCaptureVideoPreviewLayer
        
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
        }
    }
}
