//
//  StarHistoryChartView.swift
//  Starcat
//
//  Star 历史曲线的独立渲染视图与不可变渲染模型。
//
//  关键约束：
//  - 原始历史只在 Snapshot 更新或范围切换时完成抽稀和渲染建模，滚动重绘不重复做 O(n) 处理。
//  - Hover 只在跨越最近数据点时写状态，不把鼠标每个像素都写进 SwiftUI 状态树。
//  - 导出图片复用相同渲染模型，但完全不注册 Hover，避免截入瞬时浮层或触发额外布局。
//  - 入场「描边生长」动画只 mask 绘图区（轴标签在外、全程稳定），且导出截图与 Reduce
//    Motion 下首帧即终态；同范围数据刷新不重播，只有首帧 / 切范围 / 切仓库才重播。
//

import AppKit
import Charts
import SwiftUI

struct StarHistoryChartRenderModel: Equatable, Sendable {
    let range: StarHistoryRange
    let renderedPoints: [StarHistoryPoint]
    let landmarks: [StarHistoryPoint]
    let xDomain: ClosedRange<Date>
    let yDomain: ClosedRange<Double>
    let xAxisDates: [Date]

    static let empty: StarHistoryChartRenderModel = {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        return StarHistoryChartRenderModel(
            range: .oneYear,
            renderedPoints: [],
            landmarks: [],
            xDomain: start...start.addingTimeInterval(86_400),
            yDomain: 0...1,
            xAxisDates: []
        )
    }()

    init(
        points: [StarHistoryPoint],
        range: StarHistoryRange,
        repositoryCreatedAt: Date?,
        now: Date = Date()
    ) {
        let renderedPoints = StarHistoryChartSeriesBuilder.renderedPoints(
            points,
            range: range,
            repositoryCreatedAt: repositoryCreatedAt
        )
        let xDomain = StarHistoryChartLayoutPolicy.xDomain(
            range: range,
            repositoryCreatedAt: repositoryCreatedAt,
            points: points,
            now: now
        )

        self.range = range
        self.renderedPoints = renderedPoints
        landmarks = StarHistoryChartSeriesBuilder.landmarkPoints(in: renderedPoints)
        self.xDomain = xDomain
        yDomain = StarHistoryChartLayoutPolicy.yDomain(range: range, points: points)
        xAxisDates = StarHistoryChartLayoutPolicy.xAxisDates(domain: xDomain, range: range)
    }

    private init(
        range: StarHistoryRange,
        renderedPoints: [StarHistoryPoint],
        landmarks: [StarHistoryPoint],
        xDomain: ClosedRange<Date>,
        yDomain: ClosedRange<Double>,
        xAxisDates: [Date]
    ) {
        self.range = range
        self.renderedPoints = renderedPoints
        self.landmarks = landmarks
        self.xDomain = xDomain
        self.yDomain = yDomain
        self.xAxisDates = xAxisDates
    }
}

struct StarHistoryChartView: View {
    let model: StarHistoryChartRenderModel
    let interactionEnabled: Bool
    let accessibilityValue: String
    let height: CGFloat
    /// 导出截图（剪贴板图片）必须直接渲染终态曲线；屏幕展示传 true 播放入场动画。
    var animateEntrance: Bool = true

    @State private var selectedPointID: String?
    /// 入场揭示进度：0 = 绘图区完全遮住，1 = 完整曲线。只在允许动画时参与渲染。
    @State private var revealProgress: CGFloat = 0

    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion

    private var selectedPoint: StarHistoryPoint? {
        guard interactionEnabled, let selectedPointID else { return nil }
        return model.renderedPoints.first { $0.id == selectedPointID }
    }

    /// 禁用态（导出截图 / Reduce Motion / 空数据）下进度恒为 1：首帧就是终态，
    /// 不会先闪一帧空图再补动画。mask 本体保持无条件挂载，避免开关动画偏好时
    /// 视图结构抖动。
    private var effectiveRevealProgress: CGFloat {
        guard animateEntrance, !reduceMotion, !model.renderedPoints.isEmpty else { return 1 }
        return revealProgress
    }

    /// 播放入场「描边生长」动画。
    ///
    /// 触发面刻意收窄：onAppear 覆盖首帧落点与范围切换（调用点 `.id(range)` 会在切范围时
    /// 整体重建本视图，state 随之归零），`onChange` 只在旧 model 为空（切仓库）时兜底重播。
    /// 同范围刷新出新数据不重播——否则「缓存曲线刚画完、网络刷新又画一遍」会连闪两次。
    private func startEntranceRevealIfNeeded() {
        guard animateEntrance, !reduceMotion, !model.renderedPoints.isEmpty else { return }
        revealProgress = 0
        withAnimation(.easeInOut(duration: 1.1)) {
            revealProgress = 1
        }
    }

    var body: some View {
        Chart {
            historyMarks
            landmarkMarks
            if let selectedPoint {
                selectionMarks(selectedPoint)
            }
        }
        .chartXAxis {
            AxisMarks(values: model.xAxisDates) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(verbatim: axisLabel(date))
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                    }
                }
                AxisTick(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.secondary.opacity(0.25))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { axisValue in
                AxisValueLabel {
                    if let value = axisValue.as(Int.self).map(Double.init)
                        ?? axisValue.as(Double.self) {
                        Text(verbatim: StarHistoryAxisValueFormatter.string(from: value, locale: locale))
                            .font(interfaceScale.font(.captionSmall))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.1))
            }
        }
        .chartYScale(domain: model.yDomain)
        .chartXScale(
            domain: model.xDomain,
            range: .plotDimension(startPadding: 10, endPadding: 10)
        )
        // 入场动画用 mask 而不是动画 xDomain：domain 插值期间轴标签会跟着滑动，
        // 观感像整张图在缩放；mask 只裁绘图区内容，轴、刻度、网格布局全程稳定，
        // 也符合本页「只用淡入淡出 / 进度类动画、不做位移」的既有约定。
        .chartPlotStyle { plotArea in
            plotArea.mask(alignment: .leading) {
                StarHistoryRevealMask(progress: effectiveRevealProgress)
            }
        }
        .chartOverlay { proxy in
            if interactionEnabled {
                GeometryReader { geometry in
                    selectionOverlay(proxy: proxy, geometry: geometry)
                }
            }
        }
        .frame(height: height)
        .padding(10)
        .background(
            Color(nsColor: .textBackgroundColor).opacity(0.35),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("insights.repo.section.stars"))
        .accessibilityValue(Text(accessibilityValue))
        .onAppear(perform: startEntranceRevealIfNeeded)
        .onChange(of: model) { oldValue, _ in
            // 只有「空 → 有数据」才重播（切仓库时 ViewModel 先清空再落新数据）。
            guard oldValue.renderedPoints.isEmpty else { return }
            startEntranceRevealIfNeeded()
        }
    }

    /// `chartXSelection` 会为鼠标每个像素写入一个 Date。这里先映射到最近数据点，
    /// 只有点 ID 真正变化时才更新状态，因此在洞察页滚动经过图表时不会持续重建 Marks。
    private func selectionOverlay(proxy: ChartProxy, geometry: GeometryProxy) -> some View {
        ZStack {
            if let point = selectedPoint,
               let plotAnchor = proxy.plotFrame {
                let plot = geometry[plotAnchor]
                if let xInPlot = proxy.position(forX: point.date) {
                    let lineX = plot.origin.x + xInPlot
                    Path { path in
                        path.move(to: CGPoint(x: lineX, y: plot.minY))
                        path.addLine(to: CGPoint(x: lineX, y: plot.maxY))
                    }
                    .stroke(
                        Color.secondary.opacity(0.45),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                    )

                    let tooltipWidth: CGFloat = 210
                    let clampedX = min(
                        max(lineX, plot.minX + tooltipWidth / 2),
                        plot.maxX - tooltipWidth / 2
                    )
                    selectionAnnotation(point)
                        .position(x: clampedX, y: plot.minY + 18)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                guard let plotAnchor = proxy.plotFrame else {
                    updateSelection(nil)
                    return
                }
                let plot = geometry[plotAnchor]
                guard plot.contains(location),
                      let date: Date = proxy.value(atX: location.x - plot.minX)
                else {
                    updateSelection(nil)
                    return
                }
                updateSelection(
                    StarHistoryDisplayPolicy.selectedPoint(
                        in: model.renderedPoints,
                        selectedDate: date
                    )?.id
                )
            case .ended:
                updateSelection(nil)
            }
        }
    }

    private func updateSelection(_ pointID: String?) {
        guard selectedPointID != pointID else { return }
        selectedPointID = pointID
    }

    private func selectionAnnotation(_ point: StarHistoryPoint) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: fullDate(point.date))
            Text("·")
            Text(point.count.formatted(.number.locale(locale)))
                .monospacedDigit()
        }
        .font(interfaceScale.font(.captionSmall, weight: .medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .starcatGlassSurface(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
    }

    /// 数据来源与精度仍保留在模型中供统计和诊断使用，但趋势本身只表达 Stars 数量变化。
    /// 使用单一 series 和统一实线后，Swift Charts 会自然连接全部抽稀点，不再需要桥接 Mark。
    private var historyMarks: some ChartContent {
        ForEach(model.renderedPoints) { point in
            LineMark(
                x: .value("Date", point.date),
                y: .value("Stars", point.count),
                series: .value("Series", "Star History")
            )
            .foregroundStyle(Color.blue)
            .lineStyle(StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.linear)
        }
    }

    private var landmarkMarks: some ChartContent {
        ForEach(model.landmarks) { point in
            PointMark(
                x: .value("Date", point.date),
                y: .value("Stars", point.count)
            )
            .foregroundStyle(Color.blue)
            .symbolSize(28)
        }
    }

    @ChartContentBuilder
    private func selectionMarks(_ point: StarHistoryPoint) -> some ChartContent {
        PointMark(
            x: .value("Date", point.date),
            y: .value("Stars", point.count)
        )
        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
        .symbolSize(70)

        PointMark(
            x: .value("Date", point.date),
            y: .value("Stars", point.count)
        )
        .foregroundStyle(Color.blue)
        .symbolSize(30)
    }

    private func axisLabel(_ date: Date) -> String {
        switch model.range {
        case .threeMonths:
            return date.formatted(
                Date.FormatStyle().month(.abbreviated).day().locale(locale)
            )
        case .oneYear:
            return date.formatted(
                Date.FormatStyle().year().month(.abbreviated).locale(locale)
            )
        case .all:
            if StarHistoryChartLayoutPolicy.usesDayAxisLabels(domain: model.xDomain) {
                return date.formatted(
                    Date.FormatStyle().month(.abbreviated).day().locale(locale)
                )
            }
            if !StarHistoryChartLayoutPolicy.usesYearOnlyAxisLabels(domain: model.xDomain) {
                return date.formatted(
                    Date.FormatStyle().year().month(.abbreviated).locale(locale)
                )
            }
            return date.formatted(Date.FormatStyle().year().locale(locale))
        }
    }

    private func fullDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().year().month().day().locale(locale))
    }
}

/// 星标曲线入场「描边生长」遮罩：从最左侧按进度揭示绘图区。
///
/// 为什么是自绘 Shape 而不是 `scaleEffect`/裁剪矩形：Shape 通过 `animatableData`
/// 把 progress 暴露给 SwiftUI 的动画系统，`withAnimation` 修改 revealProgress 时
/// 每一帧都会用插值后的进度重算 path，得到 60fps 的从左向右揭示；`scaleEffect`
/// 在 progress 接近 0 时会产生退化几何，且无法精确表达"宽度按比例、高度撑满"。
/// mask 尺寸由 `.mask` 提议为绘图区大小，progress == 1 时铺满全区域等价于不裁剪。
private struct StarHistoryRevealMask: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(CGRect(
            x: 0,
            y: 0,
            width: rect.width * progress,
            height: rect.height
        ))
    }
}
