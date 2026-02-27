import SwiftUI
import AVFoundation

struct FrameSetView: View {
    @ObservedObject var cameraManager: CameraManager
    @Environment(\.dismiss) private var dismiss
    var onConfirm: ((FrameLayout) -> Void)?

    @State private var selectedLayout: FrameLayout = .landscapeSingle

    // Canvas / Preview 判定
    private var isPreview: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        #else
        return false
        #endif
    }

    var body: some View {
        VStack(spacing: 16) {
                // Top bar: Close (left) and In-Cam toggle (right)
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }

                    Spacer()

                    Button { toggleFrontBackCamera() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(10)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                // Aspect preview area
                AspectPreview(layout: selectedLayout)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)

                // Frame layout selection buttons
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        FrameLayoutButton(
                            layout: .landscapeSingle,
                            selected: selectedLayout == .landscapeSingle
                        ) {
                            selectedLayout = .landscapeSingle
                        }
                        FrameLayoutButton(
                            layout: .portraitSingle,
                            selected: selectedLayout == .portraitSingle
                        ) {
                            selectedLayout = .portraitSingle
                        }
                    }
                    HStack(spacing: 12) {
                        FrameLayoutButton(
                            layout: .split2,
                            selected: selectedLayout == .split2
                        ) {
                            selectedLayout = .split2
                        }
                        FrameLayoutButton(
                            layout: .split3,
                            selected: selectedLayout == .split3
                        ) {
                            selectedLayout = .split3
                        }
                    }
                }
                .padding(.horizontal, 20)

                Spacer()

                // Confirm button (Frame Set)
                Button {
                    onConfirm?(selectedLayout)
                    dismiss()
                } label: {
                    Text("Frame Set")
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color.red)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
        }
        .background(Color.black.ignoresSafeArea())
    }

    // MARK: - Helpers

    private func toggleFrontBackCamera() {
        if isPreview { return }
        let currentPosition = cameraManager.currentCamera?.position ?? .back
        let target: AVCaptureDevice.Position = (currentPosition == .back) ? .front : .back
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: target) {
            cameraManager.switchCamera(to: device)
        }
    }
}

// MARK: - Aspect Preview

struct AspectPreview: View {
    let layout: FrameLayout

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.06))
                .aspectRatio(layout.aspectRatio, contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.gray.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                )

            // Orientation label
            VStack {
                HStack {
                    Text(layout.label)
                        .font(.caption2)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(8)
                    Spacer()
                }
                Spacer()
            }
        }
    }
}

// MARK: - Frame Layout Button

struct FrameLayoutButton: View {
    let layout: FrameLayout
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(selected ? Color.red.opacity(0.18) : Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(selected ? Color.red : Color.white.opacity(0.2), lineWidth: 2)
                    )
                VStack(spacing: 6) {
                    // Simple glyphs to hint layout
                    switch layout {
                    case .landscapeSingle:
                        Rectangle().fill(Color.white.opacity(0.6)).frame(height: 14)
                    case .portraitSingle:
                        HStack { Rectangle().fill(Color.white.opacity(0.6)).frame(width: 14) ; Spacer(minLength: 0) }
                    case .split2:
                        HStack(spacing: 6) {
                            Rectangle().fill(Color.white.opacity(0.6))
                            Rectangle().fill(Color.white.opacity(0.6))
                        }.frame(height: 14)
                    case .split3:
                        HStack(spacing: 4) {
                            Rectangle().fill(Color.white.opacity(0.6))
                            Rectangle().fill(Color.white.opacity(0.6))
                            Rectangle().fill(Color.white.opacity(0.6))
                        }.frame(height: 14)
                    }
                    Text(layout.label)
                        .font(.caption2)
                        .foregroundColor(.white)
                        .padding(.top, 2)
                }
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 56)
    }
}

#Preview("FrameSetView") {
    FrameSetView(cameraManager: CameraManager.previewMock) { _ in }
        .preferredColorScheme(ColorScheme.dark)
}
