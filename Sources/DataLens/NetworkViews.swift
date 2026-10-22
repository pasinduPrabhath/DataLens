import SwiftUI
import Charts
import CoreLocation

// MARK: - Segmented control with sliding highlight

struct SlidingPicker<T: Hashable & Identifiable>: View {
    let items: [T]
    @Binding var selection: T
    var label: (T) -> String
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                Text(label(item))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(selection == item ? Color.white : Color.secondary)
                    .padding(.horizontal, 13).padding(.vertical, 7)
                    .background {
                        if selection == item {
                            Capsule().fill(Theme.accent).matchedGeometryEffect(id: "sel", in: ns)
                                .shadow(color: Theme.blue.opacity(0.5), radius: 8)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture { withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { selection = item } }
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }
}

// MARK: - Network usage page

struct NetworkUsageView: View {
    @EnvironmentObject var store: NetStore
    @EnvironmentObject var monitor: NetworkMonitor
    @State private var selDate: Date?
    @State private var detailApp: AppUsage?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                PageHeader(title: "Wi-Fi Data Usage", subtitle: "Every network you join, every app that used it", icon: "wifi")

                banners

                HStack {
                    networkChips
                    Spacer()
                    SlidingPicker(items: Period.allCases, selection: $store.period) { $0.short }
                }

                kpis
                usageChart
                HStack(alignment: .top, spacing: 18) {
                    appsCard
                    VStack(spacing: 18) {
                        budgetCard
                        insightsCard
                    }
                    .frame(width: 330)
                }
                HStack(alignment: .top, spacing: 18) {
                    heatmapCard
                    networksCard.frame(width: 330)
                }
            }
            .padding(26)
        }
        .sheet(item: $detailApp) { app in
            AppDetailSheet(app: app).environmentObject(store)
        }
    }

    // MARK: Banners

    @ViewBuilder private var banners: some View {
        if !monitor.ssidAccessible {
            BannerView(icon: "location.fill", title: "Allow Location so DataLens can read the Wi-Fi name",
                       message: "macOS hides network names from apps unless Location Services is allowed. Until then, traffic is filed under “Wi-Fi (name hidden)”. DataLens never reads your location.",
                       color: Theme.orange, actionTitle: "Allow…") {
                if monitor.locationStatus == .notDetermined { monitor.requestLocation() }
                else { PermissionLinks.openLocationSettings() }
            }
        }
    }

    // MARK: Network chips

    private var networkChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All Networks", icon: "square.stack.3d.up.fill", selected: store.selectedSSID == nil) { store.selectedSSID = nil }
                ForEach(store.snap.networks) { n in
                    chip(title: n.ssid, icon: "wifi",
                         selected: store.selectedSSID == n.ssid) { store.selectedSSID = n.ssid }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: 560)
    }

    private func chip(title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { action() } }) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                Text(title).lineLimit(1)
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(selected ? Theme.blue.opacity(0.45) : Color.white.opacity(0.06)))
            .overlay(Capsule().strokeBorder(selected ? Theme.cyan.opacity(0.8) : Color.white.opacity(0.1), lineWidth: 1))
            .foregroundStyle(selected ? Color.white : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: KPIs

    private var kpis: some View {
        let avg = store.total / store.daysInPeriod
        return HStack(spacing: 14) {
            StatTile(title: "Total", value: store.total, format: { Fmt.bytes($0) }, icon: "sum", color: Theme.blue,
                     footnote: "\(store.period.rawValue) · \(store.selectedSSID ?? "all networks")")
            StatTile(title: "Downloaded", value: store.snap.down, format: { Fmt.bytes($0) }, icon: "arrow.down.circle.fill", color: Theme.cyan,
                     footnote: store.total > 0 ? Fmt.percent(store.snap.down / store.total) + " of total" : nil)
            StatTile(title: "Uploaded", value: store.snap.up, format: { Fmt.bytes($0) }, icon: "arrow.up.circle.fill", color: Theme.pink,
                     footnote: store.total > 0 ? Fmt.percent(store.snap.up / store.total) + " of total" : nil)
            StatTile(title: "Daily average", value: avg, format: { Fmt.bytes($0) }, icon: "gauge.with.dots.needle.50percent", color: Theme.purple,
                     footnote: "per day")
        }
    }

    // MARK: Chart

    private var selectedPoint: SeriesPoint? {
        guard let selDate else { return nil }
        return store.snap.series.min { abs($0.date.timeIntervalSince(selDate)) < abs($1.date.timeIntervalSince(selDate)) }
    }

    private var tooltipFormat: Date.FormatStyle {
        switch store.snap.bucket {
        case .hour: return .dateTime.day().month().hour()
        case .day: return .dateTime.weekday(.abbreviated).day().month()
        case .month: return .dateTime.month(.wide).year()
        }
    }

    private var usageChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Usage over time", subtitle: "Hover to inspect · stacked download / upload", icon: "chart.bar.xaxis")
            if store.total == 0 {
                EmptyState(icon: "waveform.path.ecg", title: "Collecting data…",
                           message: "DataLens measures every byte on Wi-Fi while it runs. Use the network for a bit and charts fill in.")
                    .frame(height: 260)
            } else {
                Chart {
                    ForEach(store.snap.series) { p in
                        BarMark(x: .value("Time", p.date, unit: store.snap.bucket.component),
                                y: .value("Bytes", p.down), width: .ratio(0.72))
                            .foregroundStyle(by: .value("Direction", "Download"))
                            .cornerRadius(4)
                        BarMark(x: .value("Time", p.date, unit: store.snap.bucket.component),
                                y: .value("Bytes", p.up), width: .ratio(0.72))
                            .foregroundStyle(by: .value("Direction", "Upload"))
                            .cornerRadius(4)
                    }
                    if let s = selectedPoint {
                        RuleMark(x: .value("Selected", s.date, unit: store.snap.bucket.component))
                            .foregroundStyle(Color.white.opacity(0.35))
                            .annotation(position: .top, spacing: 6, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(s.date.formatted(tooltipFormat)).font(.caption.weight(.semibold))
                                    Text("↓ \(Fmt.bytes(s.down))   ↑ \(Fmt.bytes(s.up))").font(.caption2.monospacedDigit())
                                    Text("Total \(Fmt.bytes(s.total))").font(.caption2).foregroundStyle(.secondary)
                                }
                                .padding(8)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                            }
                    }
                }
                .chartForegroundStyleScale(domain: ["Download", "Upload"], range: [Theme.cyan, Theme.pink])
                .chartXSelection(value: $selDate)
                .chartYAxis {
                    AxisMarks { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4])).foregroundStyle(Color.white.opacity(0.12))
                        AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.bytes(d)).font(.caption2) } }
                    }
                }
                .chartLegend(position: .top, alignment: .trailing)
                .frame(height: 280)
            }
        }
        .card()
    }

    // MARK: Apps

    private var appsCard: some View {
        let apps = store.snap.apps
        let sum = max(apps.reduce(0) { $0 + $1.total }, 1)
        let top = Array(apps.prefix(8))
        let other = apps.dropFirst(8).reduce(0) { $0 + $1.total }
        return VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "Which apps used your data", subtitle: "Tap an app for its own history", icon: "app.badge.fill")
            if apps.isEmpty {
                EmptyState(icon: "app.dashed", title: "No app data yet", message: "Per-app counters appear a few seconds after traffic flows.")
                    .frame(height: 200)
            } else {
                HStack(alignment: .center, spacing: 20) {
                    Chart {
                        ForEach(Array(top.enumerated()), id: \.element.id) { i, a in
                            SectorMark(angle: .value("Bytes", a.total), innerRadius: .ratio(0.62), angularInset: 2)
                                .cornerRadius(5)
                                .foregroundStyle(Theme.color(at: i))
                        }
                        if other > 0 {
                            SectorMark(angle: .value("Bytes", other), innerRadius: .ratio(0.62), angularInset: 2)
                                .cornerRadius(5)
                                .foregroundStyle(Color.gray.opacity(0.5))
                        }
                    }
                    .frame(width: 190, height: 190)
                    .chartBackground { _ in
                        VStack(spacing: 1) {
                            Text("Apps").font(.caption).foregroundStyle(.secondary)
                            Text(Fmt.bytes(sum)).font(.system(size: 17, weight: .bold, design: .rounded))
                        }
                    }
                    VStack(spacing: 6) {
                        ForEach(Array(top.enumerated()), id: \.element.id) { i, a in
                            AppRow(app: a, share: a.total / sum, color: Theme.color(at: i), rank: i)
                                .onTapGesture { detailApp = a }
                        }
                    }
                }
                if apps.count > 8 {
                    DisclosureGroup("All \(apps.count) apps") {
                        VStack(spacing: 6) {
                            ForEach(Array(apps.dropFirst(8).enumerated()), id: \.element.id) { i, a in
                                AppRow(app: a, share: a.total / sum, color: .gray, rank: i + 8)
                                    .onTapGesture { detailApp = a }
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.caption)
                }
            }
        }
        .card()
    }

    // MARK: Budget

    private var budgetCard: some View {
        let cap = store.capGB * 1e9
        let cal = Calendar.current
        let day = Double(cal.component(.day, from: Date()))
        let dim = Double(cal.range(of: .day, in: .month, for: Date())?.count ?? 30)
        let projected = store.snap.monthTotal / max(day, 1) * dim
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Monthly budget", subtitle: store.selectedSSID ?? "All networks", icon: "target")
            HStack(spacing: 18) {
                RingGauge(progress: cap > 0 ? store.snap.monthTotal / cap : 0,
                          colors: (cap > 0 && store.snap.monthTotal / cap > 0.9) ? [Theme.orange, Theme.red] : [Theme.cyan, Theme.purple],
                          lineWidth: 12) {
                    VStack(spacing: 0) {
                        Text(cap > 0 ? Fmt.percent(store.snap.monthTotal / cap) : "—")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        Text("used").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(Fmt.bytes(store.snap.monthTotal)) this month").font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text("On track for \(Fmt.bytes(projected))").font(.caption).foregroundStyle(.secondary)
                    if cap > 0 && projected > cap {
                        Pill(text: "Projected over by \(Fmt.bytes(projected - cap))", color: Theme.red)
                    } else if cap > 0 {
                        Pill(text: "Within budget", color: Theme.green)
                    }
                }
            }
            HStack {
                Text("Cap").font(.caption).foregroundStyle(.secondary)
                Slider(value: $store.capGB, in: 0...2000, step: 10)
                Text(store.capGB == 0 ? "Off" : "\(Int(store.capGB)) GB").font(.caption.monospacedDigit()).frame(width: 54, alignment: .trailing)
            }
        }
        .card()
    }

    private var insightsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Insights", icon: "sparkles")
            let list = store.insights
            if list.isEmpty {
                Text("Insights appear once there is some traffic to analyse.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(list.enumerated()), id: \.offset) { _, ins in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: ins.icon).foregroundStyle(ins.color).frame(width: 18)
                    Text(ins.text).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: Heatmap

    private var heatmapCard: some View {
        let maxV = max(store.snap.heat.map(\.bytes).max() ?? 1, 1)
        let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "When you use data", subtitle: "Weekday × hour (last 4+ weeks)", icon: "square.grid.3x3.fill")
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .trailing, spacing: 3) {
                    ForEach(0..<7, id: \.self) { d in
                        Text(days[d]).font(.system(size: 9)).foregroundStyle(.secondary).frame(height: 18)
                    }
                }
                .padding(.top, 0)
                VStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { d in
                        HStack(spacing: 3) {
                            ForEach(0..<24, id: \.self) { h in
                                let v = store.snap.heat.first(where: { $0.id == d * 24 + h })?.bytes ?? 0
                                HeatSquare(value: v, maxValue: maxV, label: "\(days[d]) \(String(format: "%02d", h)):00 — \(Fmt.bytes(v))")
                            }
                        }
                    }
                    HStack {
                        ForEach([0, 6, 12, 18, 23], id: \.self) { h in
                            Text(String(format: "%02d", h)).font(.system(size: 9)).foregroundStyle(.secondary)
                            if h != 23 { Spacer() }
                        }
                    }
                }
            }
        }
        .card()
    }

    // MARK: Networks

    private var networksCard: some View {
        let nets = store.snap.networks
        let maxV = max(nets.first?.total ?? 1, 1)
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "All networks · lifetime", subtitle: "Since DataLens started tracking", icon: "wifi.circle.fill")
            if nets.isEmpty {
                Text("No networks recorded yet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(nets.enumerated()), id: \.element.id) { i, n in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Image(systemName: "wifi")
                            .foregroundStyle(Theme.color(at: i))
                        Text(n.ssid).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                        Spacer()
                        Text(Fmt.bytes(n.total)).font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.07))
                            Capsule().fill(LinearGradient(colors: [Theme.color(at: i), Theme.color(at: i).opacity(0.5)], startPoint: .leading, endPoint: .trailing))
                                .frame(width: g.size.width * n.total / maxV)
                        }
                    }
                    .frame(height: 6)
                    Text("since \(Fmt.shortDate.string(from: n.first)) · last \(Fmt.shortDate.string(from: n.last))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { store.selectedSSID = n.ssid }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

// MARK: - Subviews

struct HeatSquare: View {
    let value: Double
    let maxValue: Double
    let label: String
    @State private var hover = false
    var body: some View {
        let t = pow(value / maxValue, 0.55)
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(value == 0 ? Color.white.opacity(0.05) : Theme.cyan.opacity(0.18 + 0.82 * t))
            .frame(maxWidth: .infinity)
            .frame(height: 18)
            .scaleEffect(hover ? 1.3 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hover)
            .onHover { hover = $0 }
            .help(label)
    }
}

struct AppRow: View {
    let app: AppUsage
    let share: Double
    let color: Color
    let rank: Int
    @State private var hover = false
    var body: some View {
        HStack(spacing: 10) {
            AppIconView(name: app.name, size: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(app.name).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                    Spacer()
                    Text(Fmt.bytes(app.total)).font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.06))
                        Capsule().fill(color.gradient).frame(width: max(g.size.width * share, 3))
                    }
                }
                .frame(height: 4)
                HStack(spacing: 10) {
                    Text("↓ \(Fmt.bytes(app.down))").foregroundStyle(Theme.cyan)
                    Text("↑ \(Fmt.bytes(app.up))").foregroundStyle(Theme.pink)
                    Spacer()
                    Text(Fmt.percent(share)).foregroundStyle(.secondary)
                }
                .font(.system(size: 10).monospacedDigit())
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(hover ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    @State private var pulse = false
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(Theme.accent)
                .scaleEffect(pulse ? 1.08 : 0.94)
                .opacity(pulse ? 1 : 0.6)
            Text(title).font(.system(size: 15, weight: .semibold, design: .rounded))
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .onAppear { withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

struct AppDetailSheet: View {
    let app: AppUsage
    @EnvironmentObject var store: NetStore
    @Environment(\.dismiss) private var dismiss
    @State private var points: [SeriesPoint] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AppIconView(name: app.name, size: 44)
                VStack(alignment: .leading) {
                    Text(app.name).font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("\(store.period.rawValue) · \(store.selectedSSID ?? "all networks")").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(GlowButtonStyle())
            }
            HStack(spacing: 12) {
                StatTile(title: "Total", value: app.total, format: { Fmt.bytes($0) }, icon: "sum", color: Theme.blue)
                StatTile(title: "Downloaded", value: app.down, format: { Fmt.bytes($0) }, icon: "arrow.down.circle.fill", color: Theme.cyan)
                StatTile(title: "Uploaded", value: app.up, format: { Fmt.bytes($0) }, icon: "arrow.up.circle.fill", color: Theme.pink)
            }
            Chart(points) { p in
                AreaMark(x: .value("Time", p.date), y: .value("Bytes", p.total))
                    .foregroundStyle(LinearGradient(colors: [Theme.cyan.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Time", p.date), y: .value("Bytes", p.total))
                    .foregroundStyle(Theme.cyan)
                    .interpolationMethod(.catmullRom)
            }
            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.bytes(d)) } } } }
            .frame(height: 220)
        }
        .padding(24)
        .frame(width: 620)
        .background(AuroraBackground())
        .preferredColorScheme(.dark)
        .task {
            let db = store.monitor.usage
            let name = app.name, ssid = store.selectedSSID, period = store.period
            points = await Task.detached { db.appSeries(app: name, ssid: ssid, period: period) }.value
        }
    }
}

// MARK: - Live

struct LiveView: View {
    @EnvironmentObject var monitor: NetworkMonitor

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                PageHeader(title: "Live Network", subtitle: monitor.wifi.ssid ?? monitor.currentKey, icon: "dot.radiowaves.left.and.right")

                HStack(spacing: 18) {
                    speedCard(title: "Download", value: monitor.downSpeed, peak: monitor.peakDown, color: Theme.cyan, icon: "arrow.down")
                    speedCard(title: "Upload", value: monitor.upSpeed, peak: monitor.peakUp, color: Theme.pink, icon: "arrow.up")
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Last 3 minutes", icon: "waveform.path.ecg")
                    Chart {
                        ForEach(monitor.speedHistory) { p in
                            AreaMark(x: .value("t", p.t), y: .value("Down", p.down), series: .value("s", "d"))
                                .foregroundStyle(LinearGradient(colors: [Theme.cyan.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.catmullRom)
                            LineMark(x: .value("t", p.t), y: .value("Down", p.down), series: .value("s", "d"))
                                .foregroundStyle(Theme.cyan).interpolationMethod(.catmullRom)
                            LineMark(x: .value("t", p.t), y: .value("Up", p.up), series: .value("s", "u"))
                                .foregroundStyle(Theme.pink).interpolationMethod(.catmullRom)
                        }
                    }
                    .chartYAxis { AxisMarks { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4])).foregroundStyle(Color.white.opacity(0.12))
                        AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.speed(d)).font(.caption2) } } } }
                    .chartXAxis(.hidden)
                    .frame(height: 220)
                }
                .card()

                HStack(alignment: .top, spacing: 18) {
                    wifiCard
                    talkersCard
                }
                HStack(spacing: 14) {
                    StatTile(title: "Downloaded this session", value: monitor.sessionDown, format: { Fmt.bytes($0) }, icon: "arrow.down.circle.fill", color: Theme.cyan)
                    StatTile(title: "Uploaded this session", value: monitor.sessionUp, format: { Fmt.bytes($0) }, icon: "arrow.up.circle.fill", color: Theme.pink)
                }
            }
            .padding(26)
        }
    }

    private func speedCard(title: String, value: Double, peak: Double, color: Color, icon: String) -> some View {
        HStack(spacing: 18) {
            RingGauge(progress: min(value / max(peak, 1_000_000), 1), colors: [color, color.opacity(0.4)], lineWidth: 12) {
                Image(systemName: icon).font(.system(size: 22, weight: .bold)).foregroundStyle(color)
            }
            .frame(width: 92, height: 92)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                CountingText(value: value, format: { Fmt.speed($0) })
                    .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                    .animation(.easeOut(duration: 0.5), value: value)
                Text("peak \(Fmt.speed(peak))").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .card(tint: color)
    }

    private var wifiCard: some View {
        let w = monitor.wifi
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Connection", subtitle: w.ssid ?? "Network name hidden — allow Location", icon: "wifi")
            HStack(spacing: 18) {
                RingGauge(progress: w.quality, colors: w.quality > 0.6 ? [Theme.green, Theme.cyan] : (w.quality > 0.35 ? [Theme.yellow, Theme.orange] : [Theme.orange, Theme.red]), lineWidth: 10) {
                    VStack(spacing: 0) {
                        Text("\(w.rssi)").font(.system(size: 20, weight: .bold, design: .rounded))
                        Text("dBm").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 84, height: 84)
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow { kv("Link rate", w.txRate > 0 ? "\(Int(w.txRate)) Mbps" : "—"); kv("Channel", w.channel > 0 ? "\(w.channel) · \(w.band)" : "—") }
                    GridRow { kv("Standard", w.phy); kv("Security", w.security) }
                    GridRow { kv("SNR", "\(w.snr) dB"); kv("Noise", "\(w.noise) dBm") }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func kv(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.system(size: 12, weight: .semibold, design: .rounded))
        }
    }

    private var talkersCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Talking right now", subtitle: "Apps using Wi-Fi in the last 10 seconds", icon: "person.wave.2.fill")
            if monitor.talkers.isEmpty {
                Text("Quiet — nothing is using Wi-Fi at the moment.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 16)
            }
            ForEach(monitor.talkers) { t in
                HStack(spacing: 10) {
                    AppIconView(name: t.name, size: 24)
                    Text(t.name).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                    Spacer()
                    Text("↓ \(Fmt.speed(t.down))").foregroundStyle(Theme.cyan)
                    Text("↑ \(Fmt.speed(t.up))").foregroundStyle(Theme.pink)
                }
                .font(.system(size: 11).monospacedDigit())
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: monitor.talkers.map(\.name))
        .card()
    }
}

// MARK: - Permission deep links

enum PermissionLinks {
    static func openLocationSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") { NSWorkspace.shared.open(u) }
    }
}
