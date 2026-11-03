import SwiftUI
import Charts

/// Muted categorical colours, used only to tell Wi-Fi networks apart.
enum NetColors {
    static let palette: [Color] = [
        Color(red: 0.38, green: 0.64, blue: 1.00), Color(red: 0.36, green: 0.80, blue: 0.74),
        Color(red: 0.96, green: 0.74, blue: 0.38), Color(red: 0.92, green: 0.54, blue: 0.66),
        Color(red: 0.64, green: 0.58, blue: 0.95), Color(red: 0.62, green: 0.78, blue: 0.45),
        Color(red: 0.70, green: 0.76, blue: 0.86),
    ]
    static let unknown = Color(red: 0.45, green: 0.48, blue: 0.55)

    static func color(_ ssid: String, order: [String]) -> Color {
        if ssid.hasPrefix("Wi-Fi (") { return unknown }
        guard let i = order.firstIndex(of: ssid) else { return unknown }
        return palette[i % palette.count]
    }
}

struct HistoryView: View {
    @EnvironmentObject var monitor: NetworkMonitor

    enum Preset: String, CaseIterable, Identifiable {
        case week = "7 days", month = "30 days", quarter = "90 days", year = "1 year", all = "All"
        var id: String { rawValue }
    }

    private static var today: Date { Calendar.current.startOfDay(for: Date()) }

    @State private var preset: Preset = .month
    @State private var from = Calendar.current.date(byAdding: .day, value: -29, to: HistoryView.today)!
    @State private var to = HistoryView.today
    @State private var selectedDay = HistoryView.today
    @State private var hoverDate: Date?

    @State private var rangeData: [NetDay] = []   // daily, per network
    @State private var dayData: [NetDay] = []     // hourly, per network (selected day)
    @State private var dayApps: [AppUsage] = []
    @State private var order: [String] = []

    private var cal: Calendar { Calendar.current }
    private var rangeEnd: Date { cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: to))! }

    // MARK: Derived

    private var spanDays: Int { max(cal.dateComponents([.day], from: from, to: rangeEnd).day ?? 1, 1) }
    private var chartComponent: Calendar.Component { spanDays <= 120 ? .day : (spanDays <= 400 ? .weekOfYear : .month) }
    private var chartData: [NetDay] { chartComponent == .day ? rangeData : Self.aggregate(rangeData, by: chartComponent) }
    private var rangeTotal: Double { rangeData.reduce(0) { $0 + $1.total } }

    static func aggregate(_ days: [NetDay], by comp: Calendar.Component) -> [NetDay] {
        let cal = Calendar.current
        var map: [String: NetDay] = [:]
        for d in days {
            let key = cal.dateInterval(of: comp, for: d.date)?.start ?? d.date
            let k = "\(key.timeIntervalSince1970)|\(d.ssid)"
            var e = map[k] ?? NetDay(date: key, ssid: d.ssid, down: 0, up: 0)
            e.down += d.down; e.up += d.up
            map[k] = e
        }
        return map.values.sorted { $0.date < $1.date }
    }

    private var dayGroups: [(date: Date, nets: [NetDay], total: Double)] {
        Dictionary(grouping: rangeData, by: \.date)
            .map { (date: $0.key, nets: $0.value.sorted { $0.total > $1.total }, total: $0.value.reduce(0) { $0 + $1.total }) }
            .sorted { $0.date > $1.date }
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                PageHeader(title: "History", subtitle: "Pick any date to see where you were and what you used", icon: "calendar")
                controls
                rangeChart
                dayDetail
                dailyLog
            }
            .padding(26)
        }
        .task(id: "\(from.timeIntervalSince1970)|\(to.timeIntervalSince1970)|\(selectedDay.timeIntervalSince1970)|\(monitor.dataVersion)") { await load() }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 14) {
            SlidingPicker(items: Preset.allCases, selection: Binding(get: { preset }, set: { applyPreset($0) })) { $0.rawValue }
            Spacer()
            HStack(spacing: 8) {
                Text("From").font(.caption).foregroundStyle(.secondary)
                DayPickerButton(date: Binding(get: { from }, set: { from = cal.startOfDay(for: $0); if from > to { to = from } }))
                Text("to").font(.caption).foregroundStyle(.secondary)
                DayPickerButton(date: Binding(get: { to }, set: { to = cal.startOfDay(for: $0); if to < from { from = to } }))
            }
        }
    }

    private func applyPreset(_ p: Preset) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            preset = p
            let today = Self.today
            to = today
            switch p {
            case .week: from = cal.date(byAdding: .day, value: -6, to: today)!
            case .month: from = cal.date(byAdding: .day, value: -29, to: today)!
            case .quarter: from = cal.date(byAdding: .day, value: -89, to: today)!
            case .year: from = cal.date(byAdding: .day, value: -364, to: today)!
            case .all: from = monitor.usage.trackedRange().map { cal.startOfDay(for: $0.0) } ?? cal.date(byAdding: .day, value: -29, to: today)!
            }
        }
    }

    // MARK: Range chart

    private var hovered: (date: Date, nets: [NetDay])? {
        guard let hoverDate else { return nil }
        let nearest = chartData.map(\.date).min { abs($0.timeIntervalSince(hoverDate)) < abs($1.timeIntervalSince(hoverDate)) }
        guard let nearest else { return nil }
        return (nearest, chartData.filter { $0.date == nearest }.sorted { $0.total > $1.total })
    }

    private var rangeChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(title: "Usage by day and network", subtitle: "\(Fmt.shortDate.string(from: from)) – \(Fmt.shortDate.string(from: to)) · \(Fmt.bytes(rangeTotal)) total · click a bar to open that day", icon: "chart.bar.xaxis")
            }
            if rangeData.isEmpty {
                EmptyState(icon: "calendar.badge.clock", title: "No data in this range", message: "DataLens only has data from the day it started tracking. Try a later range.")
                    .frame(height: 240)
            } else {
                Chart {
                    ForEach(chartData) { d in
                        BarMark(x: .value("Date", d.date, unit: chartComponent), y: .value("Bytes", d.total), width: .ratio(0.72))
                            .foregroundStyle(by: .value("Network", d.ssid))
                            .cornerRadius(3)
                    }
                    RuleMark(x: .value("Selected", selectedDay, unit: .day))
                        .foregroundStyle(Color.white.opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    if let h = hovered {
                        RuleMark(x: .value("Hover", h.date, unit: chartComponent))
                            .foregroundStyle(Color.white.opacity(0.3))
                            .annotation(position: .top, spacing: 6, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(h.date.formatted(.dateTime.weekday(.abbreviated).day().month().year())).font(.caption.weight(.semibold))
                                    ForEach(h.nets) { n in
                                        HStack(spacing: 5) {
                                            Circle().fill(NetColors.color(n.ssid, order: order)).frame(width: 7, height: 7)
                                            Text("\(n.ssid)  \(Fmt.bytes(n.total))").font(.caption2.monospacedDigit())
                                        }
                                    }
                                }
                                .padding(8).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                            }
                    }
                }
                .chartForegroundStyleScale(domain: order, range: order.map { NetColors.color($0, order: order) })
                .chartXSelection(value: $hoverDate)
                .chartYAxis {
                    AxisMarks { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4])).foregroundStyle(Color.white.opacity(0.12))
                        AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.bytes(d)).font(.caption2) } }
                    }
                }
                .chartLegend(position: .top, alignment: .leading)
                .frame(height: 280)
                .onTapGesture {
                    if let h = hovered, chartComponent == .day {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { selectedDay = h.date }
                    }
                }
            }
        }
        .card()
    }

    // MARK: Day detail

    private var dayTotal: Double { dayData.reduce(0) { $0 + $1.total } }

    /// Dominant network for each hour of the selected day.
    private var hourly: [Int: NetDay] {
        var best: [Int: NetDay] = [:]
        for d in dayData {
            let h = cal.component(.hour, from: d.date)
            if d.total > (best[h]?.total ?? -1) { best[h] = d }
        }
        return best
    }

    private struct Segment: Identifiable {
        let id = UUID()
        let ssid: String
        let startHour: Int
        var endHour: Int
        var bytes: Double
    }

    private var segments: [Segment] {
        var out: [Segment] = []
        for h in 0..<24 {
            guard let d = hourly[h] else { continue }
            let hourBytes = dayData.filter { cal.component(.hour, from: $0.date) == h }.reduce(0) { $0 + $1.total }
            if var last = out.last, last.ssid == d.ssid, last.endHour == h - 1 {
                last.endHour = h; last.bytes += hourBytes
                out[out.count - 1] = last
            } else {
                out.append(Segment(ssid: d.ssid, startHour: h, endHour: h, bytes: hourBytes))
            }
        }
        return out
    }

    private var dayNetworks: [(ssid: String, hours: Int, down: Double, up: Double)] {
        Dictionary(grouping: dayData, by: \.ssid).map { k, v in
            (ssid: k, hours: Set(v.map { cal.component(.hour, from: $0.date) }).count, down: v.reduce(0) { $0 + $1.down }, up: v.reduce(0) { $0 + $1.up })
        }.sorted { $0.down + $0.up > $1.down + $1.up }
    }

    private var dayDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Button { shiftDay(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(GlowButtonStyle(color: Theme.blue))
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedDay.formatted(.dateTime.weekday(.wide).day().month(.wide).year())).font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(dayData.isEmpty ? "No data recorded" : "\(Fmt.bytes(dayTotal)) used · \(segments.count) place\(segments.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                }
                Button { shiftDay(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(GlowButtonStyle(color: Theme.blue))
                    .disabled(cal.isDateInToday(selectedDay))
                Spacer()
                DayPickerButton(date: Binding(get: { selectedDay }, set: { selectedDay = cal.startOfDay(for: $0) }))
                Button("Today") { withAnimation { selectedDay = Self.today } }.buttonStyle(GlowButtonStyle(color: Theme.cyan))
            }

            if dayData.isEmpty {
                EmptyState(icon: "moon.zzz", title: "Nothing recorded this day", message: "DataLens wasn't running, or the Mac was off or asleep.")
                    .frame(height: 160)
            } else {
                // where were you
                VStack(alignment: .leading, spacing: 6) {
                    Text("Where you were").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                    HStack(spacing: 2) {
                        ForEach(0..<24, id: \.self) { h in
                            let d = hourly[h]
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(d.map { NetColors.color($0.ssid, order: order) } ?? Color.white.opacity(0.05))
                                .frame(height: 26)
                                .help(d.map { "\(String(format: "%02d", h)):00 · \($0.ssid) · \(Fmt.bytes($0.total))" } ?? "\(String(format: "%02d", h)):00 · no data")
                        }
                    }
                    HStack {
                        ForEach([0, 3, 6, 9, 12, 15, 18, 21], id: \.self) { h in
                            Text(String(format: "%02d", h)).font(.system(size: 9)).foregroundStyle(.secondary)
                            Spacer()
                        }
                        Text("24").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }

                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(segments) { s in
                            HStack(spacing: 8) {
                                Circle().fill(NetColors.color(s.ssid, order: order)).frame(width: 8, height: 8)
                                Text("\(String(format: "%02d", s.startHour)):00 – \(String(format: "%02d", s.endHour + 1)):00").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(s.ssid).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                                Spacer()
                                Text(Fmt.bytes(s.bytes)).font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("By network").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                        ForEach(dayNetworks, id: \.ssid) { n in
                            HStack(spacing: 8) {
                                Circle().fill(NetColors.color(n.ssid, order: order)).frame(width: 8, height: 8)
                                Text(n.ssid).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                                Text("\(n.hours) h").font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Text("↓ \(Fmt.bytes(n.down))").foregroundStyle(Theme.cyan)
                                Text("↑ \(Fmt.bytes(n.up))").foregroundStyle(Theme.pink)
                            }
                            .font(.system(size: 11).monospacedDigit())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // hourly chart
                Chart(dayData) { d in
                    BarMark(x: .value("Hour", d.date, unit: .hour), y: .value("Bytes", d.total), width: .ratio(0.8))
                        .foregroundStyle(by: .value("Network", d.ssid))
                        .cornerRadius(3)
                }
                .chartForegroundStyleScale(domain: order, range: order.map { NetColors.color($0, order: order) })
                .chartXScale(domain: selectedDay...cal.date(byAdding: .day, value: 1, to: selectedDay)!)
                .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 3)) { _ in AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted))) } }
                .chartYAxis {
                    AxisMarks { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4])).foregroundStyle(Color.white.opacity(0.12))
                        AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.bytes(d)).font(.caption2) } }
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 180)

                if !dayApps.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Top apps that day").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                        let sum = max(dayApps.reduce(0) { $0 + $1.total }, 1)
                        ForEach(Array(dayApps.prefix(6).enumerated()), id: \.element.id) { i, a in
                            AppRow(app: a, share: a.total / sum, color: Theme.color(at: i), rank: i)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func shiftDay(_ delta: Int) {
        if let d = cal.date(byAdding: .day, value: delta, to: selectedDay), d <= Self.today {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { selectedDay = d }
        }
    }

    // MARK: Daily log

    private var dailyLog: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Daily log", subtitle: "Date · networks · data used", icon: "list.bullet.rectangle")
            if dayGroups.isEmpty { Text("No days in this range.").font(.caption).foregroundStyle(.secondary) }
            LazyVStack(spacing: 2) {
                ForEach(dayGroups.prefix(400), id: \.date) { g in
                    DayLogRow(date: g.date, nets: g.nets, total: g.total, order: order, selected: cal.isDate(g.date, inSameDayAs: selectedDay), maxTotal: dayGroups.map(\.total).max() ?? 1)
                        .onTapGesture { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { selectedDay = g.date } }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: Loading

    private func load() async {
        let db = monitor.usage
        let (f, e, day) = (from, rangeEnd, selectedDay)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: day)!
        let r = await Task.detached { () -> ([NetDay], [NetDay], [AppUsage], [String]) in
            let range = db.usageBySSID(from: f, to: e, component: .day)
            let hours = db.usageBySSID(from: day, to: dayEnd, component: .hour)
            let apps = db.appsBetween(from: day, to: dayEnd)
            let order = db.networks().map(\.ssid)   // stable: biggest lifetime network first
            return (range, hours, apps, order)
        }.value
        withAnimation(.easeInOut(duration: 0.5)) {
            rangeData = r.0; dayData = r.1; dayApps = r.2; order = r.3
        }
    }
}

struct DayLogRow: View {
    let date: Date
    let nets: [NetDay]
    let total: Double
    let order: [String]
    let selected: Bool
    let maxTotal: Double
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Text(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()))
                .font(.system(size: 12, weight: .semibold, design: .rounded)).frame(width: 130, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    ForEach(nets.prefix(4)) { n in
                        HStack(spacing: 4) {
                            Circle().fill(NetColors.color(n.ssid, order: order)).frame(width: 7, height: 7)
                            Text(n.ssid).lineLimit(1)
                            Text(Fmt.bytes(n.total)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.system(size: 11))
                    }
                    if nets.count > 4 { Text("+\(nets.count - 4)").font(.caption2).foregroundStyle(.secondary) }
                }
                GeometryReader { g in
                    HStack(spacing: 1) {
                        ForEach(nets) { n in
                            Rectangle().fill(NetColors.color(n.ssid, order: order)).frame(width: g.size.width * n.total / max(maxTotal, 1))
                        }
                        Spacer(minLength: 0)
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 4)
            }
            Spacer()
            Text(Fmt.bytes(total)).font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(selected ? 0.10 : (hover ? 0.05 : 0))))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Theme.cyan.opacity(0.6) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}


// MARK: - Themed calendar

struct DayPickerButton: View {
    @Binding var date: Date
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: "calendar").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                Text(date.formatted(.dateTime.day().month(.abbreviated).year())).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.07)))
            .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            MonthCalendar(selection: $date) { open = false }
        }
    }
}

struct MonthCalendar: View {
    @Binding var selection: Date
    var onPick: () -> Void
    @State private var month: Date = Date()
    private let cal = Calendar.current

    private var days: [Date?] {
        guard let start = cal.date(from: cal.dateComponents([.year, .month], from: month)),
              let range = cal.range(of: .day, in: .month, for: start) else { return [] }
        let lead = (cal.component(.weekday, from: start) - cal.firstWeekday + 7) % 7
        return Array(repeating: nil, count: lead) + range.compactMap { cal.date(byAdding: .day, value: $0 - 1, to: start) }
    }

    private var isCurrentMonth: Bool { cal.isDate(month, equalTo: Date(), toGranularity: .month) }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year())).font(.system(size: 14, weight: .bold, design: .rounded))
                Spacer()
                navButton("chevron.left") { shift(-1) }
                navButton("chevron.right") { shift(1) }.disabled(isCurrentMonth).opacity(isCurrentMonth ? 0.3 : 1)
            }
            let symbols = cal.veryShortWeekdaySymbols
            let order = (0..<7).map { symbols[(cal.firstWeekday - 1 + $0) % 7] }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 4), count: 7), spacing: 4) {
                ForEach(Array(order.enumerated()), id: \.offset) { _, s in
                    Text(s).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(height: 18)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { _, d in
                    if let d { dayCell(d) } else { Color.clear.frame(height: 32) }
                }
            }
            Button("Today") { selection = Date(); onPick() }.buttonStyle(GlowButtonStyle(color: Theme.cyan))
        }
        .padding(14)
        .frame(width: 270)
        .onAppear { month = selection }
    }

    private func navButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold)).frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }.buttonStyle(.plain)
    }

    private func dayCell(_ d: Date) -> some View {
        let selected = cal.isDate(d, inSameDayAs: selection)
        let future = d > Date()
        let today = cal.isDateInToday(d)
        return Button { selection = d; onPick() } label: {
            Text("\(cal.component(.day, from: d))")
                .font(.system(size: 12, weight: selected ? .bold : .medium, design: .rounded)).monospacedDigit()
                .foregroundStyle(selected ? Color.white : (future ? Color.secondary.opacity(0.4) : Color.primary))
                .frame(width: 32, height: 32)
                .background(Circle().fill(selected ? Theme.blue : Color.clear))
                .overlay(Circle().stroke(today && !selected ? Theme.blue : Color.clear, lineWidth: 1.2))
        }
        .buttonStyle(.plain).disabled(future)
    }

    private func shift(_ n: Int) {
        if let m = cal.date(byAdding: .month, value: n, to: month) { withAnimation(.easeInOut(duration: 0.15)) { month = m } }
    }
}
