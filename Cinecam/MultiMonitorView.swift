//
//  MultiMonitorView.swift
//  Cinecam
//
//  マルチモニタービュー: 接続中の全デバイスのカメラスナップショットをタイル表示
//

import SwiftUI

struct MultiMonitorView: View {
    @ObservedObject var sessionManager: CameraSessionManager
    @ObservedObject var cameraManager: CameraManager
    @Environment(\.dismiss) private var dismiss
    
    private var sortedDevices: [String] {
        sessionManager.peerSnapshots.keys.sorted()
    }
    
    /// 横長画角（シネマ等）の場合は1列、ポートレート画角は2列
    private var columns: [GridItem] {
        let ratio = cameraManager.desiredOrientation.aspectRatio
        if ratio >= 1.0 {
            // 横長画角 → 1列表示（大きく見せる）
            return [GridItem(.flexible())]
        }
        let count = sortedDevices.count
        let cols = count <= 1 ? 1 : (count <= 4 ? 2 : 3)
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: cols)
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Button(action: {
                        sessionManager.stopMultiMonitor()
                        dismiss()
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    
                    Spacer()
                    
                    Text("MULTI MONITOR")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    // デバイス数表示
                    Text("\(sortedDevices.count)")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Circle())
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                
                if sortedDevices.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.white)
                        Text("スナップショット待機中...")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                    }
                    Spacer()
                } else {
                    // Tile grid
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(sortedDevices, id: \.self) { deviceName in
                                snapshotTile(deviceName: deviceName)
                            }
                        }
                        .padding(8)
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func snapshotTile(deviceName: String) -> some View {
        VStack(spacing: 4) {
            if let jpegData = sessionManager.peerSnapshots[deviceName],
               let uiImage = UIImage(data: jpegData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .aspectRatio(16/9, contentMode: .fit)
                    .overlay(
                        ProgressView()
                            .tint(.white)
                    )
            }
            
            Text(deviceName)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

#Preview {
    MultiMonitorView(sessionManager: CameraSessionManager(), cameraManager: .previewMock)
}
