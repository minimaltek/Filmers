//
//  DancingLoaderView.swift
//  Filmers
//
//  SwiftUI 棒人形ランニングアニメーション ローディング表示
//  8コマのキーフレームアニメーション（コマ送り方式）
//  バイオメカニクスに基づく関節角度
//

import SwiftUI

struct DancingLoaderView: View {
    var size: CGFloat = 80
    var tint: Color = .white

    var body: some View {
        let displaySize = size * 0.5
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            // 8コマ/秒 — 離散的なフレームインデックス
            let frameIndex = Int(elapsed * 8) % 8
            RunningFigureCanvas(frame: frameIndex, tint: tint)
                .frame(width: displaySize, height: displaySize)
        }
    }
}

// MARK: - Keyframe Pose

/// 1フレーム分のポーズ（各関節の角度をラジアンで定義）
///
/// 座標系:
///   角度0 = 右方向、π/2(1.57) = 真下、π(3.14) = 左方向
///   太もも: π/2より小さい = 前方、π/2より大きい = 後方
///   膝: 太もも角度への追加曲げ（正の値で膝が曲がる）
///   上腕: π/2より小さい = 前方（下がり気味に前へ）、π/2より大きい = 後方
///   肘: 上腕角度からの引き戻し（正の値で肘が曲がる）
private struct RunPose {
    let lean: CGFloat         // 体の前傾角度（ラジアン、0.2-0.4 = 前傾）
    let bounce: CGFloat       // 上下バウンス（-1〜1）

    // 右脚
    let rThigh: CGFloat       // 右太もも角度
    let rKnee: CGFloat        // 右膝の追加曲げ角度
    // 左脚
    let lThigh: CGFloat
    let lKnee: CGFloat

    // 右腕
    let rShoulder: CGFloat    // 右上腕角度
    let rElbow: CGFloat       // 右肘の追加曲げ角度
    // 左腕
    let lShoulder: CGFloat
    let lElbow: CGFloat
}

// MARK: - 8-Frame Run Cycle (バイオメカニクス準拠)
//
// 陸上短距離選手の走行サイクルに基づく8フレーム:
//
// 【角度の目安（ラジアン→度数）】
//   0.35 rad ≈ 20° (太ももが大きく前に出ている)
//   0.70 rad ≈ 40° (太ももが前方)
//   1.05 rad ≈ 60° (やや前方〜斜め下)
//   1.57 rad ≈ 90° (真下)
//   2.09 rad ≈ 120° (後方)
//   2.44 rad ≈ 140° (大きく後方)
//
// スプリントのバイオメカニクス要点:
//   - 接地時: 股関節 50° 屈曲、膝 40° 屈曲
//   - 荷重応答: 膝 60° まで屈曲
//   - 蹴り出し: 股関節伸展(後方)、足関節底屈 25°
//   - スイング中期: 膝 最大 125° 屈曲（膝を高く畳む）
//   - 腕: 肘90°固定、肩から大きくスイング
//   - 前傾: 約15-20°
//
// 参考:
//   https://www.physio-pedia.com/Running_Biomechanics
//   https://compedgept.com/blog/four-phases-of-sprinting-mechanics/

private let runCycle: [RunPose] = [

    // === 右脚前サイクル（コマ1〜4）===

    // コマ1: 右脚接地直前（ターミナルスイング）
    // 右太もも前方50°、膝伸展準備中
    // 左脚は蹴り出し直後、後方に大きく伸びる
    // 左腕前方に強くドライブ、右腕後方に肘を高く引く
    RunPose(lean: 0.28, bounce: -0.4,
            rThigh: 0.52, rKnee: 0.25,     // 右: 前方に大きく伸ばし（50° flexion）、膝やや曲げ
            lThigh: 2.44, lKnee: 0.50,     // 左: 大きく後方へ蹴り出し（140°）、膝やや曲げ
            rShoulder: 2.70, rElbow: 0.55,  // 右腕: 後方に高く、拳が腰の後方遠くへ
            lShoulder: 0.35, lElbow: 1.57), // 左腕: 前方ドライブ、肘90°

    // コマ2: 右脚接地・荷重応答
    // 右脚が地面を捉える、膝が60°まで曲がる（衝撃吸収）
    // 左脚が地面を離れ、膝が急速に屈曲し始める（スイング開始）
    RunPose(lean: 0.32, bounce: 0.3,
            rThigh: 0.87, rKnee: 0.52,     // 右: 接地、やや前方（膝60°屈曲）
            lThigh: 2.27, lKnee: 1.22,     // 左: 後方で膝を畳み始める
            rShoulder: 2.36, rElbow: 0.70,  // 右腕: 後方、拳が後ろに伸びる
            lShoulder: 0.52, lElbow: 1.40), // 左腕: 前方

    // コマ3: 右脚ミッドスタンス（軸足真下）
    // 右脚はほぼ真下、体重を支える
    // 左脚の膝が最大屈曲（125°）で高く畳まれる — 最も特徴的なスプリントポーズ
    RunPose(lean: 0.35, bounce: 0.5,
            rThigh: 1.40, rKnee: 0.20,     // 右: 軸足、ほぼ真下で伸展
            lThigh: 0.87, lKnee: 2.18,     // 左: 太もも前方、膝125°で最大に畳む ★
            rShoulder: 1.57, rElbow: 1.22,  // 右腕: ニュートラル
            lShoulder: 1.57, lElbow: 1.05), // 左腕: やや後方寄り

    // コマ4: 右脚蹴り出し（トリプルエクステンション）
    // 右脚が後方へ伸び、地面を強く蹴る（股関節20°伸展）
    // 左脚が前方へ振り出され、膝がまだ畳まれている
    RunPose(lean: 0.30, bounce: -0.2,
            rThigh: 1.92, rKnee: 0.35,     // 右: 後方に蹴り出し（~110°）
            lThigh: 0.52, lKnee: 1.57,     // 左: 前方へ振り出し、膝畳み中
            rShoulder: 0.70, rElbow: 1.57,  // 右腕: 前方にスイング
            lShoulder: 2.70, lElbow: 0.55), // 左腕: 後方に高く、拳が後方遠くへ

    // === 左脚前サイクル（コマ5〜8）=== 左右反転

    // コマ5: 左脚接地直前（ターミナルスイング）
    RunPose(lean: 0.28, bounce: -0.4,
            rThigh: 2.44, rKnee: 0.50,     // 右: 後方に蹴り出し
            lThigh: 0.52, lKnee: 0.25,     // 左: 前方に大きく伸ばし
            rShoulder: 0.35, rElbow: 1.57,  // 右腕: 前方ドライブ
            lShoulder: 2.70, lElbow: 0.55), // 左腕: 後方に高く、拳が後方遠くへ

    // コマ6: 左脚接地・荷重応答
    RunPose(lean: 0.32, bounce: 0.3,
            rThigh: 2.27, rKnee: 1.22,     // 右: 後方で膝を畳み始める
            lThigh: 0.87, lKnee: 0.52,     // 左: 接地
            rShoulder: 0.52, rElbow: 1.40,  // 右腕: 前方
            lShoulder: 2.36, lElbow: 0.70), // 左腕: 後方、拳が後ろに伸びる

    // コマ7: 左脚ミッドスタンス
    RunPose(lean: 0.35, bounce: 0.5,
            rThigh: 0.87, rKnee: 2.18,     // 右: 膝125°最大屈曲 ★
            lThigh: 1.40, lKnee: 0.20,     // 左: 軸足
            rShoulder: 1.22, rElbow: 0.87,  // 右腕: やや後方
            lShoulder: 1.57, lElbow: 1.22), // 左腕: ニュートラル

    // コマ8: 左脚蹴り出し
    RunPose(lean: 0.30, bounce: -0.2,
            rThigh: 0.52, rKnee: 1.57,     // 右: 前方へ振り出し
            lThigh: 1.92, lKnee: 0.35,     // 左: 後方に蹴り出し
            rShoulder: 2.70, rElbow: 0.55,  // 右腕: 後方に高く、拳が後方遠くへ
            lShoulder: 0.70, lElbow: 1.57), // 左腕: 前方にスイング
]

// MARK: - Running Figure Canvas (keyframe-based)

private struct RunningFigureCanvas: View {
    let frame: Int
    let tint: Color

    var body: some View {
        Canvas { context, sz in
            let w = sz.width
            let h = sz.height
            let pose = runCycle[frame % runCycle.count]

            // 体の上下バウンス
            let bounce = pose.bounce * h * 0.03

            // --- 体幹 ---
            let hipX = w * 0.44
            let hipY = h * 0.48 + bounce
            let hip = CGPoint(x: hipX, y: hipY)

            let spineLen = h * 0.26
            let lean = pose.lean
            let neck = CGPoint(
                x: hip.x + sin(lean) * spineLen,
                y: hip.y - cos(lean) * spineLen
            )

            let headR = w * 0.09
            let headCenter = CGPoint(
                x: neck.x + sin(lean) * headR * 1.1,
                y: neck.y - cos(lean) * headR * 1.05
            )

            // 寸法
            let upperArm = w * 0.22
            let forearm  = w * 0.20
            let thigh    = h * 0.25
            let shin     = h * 0.25

            let lineW = w * 0.055
            let style = StrokeStyle(lineWidth: lineW, lineCap: .round, lineJoin: .round)

            // --- 関節角度をポーズから取得 ---
            let rThighAngle = pose.rThigh
            let lThighAngle = pose.lThigh
            let rKneeAngle = rThighAngle + pose.rKnee
            let lKneeAngle = lThighAngle + pose.lKnee

            let rShoulderAngle = pose.rShoulder
            let lShoulderAngle = pose.lShoulder
            let rElbowAngle = rShoulderAngle - pose.rElbow
            let lElbowAngle = lShoulderAngle - pose.lElbow

            // === 描画 ===

            // 頭（塗りつぶし）
            let headRect = CGRect(x: headCenter.x - headR, y: headCenter.y - headR,
                                  width: headR * 2, height: headR * 2)
            context.fill(Path(ellipseIn: headRect), with: .color(tint))

            // 背骨
            var spinePath = Path()
            spinePath.move(to: neck)
            spinePath.addLine(to: hip)
            context.stroke(spinePath, with: .color(tint), style: style)

            // 左腕
            let lElbowPt = CGPoint(x: neck.x + cos(lShoulderAngle) * upperArm,
                                   y: neck.y + sin(lShoulderAngle) * upperArm)
            let lHandPt  = CGPoint(x: lElbowPt.x + cos(lElbowAngle) * forearm,
                                   y: lElbowPt.y + sin(lElbowAngle) * forearm)
            var lArm = Path(); lArm.move(to: neck); lArm.addLine(to: lElbowPt); lArm.addLine(to: lHandPt)
            context.stroke(lArm, with: .color(tint), style: style)

            // 右腕
            let rElbowPt = CGPoint(x: neck.x + cos(rShoulderAngle) * upperArm,
                                   y: neck.y + sin(rShoulderAngle) * upperArm)
            let rHandPt  = CGPoint(x: rElbowPt.x + cos(rElbowAngle) * forearm,
                                   y: rElbowPt.y + sin(rElbowAngle) * forearm)
            var rArm = Path(); rArm.move(to: neck); rArm.addLine(to: rElbowPt); rArm.addLine(to: rHandPt)
            context.stroke(rArm, with: .color(tint), style: style)

            // 左脚
            let lKneePt = CGPoint(x: hip.x + cos(lThighAngle) * thigh,
                                  y: hip.y + sin(lThighAngle) * thigh)
            let lFootPt = CGPoint(x: lKneePt.x + cos(lKneeAngle) * shin,
                                  y: lKneePt.y + sin(lKneeAngle) * shin)
            var lLeg = Path(); lLeg.move(to: hip); lLeg.addLine(to: lKneePt); lLeg.addLine(to: lFootPt)
            context.stroke(lLeg, with: .color(tint), style: style)

            // 右脚
            let rKneePt = CGPoint(x: hip.x + cos(rThighAngle) * thigh,
                                  y: hip.y + sin(rThighAngle) * thigh)
            let rFootPt = CGPoint(x: rKneePt.x + cos(rKneeAngle) * shin,
                                  y: rKneePt.y + sin(rKneeAngle) * shin)
            var rLeg = Path(); rLeg.move(to: hip); rLeg.addLine(to: rKneePt); rLeg.addLine(to: rFootPt)
            context.stroke(rLeg, with: .color(tint), style: style)
        }
    }
}
