import SwiftUI
import Charts
import ServiceManagement

enum Page: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case wifi = "Wi-Fi Usage"
    case live = "Live Network"
    case storage = "Storage"
    case apps = "Apps & Space"
    case cleanup = "Free Up Space"
    case ssd = "SSD Health"
    case settings = "Settings"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .wifi: return "wifi"
        case .live: return "dot.radiowaves.left.and.right"
        case .storage: return "internaldrive.fill"
        case .apps: return "app.badge.fill"
        case .cleanup: return "sparkles"
        case .ssd: return "heart.text.square.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct RootView: View {
    @State private var page: Page = Page(rawValue: ProcessInfo.processInfo.environment["DATALENS_PAGE"] ?? "") ?? .overview
    @Namespace private var ns
    @EnvironmentObject var storageStore: StorageStore

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ZStack {
                AuroraBackground()
                Group {
                    switch page {
                    case .overview: OverviewView(go: { page = $0 })
                    case .wifi: NetworkUsageView()
                    case .live: LiveView()
                    case .storage: StorageView()
                    case .apps: StorageAppsView()
                    case .cleanup: CleanUpView()
                    case .ssd: SSDHealthView()
                    case .settings: SettingsView()
                    }
                }
                .id(page)
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
        }
        .animation(.easeInOut(duration: 0.28), value: page)
        .ignoresSafeArea()
        .task { await snapshotMode() }
    }

    /// Developer aid: DATALENS_SNAPSHOT=<dir> renders every page to a PNG and quits.
    private func snapshotMode() async {
        guard let dir = ProcessInfo.processInfo.environment["DATALENS_SNAPSHOT"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        for p in Page.allCases {
            page = p
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if p == .storage {
                for _ in 0..<150 where storageStore.scanning || storageStore.lastScan == nil { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            guard let v = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(p.rawValue.replacingOccurrences(of: " ", with: "_")).png"))
        }
        NSApp.terminate(nil)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent).frame(width: 34, height: 34)
                    Image(systemName: "scope").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                }
                Text("DataLens").font(.system(size: 20, weight: .bold, design: .rounded))
            }
            .padding(.top, 44).padding(.bottom, 18).padding(.horizontal, 10)

            group("", [.overview])
            group("NETWORK", [.wifi, .live])
            group("STORAGE", [.storage, .apps, .cleanup, .ssd])
            Spacer()
            group("", [.settings])
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 12)
        .frame(width: 220)
        .background(.ultraThinMaterial.opacity(0.6))
        .background(Color.black.opacity(0.25))
        .overlay(alignment: .trailing) { Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1) }
    }

    private func group(_ title: String, _ pages: [Page]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !title.isEmpty {
                Text(title).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
            }
            ForEach(pages) { p in
                SidebarRow(page: p, selected: page == p, ns: ns)
                    .onTapGesture { page = p }
            }
        }
    }
}

struct SidebarRow: View {
    let page: Page
    let selected: Bool
    var ns: Namespace.ID
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: page.icon).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.secondary))
                .frame(width: 22)
            Text(page.rawValue).font(.system(size: 13, weight: selected ? .semibold : .medium, design: .rounded))
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.75))
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background {
            ZStack {
                if selected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.10))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
                        .matchedGeometryEffect(id: "sidebarSel", in: ns)
                } else if hover {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.05))
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: selected)
    }
}

// MARK: - Overview

struct OverviewView: View {
    @EnvironmentObject var monitor: NetworkMonitor
    @EnvironmentObject var net: NetStore
    @EnvironmentObject var storage: StorageStore
    @EnvironmentObject var ssd: SSDMonitor
    var go: (Page) -> Void

    @State private var today = (down: 0.0, up: 0.0)
    @State private var month = 0.0
    @State private var week: [SeriesPoint] = []
    @State private var topApps: [AppUsage] = []

    var body: some View {
        let health = ssd.score(volume: storage.volume)
        ScrollView {
            VStack(spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(greeting).font(.system(size: 32, weight: .bold, design: .rounded))
                        Text("Here's what your Mac has been up to.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Pill(text: monitor.wifi.ssid ?? monitor.currentKey, color: Theme.cyan)
                }

                HStack(spacing: 14) {
                    StatTile(title: "Used today", value: today.down + today.up, format: { Fmt.bytes($0) }, icon: "sun.max.fill", color: Theme.orange,
                             footnote: "↓ \(Fmt.bytes(today.down))  ↑ \(Fmt.bytes(today.up))")
                    StatTile(title: "This month", value: month, format: { Fmt.bytes($0) }, icon: "calendar", color: Theme.purple, footnote: "all Wi-Fi networks")
                    StatTile(title: "Free storage", value: Double(storage.volume.free), format: { Fmt.bytes($0) }, icon: "internaldrive.fill",
                             color: storage.volume.usedFraction > 0.85 ? Theme.red : Theme.green,
                             footnote: "\(Fmt.percent(storage.volume.usedFraction)) of \(Fmt.bytes(Double(storage.volume.total))) used")
                    StatTile(title: "SSD health", value: Double(health.score), format: { String(Int($0)) + " / 100" }, icon: "heart.fill", color: Theme.pink,
                             footnote: ssd.info.smartOK ? "S.M.A.R.T. verified" : ssd.info.smartStatus)
                }

                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            SectionTitle(title: "Last 7 days on Wi-Fi", icon: "chart.bar.fill")
                            Button("Details") { go(.wifi) }.buttonStyle(GlowButtonStyle())
                        }
                        Chart(week) { p in
                            BarMark(x: .value("Day", p.date, unit: .day), y: .value("Bytes", p.total), width: .ratio(0.7))
                                .foregroundStyle(Theme.accent)
                                .cornerRadius(5)
                        }
                        .chartYAxis { AxisMarks { v in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4])).foregroundStyle(Color.white.opacity(0.12))
                            AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.bytes(d)).font(.caption2) } } } }
                        .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
                        .frame(height: 190)
                    }
                    .card()

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            SectionTitle(title: "Top data users (7 days)", icon: "flame.fill")
                        }
                        if topApps.isEmpty { Text("Collecting…").font(.caption).foregroundStyle(.secondary) }
                        ForEach(topApps.prefix(5)) { a in
                            HStack(spacing: 10) {
                                AppIconView(name: a.name, size: 24)
                                Text(a.name).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                                Spacer()
                                Text(Fmt.bytes(a.total)).font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                            }
                        }
                    }
                    .frame(width: 300, alignment: .topLeading)
                    .card()
                }

                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            SectionTitle(title: "Storage at a glance", icon: "internaldrive")
                            Button("Open") { go(.storage) }.buttonStyle(GlowButtonStyle())
                        }
                        ForEach(storage.categories.filter { ($0.bytes ?? 0) > 0 }.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }.prefix(5)) { c in
                            HStack {
                                Image(systemName: c.icon).foregroundStyle(c.color).frame(width: 20)
                                Text(c.name).font(.caption)
                                Spacer()
                                Text(Fmt.bytes(Double(c.bytes ?? 0))).font(.caption.weight(.bold).monospacedDigit())
                            }
                        }
                        if storage.categories.allSatisfy({ $0.bytes == nil }) {
                            Text("Open Storage to run your first scan.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .card()

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            SectionTitle(title: "Suggestions", icon: "sparkles")
                            Button("Free up space") { go(.cleanup) }.buttonStyle(GlowButtonStyle(color: Theme.green))
                        }
                        suggestion(icon: "leaf.fill", color: Theme.green,
                                   text: storage.reclaimable > 0 ? "\(Fmt.bytes(Double(storage.reclaimable))) can be reclaimed safely (caches, logs, build data)." : "Run a scan to find reclaimable space.")
                        if storage.volume.total > 0, Double(storage.volume.importantFree) / Double(storage.volume.total) < 0.12 {
                            suggestion(icon: "exclamationmark.triangle.fill", color: Theme.orange,
                                       text: "Your disk is nearly full. Below ~10% free the SSD slows down and updates can fail.")
                        }
                        if !monitor.ssidAccessible {
                            suggestion(icon: "location.fill", color: Theme.orange, text: "Allow Location in Settings so networks are recorded by name.")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .card()
                }
            }
            .padding(26)
            .padding(.top, 8)
        }
        .task(id: monitor.dataVersion) { await reload() }
    }

    private func suggestion(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 20)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : (h < 18 ? "Good afternoon" : "Good evening")
    }

    private func reload() async {
        let db = monitor.usage
        let r = await Task.detached { () -> ((Double, Double), Double, [SeriesPoint], [AppUsage]) in
            let cal = Calendar.current
            let t = db.totals(ssid: nil, from: cal.startOfDay(for: Date()))
            let m = db.totals(ssid: nil, from: cal.dateInterval(of: .month, for: Date())?.start)
            return ((t.down, t.up), m.down + m.up, db.series(ssid: nil, period: .week), db.apps(ssid: nil, period: .week))
        }.value
        withAnimation(.easeInOut(duration: 0.6)) {
            today = (r.0.0, r.0.1); month = r.1; week = r.2; topApps = r.3
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var monitor: NetworkMonitor
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                PageHeader(title: "Settings & Permissions", subtitle: "What DataLens needs, and how it works", icon: "gearshape.fill")

                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(title: "Permission", icon: "lock.shield.fill")
                    permission(icon: "location.fill", title: "Location Services",
                               detail: "Lets macOS tell DataLens which Wi-Fi name you are on. Location itself is never read.",
                               ok: monitor.ssidAccessible, button: "Open Settings") {
                        if monitor.locationStatus == .notDetermined { monitor.requestLocation() } else { PermissionLinks.openLocationSettings() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()

                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(title: "Run in background", icon: "power")
                    Toggle(isOn: Binding(get: { launchAtLogin }, set: { setLaunch($0) })) {
                        VStack(alignment: .leading) {
                            Text("Start DataLens at login").font(.system(size: 13, weight: .semibold, design: .rounded))
                            Text("Usage is only measured while the app runs. It stays in the menu bar when you close the window.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    if let e = launchError { Text(e).font(.caption).foregroundStyle(Theme.orange) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "How the numbers are collected", icon: "questionmark.circle.fill")
                    note("Per-network totals come from the Wi-Fi interface counters, sampled every 2 s and filed under the current SSID.")
                    note("Per-app numbers come from `nettop` every 10 s. Very short-lived processes can be missed, so the app list can add up to slightly less than the network total.")
                    note("Storage sizes use allocated disk blocks (the same idea as Finder's “Size on disk”). APFS clones can make folders look larger than the space they really take.")
                    note("History starts the first time DataLens runs: macOS keeps no per-network record of past usage, so there is nothing to import.")
                    note("All data stays on this Mac in ~/Library/Application Support/DataLens.")
                    Button("Reveal data folder") { NSWorkspace.shared.activateFileViewerSelecting([UsageDB.directory]) }.buttonStyle(GlowButtonStyle())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
            .padding(26)
        }
    }

    private func note(_ t: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 4)).padding(.top, 6).foregroundStyle(.secondary)
            Text(t).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func permission(icon: String, title: String, detail: String, ok: Bool, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(ok ? Theme.green : Theme.orange).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if ok { Pill(text: "Granted", color: Theme.green) }
            else { Button(button, action: action).buttonStyle(GlowButtonStyle(color: Theme.orange)) }
        }
    }

    private func setLaunch(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchError = nil
        } catch {
            launchError = "Couldn't change login item: \(error.localizedDescription). Move DataLens to /Applications first."
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
