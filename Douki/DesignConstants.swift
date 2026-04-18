//
//  DesignConstants.swift
//  Douki
//
//  デザイン関連の定数定義
//

import SwiftUI

/// アプリ全体で使用するデザイン定数
enum DesignConstants {
    
    // MARK: - Spacing
    
    enum Spacing {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let extraLarge: CGFloat = 20
        static let huge: CGFloat = 24
    }
    
    // MARK: - Corner Radius
    
    enum CornerRadius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 14
        static let extraLarge: CGFloat = 15
        static let circle: CGFloat = 999
    }
    
    // MARK: - Control Sizes
    
    enum ControlSize {
        static let iconButton: CGFloat = 44
        static let recordButton: CGFloat = 70
        static let recordButtonInner: CGFloat = 60
        static let recordButtonStop: CGFloat = 28
        static let layoutButton: CGFloat = 56
        static let cameraLensButton: CGFloat = 80
    }
    
    // MARK: - Colors
    
    enum Colors {
        static let overlayDark = Color.black.opacity(0.6)
        static let overlayLight = Color.white.opacity(0.1)
        static let overlayExtraLight = Color.white.opacity(0.05)
        static let overlayVeryLight = Color.white.opacity(0.08)
        static let recordingRed = Color.red
        static let activeYellow = Color.yellow
        static let masterOrange = Color.orange
        static let slaveGreen = Color.green
        static let primaryBlue = Color.blue
    }
    
    // MARK: - Font Sizes
    
    enum FontSize {
        static let tiny: CGFloat = 9
        static let extraSmall: CGFloat = 10
        static let small: CGFloat = 13
        static let medium: CGFloat = 16
        static let large: CGFloat = 18
        static let extraLarge: CGFloat = 24
        static let huge: CGFloat = 27
        static let massive: CGFloat = 48
        static let recordButton: CGFloat = 50
    }
    
    // MARK: - Opacity
    
    enum Opacity {
        static let disabled: Double = 0.3
        static let secondary: Double = 0.5
        static let tertiary: Double = 0.7
        static let quaternary: Double = 0.8
        static let quinary: Double = 0.9
    }
    
    // MARK: - Layout
    
    enum Layout {
        static let maxControlWidth: CGFloat = 200
        static let segmentControlWidth: CGFloat = 150
        static let disconnectButtonWidth: CGFloat = 180
        static let connectionIconSize: CGFloat = 12
        static let logViewHeight: CGFloat = 60
        static let cameraLensSize = CGSize(width: 80, height: 80)
        static let framePreviewMaxWidth: CGFloat = .infinity
    }
}
