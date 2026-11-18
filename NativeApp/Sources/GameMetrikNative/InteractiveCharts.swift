import SwiftUI
import Charts
import GameMetrikCore

struct DashboardTrendChart: View {
    let points: [TrendPoint]
    let metric: DashboardMetric
    let currency: String
    var highlightedDate: String?
    var bars: Bool
    var onSelect: ((String) -> Void)?
    @State private var selection: Int?
    init(points: [TrendPoint], metric: DashboardMetric, currency: String, initialSelection: Int? = nil,
         highlightedDate: String? = nil, bars: Bool = false, onSelect: ((String) -> Void)? = nil) {
        self.points = points; self.metric = metric; self.currency = currency
        self.highlightedDate = highlightedDate; self.bars = bars; self.onSelect = onSelect
        _selection = State(initialValue: initialSelection)
    }
    var body: some View {
        let positions = ChartInspection.dayPositions(points.map(\.date))
        let segments = ChartInspection.segments(positions: positions, values: points.map { metric.value($0) })
        let highlighted = selection ?? points.firstIndex { $0.date == highlightedDate }
        Chart {
            ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                if positions.indices.contains(index), positions[index].isFinite, let value = metric.value(point) {
                    if bars {
                        RectangleMark(xStart: .value("Début", positions[index] - 0.32), xEnd: .value("Fin", positions[index] + 0.32),
                                      yStart: .value("Zéro", 0), yEnd: .value(metric.label, value))
                            .foregroundStyle(.metrik)
                            .accessibilityLabel(chartFullDate(point.date)).accessibilityValue(formatted(metric, point))
                    } else {
                        LineMark(x: .value("Date", positions[index]), y: .value(metric.label, value), series: .value("Série", segments[index]))
                            .foregroundStyle(.metrik).lineStyle(StrokeStyle(lineWidth: 2))
                            .accessibilityLabel(chartFullDate(point.date)).accessibilityValue(formatted(metric, point))
                        if points.count <= 60 {
                            PointMark(x: .value("Date", positions[index]), y: .value(metric.label, value)).foregroundStyle(.metrik).symbolSize(18)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            if let highlighted, positions.indices.contains(highlighted), positions[highlighted].isFinite {
                RuleMark(x: .value("Date sélectionnée", positions[highlighted])).foregroundStyle(.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3])).accessibilityHidden(true)
            }
        }
        .chartXScale(domain: chartDomain(positions))
        .chartXAxis {
            AxisMarks(values: ChartInspection.axisPositions(positions)) { axis in
                AxisGridLine().foregroundStyle(.quaternary)
                if let value = axis.as(Double.self), let first = points.first?.date {
                    AxisValueLabel(anchor: value == positions.first ? .topLeading : value == positions.last ? .topTrailing : .top) { Text(calendarLabel(first: first, offset: value)).font(.system(size: 11)) }
                }
            }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartOverlay { proxy in
            ChartHoverOverlay(proxy: proxy, positions: positions, selection: $selection, onSelect: onSelect.map { callback in { index in callback(points[index].date) } }) { index in
                ChartTooltip(title: chartFullDate(points[index].date)) {
                    ForEach(DashboardMetric.allCases) { item in
                        HStack {
                            Text(item.label).foregroundStyle(.secondary)
                            Spacer(minLength: 10)
                            Text(formatted(item, points[index])).monospacedDigit().fontWeight(item == metric ? .semibold : .regular)
                        }
                    }
                    if onSelect != nil { Text("Clique ou appuie sur Entrée pour examiner cette journée.").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .focusable()
        .onMoveCommand { direction in selection = movedSelection(selection, highlighted: highlighted, direction: direction, count: points.count) }
        .onKeyPress(.return) {
            guard let onSelect, let index = selection ?? highlighted, points.indices.contains(index) else { return .ignored }
            onSelect(points[index].date); return .handled
        }
        .onExitCommand { selection = nil }
        .onChange(of: metric) { _, _ in selection = nil }
        .onChange(of: points.map(\.date)) { _, _ in selection = nil }
        .accessibilityLabel("Évolution des \(metric.label.lowercased()). Flèches pour parcourir les dates, Entrée pour examiner une journée.")
        .accessibilityAction(named: Text("Examiner cette journée")) {
            if let onSelect, let index = selection ?? highlighted ?? points.indices.last { onSelect(points[index].date) }
        }
    }
    private func formatted(_ metric: DashboardMetric, _ point: TrendPoint) -> String {
        if metric == .revenue { return Display.revenue(point, currency: currency) }
        guard let value = metric.value(point) else { return "Non disponible" }
        return metric == .revenue ? Display.money(value, currency: currency) : Display.number(value)
    }
}

struct InteractiveActivityChart: View {
    let days: [PlayerDay]
    @State private var selection: Int?
    init(days: [PlayerDay], initialSelection: Int? = nil) {
        self.days = days
        _selection = State(initialValue: initialSelection)
    }
    var body: some View {
        let positions = ChartInspection.dayPositions(days.map(\.id))
        Chart {
            ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                if positions.indices.contains(index), positions[index].isFinite {
                    RectangleMark(xStart: .value("Début", positions[index] - 0.35), xEnd: .value("Fin", positions[index] + 0.35), yStart: .value("Zéro", 0), yEnd: .value("Parties", day.completions)).foregroundStyle(.metrik)
                        .accessibilityLabel(chartFullDate(day.id)).accessibilityValue("\(day.completions) parties")
                }
            }
            if let selection, positions.indices.contains(selection), positions[selection].isFinite {
                RuleMark(x: .value("Date sélectionnée", positions[selection])).foregroundStyle(.secondary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3])).accessibilityHidden(true)
            }
        }
        .chartXScale(domain: chartDomain(positions))
        .chartXAxis {
            AxisMarks(values: ChartInspection.axisPositions(positions, limit: 3)) { axis in
                if let value = axis.as(Double.self), let first = days.first?.id {
                    AxisValueLabel(anchor: value == positions.first ? .topLeading : value == positions.last ? .topTrailing : .top) { Text(calendarLabel(first: first, offset: value)).font(.system(size: 11)) }
                }
            }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartOverlay { proxy in
            ChartHoverOverlay(proxy: proxy, positions: positions, selection: $selection) { index in
                ChartTooltip(title: chartFullDate(days[index].id)) {
                    HStack { Text("Parties terminées").foregroundStyle(.secondary); Spacer(); Text(days[index].completions.formatted()).monospacedDigit() }
                }
            }
        }
        .focusable()
        .onMoveCommand { direction in selection = movedSelection(selection, direction: direction, count: days.count) }
        .onExitCommand { selection = nil }
        .onChange(of: days.map(\.id)) { _, _ in selection = nil }
        .accessibilityLabel("Parties terminées par jour. Les jours sont espacés selon le calendrier.")
    }
}

private struct ChartHoverOverlay<Tooltip: View>: View {
    let proxy: ChartProxy
    let positions: [Double]
    @Binding var selection: Int?
    var onSelect: ((Int) -> Void)?
    @ViewBuilder let tooltip: (Int) -> Tooltip
    var body: some View {
        GeometryReader { geometry in
            if let anchor = proxy.plotFrame {
                let frame = geometry[anchor]
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard frame.contains(location) else { selection = nil; return }
                                selection = ChartInspection.nearestIndex(value: proxy.value(atX: location.x - frame.minX, as: Double.self), positions: positions)
                            case .ended: selection = nil
                            }
                        }
                        .gesture(SpatialTapGesture().onEnded { event in
                            guard frame.contains(event.location), let index = ChartInspection.nearestIndex(value: proxy.value(atX: event.location.x - frame.minX, as: Double.self), positions: positions) else { return }
                            selection = index; onSelect?(index)
                        })
                    if let selection, positions.indices.contains(selection), let x = proxy.position(forX: positions[selection]) {
                        let width = min(260.0, max(0, geometry.size.width - 16))
                        let pointX = frame.minX + x
                        let preferredX = pointX > geometry.size.width / 2 ? pointX - width - 12 : pointX + 12
                        tooltip(selection)
                            .frame(width: width)
                            .offset(x: min(max(8, preferredX), max(8, geometry.size.width - width - 8)), y: max(0, frame.minY))
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }
}
private struct ChartTooltip<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).fontWeight(.semibold)
            content()
        }.font(.system(size: 12)).padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.3)))
            .accessibilityElement(children: .combine)
    }
}
private func chartDomain(_ positions: [Double]) -> ClosedRange<Double> {
    let finite = positions.filter(\.isFinite)
    return (min(0, finite.min() ?? 0) - 0.5)...max(0.5, (finite.max() ?? 0) + 0.5)
}
private func calendarLabel(first: String, offset: Double) -> String {
    guard let date = Dates.parse(first + "T12:00:00Z") else { return first }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let components = calendar.dateComponents([.day, .month], from: date.addingTimeInterval(offset * 86400))
    return String(format: "%02d.%02d", components.day ?? 0, components.month ?? 0)
}
func chartFullDate(_ value: String) -> String {
    guard let date = Dates.parse(value + "T12:00:00Z") else { return value }
    var style = Date.FormatStyle(date: .long, time: .omitted)
    style.timeZone = .gmt
    return date.formatted(style)
}
private func movedSelection(_ current: Int?, highlighted: Int? = nil, direction: MoveCommandDirection, count: Int) -> Int? {
    guard count > 0 else { return nil }
    switch direction {
    case .left: return ChartInspection.movedIndex(hovered: current, highlighted: highlighted, offset: -1, count: count)
    case .right: return ChartInspection.movedIndex(hovered: current, highlighted: highlighted, offset: 1, count: count)
    default: return current
    }
}
