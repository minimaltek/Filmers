//
//  MetalPreviewRenderer.swift
//  Filmers
//
//  Metal ベースのプレビューレンダリング。
//  AVPlayerItemVideoOutput からフレームを取得し、CIFilter 適用後に MTKView に描画する。
//  全フレームが必ずフィルタパイプラインを通過するため、seek 直後のエフェクト抜けが発生しない。
//

import Foundation
import AVFoundation
import MetalKit
import CoreImage

// MARK: - MetalPreviewRenderer

final class MetalPreviewRenderer: NSObject, MTKViewDelegate {

    // MARK: Metal Pipeline

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext

    // MARK: Video Output

    /// デバイスごとの AVPlayerItemVideoOutput（フレーム取得用）
    private var videoOutputs: [String: AVPlayerItemVideoOutput] = [:]

    /// デバイスごとの preferredTransform（天地回転が必要な場合）
    var videoTransforms: [String: CGAffineTransform] = [:]

    /// 現在表示中のデバイス名（PlaybackController.activePreviewDevice と同期）
    var activeDevice: String = ""

    /// フィルタパラメータ（PlaybackController と同一インスタンスを共有）
    var filterParamsHolder: FilterParamsHolder?

    /// 一時停止中のフィルタ変更用：最後に取得した未加工 CIImage をキャッシュ
    private var lastRawImage: CIImage?

    /// MTKView への弱参照（requestRender 用）
    weak var mtkView: MTKView?

    // MARK: - Init

    override init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("Metal is not supported on this device")
        }
        self.device = device
        self.commandQueue = queue
        self.ciContext = CIContext(mtlDevice: device, options: [
            .cacheIntermediates: false,
            .priorityRequestLow: false
        ])
        super.init()
    }

    // MARK: - Setup / Teardown

    /// AVPlayer ごとに AVPlayerItemVideoOutput を作成してアタッチする
    func setup(players: [String: AVPlayer]) {
        teardown()
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        for (deviceName, player) in players {
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
            if let item = player.currentItem {
                item.add(output)
            }
            videoOutputs[deviceName] = output
        }
    }

    /// 全 output を除去してリソース解放
    func teardown() {
        for (deviceName, output) in videoOutputs {
            _ = deviceName
            _ = output
        }
        videoOutputs.removeAll()
        lastRawImage = nil
    }

    /// 一時停止中にフィルタ変更後、次の描画サイクルを強制発行
    func requestRender() {
        mtkView?.setNeedsDisplay()
    }

    // MARK: - Pipeline Warm-up

    /// Metal CIFilter シェーダパイプラインを事前コンパイルする。
    /// 初回フレーム描画時の "building pipeline" による数秒の固まりを防ぐため、
    /// setupAll() 内の isReady = true より前に呼ぶこと。
    func warmUpPipeline() async {
        let ciCtx = self.ciContext
        let mtlDevice = self.device
        await Task.detached(priority: .userInitiated) {
            guard let commandQueue = mtlDevice.makeCommandQueue() else { return }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: 64,
                height: 64,
                mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderWrite, .shaderRead]
            guard let texture = mtlDevice.makeTexture(descriptor: descriptor) else { return }

            // ウォームアップ対象フィルタ名のリスト（nil = フィルタなし）
            // CIRenderDestination + commandBuffer 経由でレンダリングすることで
            // draw(in:) と同じ Metal パイプラインが事前コンパイルされる
            let filterNames: [String?] = [
                nil,                    // フィルタなし（基本パイプライン）
                "CIColorControls",      // 彩度・コントラスト系（custom_vivid など）
                "CIPhotoEffectNoir",    // モノクロ系
                "CIColorPosterize",     // ポスタライズ
                "CIBloom",              // ブルーム
                "CIEdges",              // エッジ検出（custom_comic）
            ]

            for filterName in filterNames {
                guard let commandBuffer = commandQueue.makeCommandBuffer() else { continue }
                let rect = CGRect(x: 0, y: 0, width: 64, height: 64)
                var image = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3))
                    .cropped(to: rect)
                if let name = filterName, let f = CIFilter(name: name) {
                    f.setValue(image, forKey: kCIInputImageKey)
                    if let out = f.outputImage?.cropped(to: rect) {
                        image = out
                    }
                }
                let dest = CIRenderDestination(
                    width: 64,
                    height: 64,
                    pixelFormat: .bgra8Unorm,
                    commandBuffer: commandBuffer,
                    mtlTextureProvider: { texture }
                )
                dest.isFlipped = false
                _ = try? ciCtx.startTask(toRender: image, to: dest)
                // addCompletedHandler は commit() より前に登録する必要がある
                // （commit後に完了している場合、ハンドラが呼ばれない可能性があるため）
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    commandBuffer.addCompletedHandler { _ in continuation.resume() }
                    commandBuffer.commit()
                }
            }
        }.value
    }

    // MARK: - Transform Helpers

    /// preferredTransform を正規化する（エクスポートエンジンと同一ロジック）。
    /// 回転後の矩形の origin が (0,0) になるよう translation を補正する。
    /// 戻り値: (正規化済み transform, 回転後のサイズ)
    private func normalizeTransform(_ transform: CGAffineTransform, naturalSize: CGSize) -> (CGAffineTransform, CGSize) {
        let appliedRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let normalized = transform
            .concatenating(CGAffineTransform(translationX: -appliedRect.origin.x, y: -appliedRect.origin.y))
        let rotatedSize = CGSize(width: abs(appliedRect.width), height: abs(appliedRect.height))
        return (normalized, rotatedSize)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // サイズ変更時は特別な処理不要
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let drawableSize = view.drawableSize

        // activeDevice が空 = 黒画面区間
        guard !activeDevice.isEmpty,
              let output = videoOutputs[activeDevice] else {
            renderBlack(to: drawable, commandBuffer: commandBuffer, size: drawableSize)
            return
        }

        // フレーム取得
        let hostTime = CACurrentMediaTime()
        let itemTime = output.itemTime(forHostTime: hostTime)

        var rawImage: CIImage?
        if output.hasNewPixelBuffer(forItemTime: itemTime),
           let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
            rawImage = CIImage(cvPixelBuffer: pixelBuffer)
            lastRawImage = rawImage
        } else {
            rawImage = lastRawImage
        }

        guard let sourceImage = rawImage else {
            renderBlack(to: drawable, commandBuffer: commandBuffer, size: drawableSize)
            return
        }

        // ── preferredTransform の適用 ──
        // AVPlayerItemVideoOutput の CVPixelBuffer は raw データ（preferredTransform 未適用）。
        // エクスポートエンジンと同じロジックで正規化 transform を適用する。
        //
        // ★ 重要: CIImage は左下原点、preferredTransform は左上原点（UIKit）前提。
        //   そのため transform を CIImage 座標系に変換してから適用する。
        //   手順: Y反転 → preferredTransform → Y反転（戻す）→ origin正規化
        let transform = videoTransforms[activeDevice] ?? .identity
        var orientedImage: CIImage
        if transform != .identity {
            let rawW = sourceImage.extent.width
            let rawH = sourceImage.extent.height

            // CIImage(左下原点) → UIKit(左上原点) に変換
            let toUIKit = CGAffineTransform(scaleX: 1, y: -1)
                .concatenating(CGAffineTransform(translationX: 0, y: rawH))

            // UIKit座標系で preferredTransform を適用
            // 適用後の矩形を計算して origin を (0,0) に正規化
            let inUIKit = toUIKit.concatenating(transform)
            let uikitRect = CGRect(origin: .zero, size: CGSize(width: rawW, height: rawH)).applying(inUIKit)
            let normalizedUIKit = inUIKit
                .concatenating(CGAffineTransform(translationX: -uikitRect.origin.x, y: -uikitRect.origin.y))

            // UIKit(左上原点) → CIImage(左下原点) に戻す
            let rotatedH = abs(uikitRect.height)
            let backToCI = CGAffineTransform(scaleX: 1, y: -1)
                .concatenating(CGAffineTransform(translationX: 0, y: rotatedH))

            let fullTransform = normalizedUIKit.concatenating(backToCI)

            let result = sourceImage.transformed(by: fullTransform)
            let origin = result.extent.origin
            orientedImage = result.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        } else {
            orientedImage = sourceImage
        }

        // フィルタ適用
        var finalImage = orientedImage
        if let holder = filterParamsHolder {
            let params = holder.snapshot()
            if params.hasEffect {
                finalImage = PlaybackController.applyFilters(
                    to: orientedImage,
                    videoFilter: params.videoFilter,
                    kaleidoscopeType: params.kaleidoscopeType,
                    kaleidoscopeSize: params.kaleidoscopeSize,
                    centerX: params.centerX,
                    centerY: params.centerY,
                    tileHeight: params.tileHeight,
                    mirrorDirection: params.mirrorDirection,
                    rotationAngle: params.rotationAngle,
                    displayAspectRatio: params.displayAspectRatio,
                    filterIntensity: params.filterIntensity
                )
            }
        }

        // Aspect-fill: 映像を drawable サイズに合わせてスケール・センタリング
        let videoExtent = finalImage.extent
        guard videoExtent.width > 0, videoExtent.height > 0 else {
            renderBlack(to: drawable, commandBuffer: commandBuffer, size: drawableSize)
            return
        }

        let scaleX = drawableSize.width / videoExtent.width
        let scaleY = drawableSize.height / videoExtent.height
        let scale = max(scaleX, scaleY) // aspect-fill
        let scaledW = videoExtent.width * scale
        let scaledH = videoExtent.height * scale
        let tx = (drawableSize.width - scaledW) / 2 - videoExtent.origin.x * scale
        let ty = (drawableSize.height - scaledH) / 2 - videoExtent.origin.y * scale

        // CIImage（左下原点）→ Metal テクスチャ（左上原点）への Y軸反転 + Aspect-fill
        let fitTransform = CGAffineTransform(scaleX: scale, y: scale)
            .translatedBy(x: tx / scale, y: ty / scale)
        let yFlip = CGAffineTransform(scaleX: 1, y: -1)
            .translatedBy(x: 0, y: -drawableSize.height)
        let transformed = finalImage
            .transformed(by: fitTransform)
            .transformed(by: yFlip)

        // drawable のテクスチャに描画
        let destination = CIRenderDestination(
            width: Int(drawableSize.width),
            height: Int(drawableSize.height),
            pixelFormat: view.colorPixelFormat,
            commandBuffer: commandBuffer,
            mtlTextureProvider: { drawable.texture }
        )
        destination.isFlipped = false

        do {
            try ciContext.startTask(toRender: transformed, to: destination)
        } catch {
            // レンダリングエラーは無視（次フレームで再試行）
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Helpers

    private func renderBlack(to drawable: CAMetalDrawable, commandBuffer: MTLCommandBuffer, size: CGSize) {
        let black = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        let destination = CIRenderDestination(
            width: Int(size.width),
            height: Int(size.height),
            pixelFormat: .bgra8Unorm,
            commandBuffer: commandBuffer,
            mtlTextureProvider: { drawable.texture }
        )
        try? ciContext.startTask(toRender: black, to: destination)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - MetalPreviewView (UIViewRepresentable)

import SwiftUI

struct MetalPreviewView: UIViewRepresentable {
    let renderer: MetalPreviewRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.delegate = renderer
        view.preferredFramesPerSecond = 30
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.backgroundColor = .black
        renderer.mtkView = view
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // renderer は外部管理、更新不要
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: ()) {
        uiView.delegate = nil
    }
}
