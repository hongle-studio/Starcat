//
//  InsightsCardIllustration.swift
//  Starcat
//
//  仓库洞察卡片（本地洞察 / 活动概览）的示意装饰插画与轻量部件。
//
//  关键约束（对齐 InsightsMetricMotifBackground 的既有约定）：
//  - 只做视觉层次，不携带任何数据语义，禁止据此解读指标；
//  - 统一用语义 tint 低透明绘制，明暗主题都可读；
//  - allowsHitTesting(false) + accessibilityHidden(true)，不进无障碍树；
//  - SF Symbols 没有对应的「文件夹 / 单据 / 盾牌组合」类插画，因此用 Canvas 手绘。
//

import SwiftUI

/// 卡片装饰插画的语义母题。一个母题对应一种手绘线稿，与卡片内容一一对应。
enum InsightsCardIllustrationMotif: Sendable {
    /// 最新 Release：文件夹 + 星光。
    case releaseFolder
    /// 开源许可证：单据 + 圆形徽章。
    case licenseDocument
    /// 健康评分：上升柱。
    case healthBars
    /// OpenSSF：盾牌 + 对勾。
    case securityShield
    /// 新建 Pull Request：分支节点。
    case branchGraph
    /// 已合并 Pull Request：汇入曲线。
    case mergeCurve
    /// 新建 Issue：单据 + 圆点徽章。
    case issueDocument
    /// 已关闭 Issue：对勾圆环。
    case checkCircle
}

/// Canvas 手绘的卡片装饰插画。绘制空间固定 72×52，等比缩放居中，避免随容器拉伸变形。
struct InsightsCardIllustration: View {
    let motif: InsightsCardIllustrationMotif
    let tint: Color

    private static let designSize = CGSize(width: 72, height: 52)

    var body: some View {
        Canvas { context, size in
            guard size.width > 1, size.height > 1 else { return }
            let scale = min(
                size.width / Self.designSize.width,
                size.height / Self.designSize.height
            )
            let scaled = CGSize(
                width: Self.designSize.width * scale,
                height: Self.designSize.height * scale
            )
            var inner = context
            inner.translateBy(
                x: (size.width - scaled.width) / 2,
                y: (size.height - scaled.height) / 2
            )
            inner.scaleBy(x: scale, y: scale)
            switch motif {
            case .releaseFolder:
                Self.drawReleaseFolder(into: &inner, tint: tint)
            case .licenseDocument:
                Self.drawLicenseDocument(into: &inner, tint: tint)
            case .healthBars:
                Self.drawHealthBars(into: &inner, tint: tint)
            case .securityShield:
                Self.drawSecurityShield(into: &inner, tint: tint)
            case .branchGraph:
                Self.drawBranchGraph(into: &inner, tint: tint)
            case .mergeCurve:
                Self.drawMergeCurve(into: &inner, tint: tint)
            case .issueDocument:
                Self.drawIssueDocument(into: &inner, tint: tint)
            case .checkCircle:
                Self.drawCheckCircle(into: &inner, tint: tint)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - 母题线稿

    /// 文件夹 + 星光：示意「最新版本打包发布」。
    private static func drawReleaseFolder(
        into context: inout GraphicsContext,
        tint: Color
    ) {
        var folder = Path()
        folder.addRoundedRect(
            in: CGRect(x: 8, y: 12, width: 24, height: 10),
            cornerSize: CGSize(width: 4, height: 4),
            style: .continuous
        )
        folder.addRoundedRect(
            in: CGRect(x: 8, y: 16, width: 46, height: 27),
            cornerSize: CGSize(width: 5, height: 5),
            style: .continuous
        )
        context.fill(folder, with: .color(tint.opacity(0.10)))
        context.stroke(
            folder,
            with: .color(tint.opacity(0.26)),
            style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)
        )

        // 文件夹正面的小圆徽，示意 Release 图标贴纸。
        let badge = Path(ellipseIn: CGRect(x: 24, y: 25, width: 12, height: 12))
        context.fill(badge, with: .color(tint.opacity(0.18)))

        // 四角星：版本更新的「新」信号。
        var spark = Path()
        spark.move(to: CGPoint(x: 60, y: 5))
        spark.addLine(to: CGPoint(x: 62.4, y: 10.6))
        spark.addLine(to: CGPoint(x: 68, y: 13))
        spark.addLine(to: CGPoint(x: 62.4, y: 15.4))
        spark.addLine(to: CGPoint(x: 60, y: 21))
        spark.addLine(to: CGPoint(x: 57.6, y: 15.4))
        spark.addLine(to: CGPoint(x: 52, y: 13))
        spark.addLine(to: CGPoint(x: 57.6, y: 10.6))
        spark.closeSubpath()
        context.fill(spark, with: .color(tint.opacity(0.24)))
    }

    /// 单据 + 圆形徽章：示意许可证文本与授权印章。
    private static func drawLicenseDocument(
        into context: inout GraphicsContext,
        tint: Color
    ) {
        drawDocumentBody(into: &context, tint: tint, frame: CGRect(x: 16, y: 6, width: 32, height: 40))

        drawTextLines(
            into: &context,
            tint: tint,
            xs: CGRect(x: 22, y: 15, width: 20, height: 0),
            rows: [15, 22, 29]
        )

        // 印章：圆环 + 对勾。
        let sealCenter = CGPoint(x: 47, y: 40)
        context.stroke(
            Path(ellipseIn: CGRect(
                x: sealCenter.x - 7,
                y: sealCenter.y - 7,
                width: 14,
                height: 14
            )),
            with: .color(tint.opacity(0.30)),
            style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
        )
        var check = Path()
        check.move(to: CGPoint(x: sealCenter.x - 3.4, y: sealCenter.y))
        check.addLine(to: CGPoint(x: sealCenter.x - 1, y: sealCenter.y + 2.4))
        check.addLine(to: CGPoint(x: sealCenter.x + 3.6, y: sealCenter.y - 2.6))
        context.stroke(
            check,
            with: .color(tint.opacity(0.34)),
            style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
        )
    }

    /// 上升柱：示意健康评分的多维度量。
    private static func drawHealthBars(
        into context: inout GraphicsContext,
        tint: Color
    ) {
        let bars: [(x: CGFloat, height: CGFloat)] = [
            (10, 18),
            (30, 28),
            (50, 40)
        ]
        for bar in bars {
            let rect = CGRect(
                x: bar.x,
                y: 48 - bar.height,
                width: 12,
                height: bar.height
            )
            context.fill(
                Path(roundedRect: rect, cornerRadius: 3.5, style: .continuous),
                with: .color(tint.opacity(0.16))
            )
        }
    }

    /// 盾牌 + 对勾：示意安全评分。
    private static func drawSecurityShield(
        into context: inout GraphicsContext,
        tint: Color
    ) {
        var shield = Path()
        shield.move(to: CGPoint(x: 36, y: 5))
        shield.addCurve(
            to: CGPoint(x: 56, y: 11),
            control1: CGPoint(x: 43, y: 8.6),
            control2: CGPoint(x: 50, y: 11)
        )
        shield.addCurve(
            to: CGPoint(x: 36, y: 47),
            control1: CGPoint(x: 56, y: 27),
            control2: CGPoint(x: 48, y: 40)
        )
        shield.addCurve(
            to: CGPoint(x: 16, y: 11),
            control1: CGPoint(x: 24, y: 40),
            control2: CGPoint(x: 16, y: 27)
        )
        shield.addCurve(
            to: CGPoint(x: 36, y: 5),
            control1: CGPoint(x: 22, y: 11),
            control2: CGPoint(x: 29, y: 8.6)
        )
        shield.closeSubpath()
        context.fill(shield, with: .color(tint.opacity(0.10)))
        context.stroke(
            shield,
            with: .color(tint.opacity(0.26)),
            style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)
        )

        var check = Path()
        check.move(to: CGPoint(x: 28, y: 25))
        check.addLine(to: CGPoint(x: 34, y: 31))
        check.addLine(to: CGPoint(x: 45, y: 19))
        context.stroke(
            check,
            with: .color(tint.opacity(0.30)),
            style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
        )
    }

    /// 分支节点：示意从主干新建 Pull Request。
    private static func drawBranchGraph(
        into context: inout GraphicsContext,
        tint: Color
    ) {
        var trunk = Path()
        trunk.move(to: CGPoint(x: 12, y: 14))
        trunk.addLine(to: CGPoint(x: 12, y: 40))
        var branch = Path()
        branch.move(to: CGPoint(x: 12, y: 32))
        branch.addCurve(
            to: CGPoint(x: 42, y: 12),
            control1: CGPoint(x: 28, y: 32),
            control2: CGPoint(x: 26, y: 12)
        )
        for path in [trunk, branch] {
            context.stroke(
                path,
                with: .color(tint.opacity(0.26)),
                style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
            )
        }
        drawNode(into: &context, tint: tint, at: CGPoint(x: 12, y: 44), radius: 4)
        drawNode(into: &context, tint: tint, at: CGPoint(x: 12, y: 14), radius: 4)
        drawNode(into: &context, tint: tint, at: CGPoint(x: 46, y: 12), radius: 4.5)
    }

    /// 汇入曲线：示意分支合并回主干。
    private static func drawMergeCurve(
        into context: inout GraphicsContext,
        tint: Color
    ) {
        var main = Path()
        main.move(to: CGPoint(x: 8, y: 40))
        main.addLine(to: CGPoint(x: 58, y: 40))
        var curve = Path()
        curve.move(to: CGPoint(x: 18, y: 12))
        curve.addCurve(
            to: CGPoint(x: 44, y: 40),
            control1: CGPoint(x: 18, y: 30),
            control2: CGPoint(x: 28, y: 40)
        )
        context.stroke(
            main,
            with: .color(tint.opacity(0.22)),
            style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
        )
        context.stroke(
            curve,
            with: .color(tint.opacity(0.28)),
            style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
        )
        drawNode(into: &context, tint: tint, at: CGPoint(x: 18, y: 12), radius: 4)
        drawNode(into: &context, tint: tint, at: CGPoint(x: 58, y: 40), radius: 4.5)
    }

    /// 单据 + 圆点徽章：示意新建 Issue 工单。
    private static func drawIssueDocument(
        into context: inout GraphicsContext,
        tint: Color
    ) {
        drawDocumentBody(into: &context, tint: tint, frame: CGRect(x: 22, y: 6, width: 32, height: 40))

        drawTextLines(
            into: &context,
            tint: tint,
            xs: CGRect(x: 28, y: 15, width: 20, height: 0),
            rows: [15, 22, 29]
        )

        // 圆环 + 圆点，与列表里「新建 Issue」的 record.circle 符号同构。
        let badgeCenter = CGPoint(x: 18, y: 40)
        context.stroke(
            Path(ellipseIn: CGRect(
                x: badgeCenter.x - 7,
                y: badgeCenter.y - 7,
                width: 14,
                height: 14
            )),
            with: .color(tint.opacity(0.30)),
            style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
        )
        context.fill(
            Path(ellipseIn: CGRect(
                x: badgeCenter.x - 2.6,
                y: badgeCenter.y - 2.6,
                width: 5.2,
                height: 5.2
            )),
            with: .color(tint.opacity(0.32))
        )
    }

    /// 对勾圆环：示意已关闭 Issue。
    private static func drawCheckCircle(
        into context: inout GraphicsContext,
        tint: Color
    ) {
        let ring = Path(ellipseIn: CGRect(x: 19, y: 9, width: 34, height: 34))
        context.fill(ring, with: .color(tint.opacity(0.08)))
        context.stroke(
            ring,
            with: .color(tint.opacity(0.26)),
            style: StrokeStyle(lineWidth: 2)
        )

        var check = Path()
        check.move(to: CGPoint(x: 28, y: 27))
        check.addLine(to: CGPoint(x: 34, y: 33))
        check.addLine(to: CGPoint(x: 45, y: 20))
        context.stroke(
            check,
            with: .color(tint.opacity(0.32)),
            style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
        )
    }

    // MARK: - 共用元素

    private static func drawDocumentBody(
        into context: inout GraphicsContext,
        tint: Color,
        frame: CGRect
    ) {
        let body = Path(roundedRect: frame, cornerRadius: 4, style: .continuous)
        context.fill(body, with: .color(tint.opacity(0.10)))
        context.stroke(
            body,
            with: .color(tint.opacity(0.26)),
            style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)
        )
    }

    private static func drawTextLines(
        into context: inout GraphicsContext,
        tint: Color,
        xs: CGRect,
        rows: [CGFloat]
    ) {
        for row in rows {
            var line = Path()
            line.move(to: CGPoint(x: xs.minX, y: row))
            line.addLine(to: CGPoint(x: xs.minX + xs.width, y: row))
            context.stroke(
                line,
                with: .color(tint.opacity(0.22)),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
        }
    }

    private static func drawNode(
        into context: inout GraphicsContext,
        tint: Color,
        at center: CGPoint,
        radius: CGFloat
    ) {
        let rect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        let node = Path(ellipseIn: rect)
        context.fill(node, with: .color(tint.opacity(0.20)))
        context.stroke(node, with: .color(tint.opacity(0.32)), lineWidth: 1.2)
    }
}

/// 洞察卡左上角的彩色图标 chip：亮色白底 / 深色提亮底 + 语义色图标。
struct InsightsCardIconChip: View {
    let systemImage: String
    let tint: Color
    /// 外部需要更小 / 更大 chip 时显式传入；默认对齐原型比例。
    var size: CGFloat = 26

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(chipFill)
            Image(systemName: systemImage)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }

    private var chipFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.13) : Color.white.opacity(0.82)
    }
}

/// 洞察卡上的圆形 chevron 触发器（原型中的「查看详情」入口）。
///
/// 铁律：`.buttonStyle(.plain)` 必须紧跟 `.focusEffectDisabled()`。
struct InsightsCardChevronButton: View {
    /// 已本地化的 tooltip / 无障碍标签文本。
    let helpText: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(chipFill)
                Circle()
                    .stroke(Color.secondary.opacity(0.16), lineWidth: 0.8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 22, height: 22)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(Text(verbatim: helpText))
        .accessibilityLabel(Text(verbatim: helpText))
    }

    private var chipFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.92)
    }
}
