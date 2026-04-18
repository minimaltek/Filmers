//
//  FrameLayout.swift
//  Filmers
//
//  フレームレイアウトの定義
//

import CoreGraphics

/// カメラフレームのレイアウトタイプ
enum FrameLayout: CaseIterable, Equatable, Codable {
    case landscapeSingle
    case portraitSingle
    case split2
    case split3

    /// アスペクト比
    var aspectRatio: CGFloat {
        switch self {
        case .landscapeSingle: return 16.0 / 9.0
        case .portraitSingle:  return 9.0 / 16.0
        case .split2:          return 16.0 / 9.0
        case .split3:          return 16.0 / 9.0
        }
    }

    /// 表示ラベル
    var label: String {
        switch self {
        case .landscapeSingle: return "Landscape"
        case .portraitSingle:  return "Portrait"
        case .split2:          return "Split 2"
        case .split3:          return "Split 3"
        }
    }
    
    /// 説明文
    var description: String {
        switch self {
        case .landscapeSingle: return "Single landscape frame"
        case .portraitSingle:  return "Single portrait frame"
        case .split2:          return "Two frames side by side"
        case .split3:          return "Three frames side by side"
        }
    }
}
