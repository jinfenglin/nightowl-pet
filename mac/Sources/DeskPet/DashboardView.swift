import Charts
import SwiftUI

/// Chart chrome & ink from the data-viz reference palette (light / dark steps).
private struct VizPalette {
    let surface, primary, secondary, muted, grid, axis, series: Color

    static func forScheme(_ scheme: ColorScheme) -> VizPalette {
        scheme == .dark
            ? VizPalette(surface: Color(hex: 0x1a1a19), primary: Color(hex: 0xf0efec), secondary: Color(hex: 0xc3c2b7),
                         muted: Color(hex: 0x898781), grid: Color(hex: 0x2c2c2a), axis: Color(hex: 0x383835),
                         series: Color(hex: 0x3987e5))
            : VizPalette(surface: Color(hex: 0xfcfcfb), primary: Color(hex: 0x0b0b0b), secondary: Color(hex: 0x52514e),
                         muted: Color(hex: 0x898781), grid: Color(hex: 0xe1e0d9), axis: Color(hex: 0xc3c2b7),
                         series: Color(hex: 0x2a78d6))
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

/// A plotted day; `segment` splits the line where days are missing.
private struct HPPoint: Identifiable {
    let date: Date
    let minHP: Int
    let segment: Int
    var id: Date { date }
}

struct DashboardView: View {
    @ObservedObject var history: HPHistory
    var now: Date = Date()

    @Environment(\.colorScheme) private var scheme
    @State private var showTable = false
    @State private var hovered: HPPoint?

    private static let windowDays = 30
    private static let lowLine = 30

    private var palette: VizPalette { .forScheme(scheme) }

    @AppStorage(Pref.language) private var language = AppLanguage.system.rawValue  // re-render on change
    private var locale: Locale { AppLanguage.locale }

    private var points: [HPPoint] {
        var segment = 0
        var previous: Date?
        return history.recent(Self.windowDays, until: now).map { day in
            if let previous, Calendar.current.dateComponents([.day], from: previous, to: day.date).day! > 1 {
                segment += 1
            }
            previous = day.date
            return HPPoint(date: day.date, minHP: day.minHP, segment: segment)
        }
    }

    private var domain: ClosedRange<Date> {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let start = cal.date(byAdding: .day, value: -(Self.windowDays - 1), to: today)!
        // whole days: `unit: .day` marks sit at midday, so this leaves half a day of air at each end
        return start...cal.date(byAdding: .day, value: 1, to: today)!
    }

    var body: some View {
        let points = points
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("每日最低血量", "Daily Minimum HP"))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(palette.primary)
                    Text(L("最近 \(Self.windowDays) 天 · 每天取当天的最低 HP", "Last \(Self.windowDays) days · lowest HP of each day"))
                        .font(.callout)
                        .foregroundStyle(palette.secondary)
                }
                Spacer()
                Picker("", selection: $showTable) {
                    Text(L("图表", "Chart")).tag(false)
                    Text(L("表格", "Table")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if points.isEmpty {
                Text(L("还没有数据。DeskPet 每天会记录一次最低血量，明天再来看看吧。", "No data yet. DeskPet records the lowest HP once a day. Check back tomorrow."))
                    .foregroundStyle(palette.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                stats(points)
                if showTable {
                    table(points)
                } else {
                    chart(points)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 460)
        .background(palette.surface)
        .environment(\.locale, locale)  // chart axis dates
    }

    // MARK: - Stat tiles

    private func stats(_ points: [HPPoint]) -> some View {
        let today = points.last { Calendar.current.isDate($0.date, inSameDayAs: now) }
        let average = Double(points.map(\.minHP).reduce(0, +)) / Double(points.count)
        let worst = points.min { $0.minHP < $1.minHP }!
        let lowDays = points.filter { $0.minHP < Self.lowLine }.count
        return HStack(spacing: 12) {
            statTile(L("今天最低", "Today's low"), today.map { "\($0.minHP)" } ?? "—", nil)
            statTile(L("\(Self.windowDays) 天平均", "\(Self.windowDays)-day average"), String(format: "%.0f", average), L("\(points.count) 天有记录", points.count == 1 ? "1 day recorded" : "\(points.count) days recorded"))
            statTile(L("最低的一天", "Worst day"), "\(worst.minHP)", worst.date.formatted(.dateTime.month(.defaultDigits).day().locale(locale)))
            statTile(L("低于残血线", "Below low line"), L("\(lowDays) 天", lowDays == 1 ? "1 day" : "\(lowDays) days"), "HP < \(Self.lowLine)")
        }
    }

    private func statTile(_ label: String, _ value: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(palette.secondary)
            Text(value).font(.system(size: 26, weight: .semibold)).foregroundStyle(palette.primary)
            Text(detail ?? " ").font(.caption).foregroundStyle(palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).stroke(palette.grid, lineWidth: 1))
    }

    // MARK: - Chart

    private func chart(_ points: [HPPoint]) -> some View {
        let latest = points.last!
        let worst = points.min { $0.minHP < $1.minHP }!
        return Chart {
            RuleMark(y: .value(L("残血线", "Low line"), Self.lowLine))
                .foregroundStyle(palette.axis)
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, alignment: .leading, spacing: 2) {
                    Text(L("残血线 \(Self.lowLine)", "Low line \(Self.lowLine)")).font(.caption2).foregroundStyle(palette.muted)
                }

            ForEach(points) { p in
                LineMark(x: .value(L("日期", "Date"), p.date, unit: .day),
                         y: .value(L("最低血量", "Min HP"), p.minHP),
                         series: .value(L("段", "Segment"), p.segment))
                    .foregroundStyle(palette.series)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                PointMark(x: .value(L("日期", "Date"), p.date, unit: .day), y: .value(L("最低血量", "Min HP"), p.minHP))
                    .symbol {
                        Circle()
                            .fill(palette.series)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(palette.surface, lineWidth: 2))
                    }
                    .annotation(position: .top, spacing: 6) {
                        // direct labels only on the latest and the lowest day
                        if p.id == latest.id || (p.id == worst.id && worst.minHP < latest.minHP) {
                            Text("\(p.minHP)").font(.caption.weight(.semibold)).foregroundStyle(palette.primary)
                        }
                    }
            }

            if let hovered {
                RuleMark(x: .value(L("日期", "Date"), hovered.date, unit: .day))
                    .foregroundStyle(palette.muted)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(hovered)
                    }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(palette.grid)
                AxisValueLabel().foregroundStyle(palette.muted)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) {
                AxisTick(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(palette.axis)
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day()).foregroundStyle(palette.muted)
            }
        }
        .chartPlotStyle { plot in
            plot.overlay(alignment: .bottom) { Rectangle().fill(palette.axis).frame(height: 1) }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let location) = phase, let plot = proxy.plotFrame,
                              let date: Date = proxy.value(atX: location.x - geo[plot].origin.x) else {
                            hovered = nil
                            return
                        }
                        hovered = points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                    }
            }
        }
        .padding(.top, 52)  // room for the tooltip above the plot
    }

    private func tooltip(_ p: HPPoint) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Capsule().fill(palette.series).frame(width: 12, height: 2)
                Text("\(p.minHP)").font(.callout.weight(.bold)).foregroundStyle(palette.primary)
                Text(L("最低血量", "Min HP")).font(.caption).foregroundStyle(palette.secondary)
            }
            Text(p.date.formatted(.dateTime.month(.defaultDigits).day().weekday(.abbreviated).locale(locale)))
                .font(.caption)
                .foregroundStyle(palette.muted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.grid, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }

    // MARK: - Table view

    private func table(_ points: [HPPoint]) -> some View {
        Table(points.reversed()) {
            TableColumn(L("日期", "Date")) { p in
                Text(p.date.formatted(.dateTime.year().month(.defaultDigits).day().weekday(.abbreviated).locale(locale)))
            }
            TableColumn(L("最低血量", "Min HP")) { p in
                Text("\(p.minHP)").monospacedDigit()
            }
            TableColumn("") { p in
                Text(p.minHP < Self.lowLine ? L("低于残血线", "Below low line") : "").foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
enum DashboardWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: DashboardView(history: .shared)))
            w.title = title
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 720, height: 500))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private static var title: String { L("血量看板", "HP Dashboard") }

    static func refreshTitle() { window?.title = title }
}
