import SwiftUI
import Charts
import AppKit

// MARK: - Storage overview

struct StorageView: View {
    @EnvironmentObject var store: StorageStore
    @State private var hoveredCat: String?

    private var segments: [(id: String, name: String, color: Color, bytes: Int64)] {
        var s = store.categories.compactMap { c -> (String, String, Color, Int64)? in
            guard let b = c.bytes, b > 0 else { return nil }
            return (c.id, c.name, c.color, b)
        }
        if store.systemBytes > 0 { s.append(("system", "macOS & system data", Color(red: 0.42, green: 0.46, blue: 0.55), store.systemBytes)) }
        return s.sorted { $0.3 > $1.3 }.map { (id: $0.0, name: $0.1, color: $0.2, bytes: $0.3) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                if store.scanning { scanProgress }
                overviewCard
                HStack(alignment: .top, spacing: 18) {
                    categoriesCard
                    VStack(spacing: 18) { whatHappenedCard; snapshotsCard }.frame(width: 360)
                }
                explorerCard
            }
            .padding(26)
        }
        .onAppear { if store.lastScan == nil && !store.scanning { store.scan() } }
    }

    private var header: some View {
        HStack {
            PageHeader(title: "Storage", subtitle: "Where every gigabyte of your Mac went", icon: "internaldrive.fill")
            Button {
                store.scanning ? store.cancelScan() : store.scan()
            } label: {
                Label(store.scanning ? "Stop" : "Scan now", systemImage: store.scanning ? "stop.fill" : "arrow.clockwise")
            }
            .buttonStyle(GlowButtonStyle(color: store.scanning ? Theme.red : Theme.blue))
        }
    }

    private var scanProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView().controlSize(.small)
                Text(store.scanStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.percent(store.scanProgress)).font(.caption.monospacedDigit())
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    Capsule().fill(Theme.accent).frame(width: g.size.width * store.scanProgress)
                        .animation(.easeOut(duration: 0.4), value: store.scanProgress)
                }
            }
            .frame(height: 6)
        }
        .card(padding: 14)
    }

    private var overviewCard: some View {
        let v = store.volume
        return HStack(spacing: 28) {
            RingGauge(progress: v.usedFraction,
                      colors: v.usedFraction > 0.9 ? [Theme.orange, Theme.red] : (v.usedFraction > 0.75 ? [Theme.yellow, Theme.orange] : [Theme.cyan, Theme.purple, Theme.pink]),
                      lineWidth: 20) {
                VStack(spacing: 2) {
                    CountingText(value: Double(v.free), format: { Fmt.bytes($0) })
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .animation(.easeOut(duration: 1), value: v.free)
                    Text("free").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 190, height: 190)

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    CountingText(value: Double(v.used), format: { Fmt.bytes($0) })
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .animation(.easeOut(duration: 1), value: v.used)
                    Text("used of \(Fmt.bytes(Double(v.total)))").foregroundStyle(.secondary)
                    Spacer()
                    if v.purgeable > 0 { Pill(text: "\(Fmt.bytes(Double(v.purgeable))) purgeable", color: Theme.green) }
                }
                stackedBar
                legend
            }
        }
        .card(padding: 22)
    }

    private var stackedBar: some View {
        let total = Double(max(store.volume.total, 1))
        return GeometryReader { g in
            HStack(spacing: 2) {
                ForEach(segments, id: \.id) { s in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(s.color.gradient)
                        .frame(width: max(g.size.width * Double(s.bytes) / total - 2, 0))
                        .opacity(hoveredCat == nil || hoveredCat == s.id ? 1 : 0.3)
                        .onHover { hoveredCat = $0 ? s.id : nil }
                        .help("\(s.name) — \(Fmt.bytes(Double(s.bytes)))")
                }
                Spacer(minLength: 0)
            }
            .animation(.spring(response: 0.7, dampingFraction: 0.85), value: segments.map(\.bytes))
        }
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
    }

    private var legend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(segments.prefix(9), id: \.id) { s in
                HStack(spacing: 6) {
                    Circle().fill(s.color).frame(width: 8, height: 8)
                    Text(s.name).font(.caption).lineLimit(1)
                    Text(Fmt.bytes(Double(s.bytes))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .opacity(hoveredCat == nil || hoveredCat == s.id ? 1 : 0.35)
                .onHover { hoveredCat = $0 ? s.id : nil }
            }
        }
    }

    private var categoriesCard: some View {
        let maxB = Double(max(segments.map(\.bytes).max() ?? 1, 1))
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "By category", subtitle: "Click a folder row to explore inside it", icon: "chart.bar.fill")
            ForEach(store.categories) { c in
                CategoryRow(cat: c, maxBytes: maxB) {
                    if let p = c.revealPath { store.openExplorer(c.id == "otherhome" ? NSHomeDirectory() : p) }
                }
            }
            if store.systemBytes > 0 {
                CategoryRow(cat: StorageCategory(id: "system", name: "macOS & system data", icon: "apple.logo", color: Color(red: 0.42, green: 0.46, blue: 0.55), paths: [],
                                                 bytes: store.systemBytes, note: "Sealed macOS, APFS snapshots, VM/swap, anything DataLens can't read"), maxBytes: maxB, onTap: {})
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var whatHappenedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "What happened to your space?", subtitle: store.changesSince.map { "Changes since \(Fmt.shortDate.string(from: $0))" } ?? "Free space over time", icon: "clock.arrow.2.circlepath")

            if store.history.count >= 2 {
                Chart {
                    ForEach(store.history, id: \.0) { p in
                        AreaMark(x: .value("Date", p.0), y: .value("Free", Double(p.2)))
                            .foregroundStyle(LinearGradient(colors: [Theme.green.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", p.0), y: .value("Free", Double(p.2)))
                            .foregroundStyle(Theme.green).interpolationMethod(.monotone)
                    }
                }
                .chartYAxis { AxisMarks { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4])).foregroundStyle(Color.white.opacity(0.12))
                    AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.bytes(d)).font(.caption2) } } } }
                .frame(height: 110)
            } else {
                Text("DataLens records your free space every few hours while it runs, so this chart grows into a timeline. macOS itself keeps no history, so it starts from today.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if store.changes.isEmpty {
                Text(store.changesSince == nil ? "Run another scan later and DataLens will list exactly which folders and apps grew or shrank."
                                                 : "Nothing grew or shrank by more than 100 MB since the previous scan.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(store.changes.prefix(8)) { ch in
                HStack {
                    Image(systemName: ch.delta > 0 ? "arrow.up.right" : "arrow.down.right")
                        .foregroundStyle(ch.delta > 0 ? Theme.red : Theme.green)
                    Text(ch.name).font(.caption).lineLimit(1)
                    Spacer()
                    Text((ch.delta > 0 ? "+" : "−") + Fmt.bytes(Double(abs(ch.delta))))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(ch.delta > 0 ? Theme.red : Theme.green)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var snapshotsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Hidden space eaters", icon: "eye.slash.fill")
            infoRow(icon: "camera.metering.matrix", title: "Time Machine local snapshots", value: "\(store.snapshotCount)",
                    note: store.snapshotCount > 0 ? "macOS frees these automatically when space is needed. They count as “System Data”." : "None found.")
            infoRow(icon: "arrow.3.trianglepath", title: "Purgeable space", value: Fmt.bytes(Double(store.volume.purgeable)),
                    note: "iCloud-cached and temporary files macOS will delete on demand.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func infoRow(icon: String, title: String, value: String, note: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.purple).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack { Text(title).font(.system(size: 12, weight: .semibold, design: .rounded)); Spacer(); Text(value).font(.system(size: 12, weight: .bold, design: .rounded)) }
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Explorer

    private var explorerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(title: "Folder explorer", subtitle: "Rectangles are sized by disk usage — click a folder to dive in", icon: "square.grid.3x3.topleft.filled")
                Button("Home") { store.openExplorer(NSHomeDirectory()) }.buttonStyle(GlowButtonStyle(color: Theme.cyan))
                Button("Macintosh HD") { store.openExplorer("/System/Volumes/Data") }.buttonStyle(GlowButtonStyle(color: Theme.purple))
            }
            if store.explorerStack.isEmpty {
                EmptyState(icon: "square.grid.3x3.fill", title: "Pick a place to explore", message: "Choose Home or Macintosh HD, or click any category above.")
                    .frame(height: 200)
            } else {
                HStack(spacing: 4) {
                    ForEach(Array(store.explorerStack.enumerated()), id: \.offset) { i, p in
                        if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary) }
                        Button((p as NSString).lastPathComponent.isEmpty ? "/" : (p as NSString).lastPathComponent) { store.ascend(to: i) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: i == store.explorerStack.count - 1 ? .bold : .regular, design: .rounded))
                            .foregroundStyle(i == store.explorerStack.count - 1 ? Color.white : Theme.cyan)
                    }
                    Spacer()
                    if store.explorerLoading { ProgressView().controlSize(.small); Text("measuring…").font(.caption).foregroundStyle(.secondary) }
                }
                TreemapView(entries: store.explorerEntries) { store.descend($0) }
                    .frame(height: 380)
                    .overlay {
                        if store.explorerLoading && store.explorerEntries.isEmpty { ShimmerBar().frame(height: 380) }
                    }
            }
        }
        .card()
    }
}

struct CategoryRow: View {
    let cat: StorageCategory
    let maxBytes: Double
    var onTap: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: cat.icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(cat.color)
                .frame(width: 32, height: 32)
                .background(cat.color.opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(cat.name).font(.system(size: 13, weight: .semibold, design: .rounded))
                    Spacer()
                    if let b = cat.bytes {
                        Text(Fmt.bytes(Double(b))).font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                    } else {
                        ShimmerBar().frame(width: 60, height: 12)
                    }
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.06))
                        Capsule().fill(cat.color.gradient)
                            .frame(width: g.size.width * CGFloat(Double(cat.bytes ?? 0) / maxBytes))
                    }
                }
                .frame(height: 6)
                .animation(.spring(response: 0.8, dampingFraction: 0.8), value: cat.bytes)
                if let n = cat.note { Text(n).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(hover ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onTap)
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

// MARK: - Apps

struct StorageAppsView: View {
    @EnvironmentObject var store: StorageStore
    @State private var sort = Sort.total
    @State private var query = ""

    enum Sort: String, CaseIterable, Identifiable {
        case total = "Total", app = "App", data = "Data", cache = "Caches"
        var id: String { rawValue }
    }

    private var sorted: [AppFootprint] {
        let list = store.apps.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        switch sort {
        case .total: return list.sorted { $0.total > $1.total }
        case .app: return list.sorted { $0.appBytes > $1.appBytes }
        case .data: return list.sorted { $0.dataBytes > $1.dataBytes }
        case .cache: return list.sorted { $0.cacheBytes > $1.cacheBytes }
        }
    }

    var body: some View {
        let maxB = Double(max(store.apps.map(\.total).max() ?? 1, 1))
        ScrollView {
            VStack(spacing: 18) {
                PageHeader(title: "Apps & Their Space", subtitle: "App bundle + the data and caches each app keeps elsewhere", icon: "square.grid.2x2.fill")

                HStack(spacing: 14) {
                    StatTile(title: "Apps", value: Double(store.apps.count), format: { String(Int($0)) }, icon: "app.fill", color: Theme.blue)
                    StatTile(title: "App bundles", value: Double(store.apps.reduce(0) { $0 + $1.appBytes }), format: { Fmt.bytes($0) }, icon: "shippingbox.fill", color: Theme.cyan)
                    StatTile(title: "Their data", value: Double(store.apps.reduce(0) { $0 + $1.dataBytes }), format: { Fmt.bytes($0) }, icon: "externaldrive.fill", color: Theme.purple)
                    StatTile(title: "Their caches", value: Double(store.apps.reduce(0) { $0 + $1.cacheBytes }), format: { Fmt.bytes($0) }, icon: "clock.arrow.circlepath", color: Theme.pink)
                }

                HStack {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search apps", text: $query).textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                    .frame(maxWidth: 280)
                    Spacer()
                    SlidingPicker(items: Sort.allCases, selection: $sort) { $0.rawValue }
                }

                if store.apps.isEmpty {
                    EmptyState(icon: "square.grid.2x2", title: store.scanning ? "Measuring apps…" : "No scan yet",
                               message: "DataLens sizes each app and the folders it leaves in ~/Library.")
                        .card().frame(height: 220)
                } else {
                    VStack(spacing: 4) {
                        HStack(spacing: 14) {
                            legendDot("App", Theme.blue); legendDot("Data", Theme.purple); legendDot("Caches", Theme.pink)
                            Spacer()
                        }
                        .padding(.bottom, 6)
                        ForEach(sorted.prefix(80)) { a in
                            AppFootprintRow(app: a, maxBytes: maxB)
                        }
                    }
                    .card()
                }
            }
            .padding(26)
        }
        .onAppear { if store.lastScan == nil && !store.scanning { store.scan() } }
    }

    private func legendDot(_ t: String, _ c: Color) -> some View {
        HStack(spacing: 5) { Circle().fill(c).frame(width: 8, height: 8); Text(t).font(.caption).foregroundStyle(.secondary) }
    }
}

struct AppFootprintRow: View {
    @EnvironmentObject var store: StorageStore
    let app: AppFootprint
    let maxBytes: Double
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(name: app.name, path: app.path, size: 34)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(app.name).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
                    Spacer()
                    Text(Fmt.bytes(Double(app.total))).font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                }
                GeometryReader { g in
                    let scale = g.size.width * CGFloat(Double(app.total) / maxBytes) / CGFloat(max(Double(app.total), 1))
                    HStack(spacing: 1) {
                        Rectangle().fill(Theme.blue.gradient).frame(width: CGFloat(app.appBytes) * scale)
                        Rectangle().fill(Theme.purple.gradient).frame(width: CGFloat(app.dataBytes) * scale)
                        Rectangle().fill(Theme.pink.gradient).frame(width: CGFloat(app.cacheBytes) * scale)
                        Spacer(minLength: 0)
                    }
                    .clipShape(Capsule())
                    .animation(.spring(response: 0.7, dampingFraction: 0.85), value: app.total)
                }
                .frame(height: 6)
                HStack(spacing: 12) {
                    Text("App \(Fmt.bytes(Double(app.appBytes)))").foregroundStyle(Theme.blue)
                    Text("Data \(Fmt.bytes(Double(app.dataBytes)))").foregroundStyle(Theme.purple)
                    Text("Caches \(Fmt.bytes(Double(app.cacheBytes)))").foregroundStyle(Theme.pink)
                    Spacer()
                    if hover {
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) }
                            .buttonStyle(GlowButtonStyle(color: Theme.blue))
                        if app.cacheBytes > 20_000_000 {
                            Button("Clear caches") { store.trashAppCaches(app) }.buttonStyle(GlowButtonStyle(color: Theme.blue))
                        }
                    }
                }
                .font(.system(size: 10).monospacedDigit())
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(hover ? 0.06 : 0)))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

// MARK: - Clean up

struct CleanUpView: View {
    @EnvironmentObject var store: StorageStore

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                PageHeader(title: "Free Up Space", subtitle: "Ranked by how much you get back — nothing is deleted without asking", icon: "sparkles")

                if let m = store.lastActionMessage {
                    BannerView(icon: "checkmark.circle.fill", title: "Done", message: m, color: Theme.green, actionTitle: "Dismiss") { store.lastActionMessage = nil }
                }

                hero

                if store.cleanup.isEmpty {
                    EmptyState(icon: "sparkles", title: store.scanning ? "Looking for things to clean…" : "Nothing found yet",
                               message: "Run a scan from the Storage page to build this list.")
                        .card().frame(height: 200)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                        ForEach(store.cleanup) { item in CleanupCard(item: item, maxBytes: Double(store.cleanup.first?.bytes ?? 1)) }
                    }
                }

                filesCard(title: "Largest files", subtitle: "Files over 300 MB found by Spotlight in your home folder", files: store.bigFiles, icon: "doc.zipper")
                filesCard(title: "Recent heavy hitters", subtitle: "Big files created or changed in the last 14 days — what filled your disk lately", files: store.recentHeavy, icon: "flame.fill")
                tips
            }
            .padding(26)
        }
        .onAppear { if store.lastScan == nil && !store.scanning { store.scan() } }
    }

    private var hero: some View {
        HStack(spacing: 24) {
            RingGauge(progress: store.volume.total > 0 ? Double(store.reclaimable) / Double(store.volume.total) * 4 : 0, colors: [Theme.green, Theme.cyan], lineWidth: 14) {
                Image(systemName: "leaf.fill").font(.system(size: 30)).foregroundStyle(Theme.green)
            }
            .frame(width: 120, height: 120)
            VStack(alignment: .leading, spacing: 6) {
                Text("You can safely reclaim").font(.callout).foregroundStyle(.secondary)
                CountingText(value: Double(store.reclaimable), format: { Fmt.bytes($0) })
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                    .animation(.easeOut(duration: 1.2), value: store.reclaimable)
                Text("up to \(Fmt.bytes(Double(store.reclaimableAll))) if you also review the yellow items · move to Trash, then empty it to get the space back")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .card(padding: 22, tint: Theme.green)
    }

    private func filesCard(title: String, subtitle: String, files: [BigFile], icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: title, subtitle: subtitle, icon: icon)
            if files.isEmpty { Text("Nothing to show.").font(.caption).foregroundStyle(.secondary) }
            ForEach(files.prefix(15)) { f in BigFileRow(file: f) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "More ways to shrink your Mac's footprint", icon: "lightbulb.fill")
            let list: [(String, String, String)] = [
                ("icloud.fill", "Optimize Mac Storage for Photos", "Photos ▸ Settings ▸ iCloud ▸ Optimize Mac Storage keeps small versions locally."),
                ("message.fill", "Trim Messages & Mail attachments", "System Settings ▸ General ▸ Storage ▸ Messages / Mail lets you drop old attachments."),
                ("arrow.down.app.fill", "Delete apps you never open", "Open the Apps page, sort by size, and remove what you have not used in months."),
                ("film.stack.fill", "Move big media to an external drive", "Videos, VMs and project archives are the biggest wins — see Largest files."),
                ("globe", "Remove language files", "Unused localisations can be huge in some apps. Leave system apps alone."),
                ("externaldrive.badge.icloud", "Offload Desktop & Documents to iCloud", "System Settings ▸ Apple ID ▸ iCloud ▸ Drive ▸ Desktop & Documents Folders."),
            ]
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(list, id: \.1) { t in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: t.0).foregroundStyle(Theme.cyan).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.1).font(.system(size: 12, weight: .semibold, design: .rounded))
                            Text(t.2).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            Button("Open macOS Storage settings") {
                if let u = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") { NSWorkspace.shared.open(u) }
            }
            .buttonStyle(GlowButtonStyle(color: Theme.cyan))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct CleanupCard: View {
    @EnvironmentObject var store: StorageStore
    let item: CleanupItem
    let maxBytes: Double

    private var buttonTitle: String {
        switch item.action {
        case .trashContents, .trashPaths: return "Move to Trash"
        case .emptyTrash: return "Empty Trash"
        case .revealOnly: return "Show in Finder"
        case .command: return "Copy command"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: item.icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(item.risk.color)
                    .frame(width: 36, height: 36)
                    .background(item.risk.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
                    Pill(text: item.risk.rawValue, color: item.risk.color)
                }
                Spacer()
                Text(Fmt.bytes(Double(item.bytes))).font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
            }
            Text(item.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            GeometryReader { g in
                Capsule().fill(item.risk.color.gradient).frame(width: g.size.width * CGFloat(Double(item.bytes) / maxBytes))
                    .animation(.spring(response: 0.8, dampingFraction: 0.8), value: item.bytes)
            }
            .frame(height: 4)
            HStack {
                if case .revealOnly = item.action {} else {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(item.paths.prefix(1).map { URL(fileURLWithPath: $0) }) }
                        .buttonStyle(GlowButtonStyle(color: Theme.blue))
                }
                Spacer()
                Button(buttonTitle) { store.perform(item) }
                    .buttonStyle(GlowButtonStyle(color: item.risk == .safe ? Theme.green : Theme.orange))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
        .hoverLift()
    }
}

struct BigFileRow: View {
    @EnvironmentObject var store: StorageStore
    let file: BigFile
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(name: file.name, path: file.path, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.name).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                    if file.isStale { Pill(text: "unused 6+ months", color: Theme.yellow) }
                }
                Text(file.folder).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if hover {
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]) }.buttonStyle(GlowButtonStyle(color: Theme.blue))
                Button("Trash") { store.trashFile(file) }.buttonStyle(GlowButtonStyle(color: Theme.red))
            }
            Text(Fmt.bytes(Double(file.bytes))).font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(hover ? 0.06 : 0)))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

// MARK: - SSD health

struct SSDHealthView: View {
    @EnvironmentObject var ssd: SSDMonitor
    @EnvironmentObject var storage: StorageStore

    var body: some View {
        let result = ssd.score(volume: storage.volume)
        let col: [Color] = result.score >= 85 ? [Theme.green, Theme.cyan] : (result.score >= 60 ? [Theme.yellow, Theme.orange] : [Theme.orange, Theme.red])
        ScrollView {
            VStack(spacing: 18) {
                PageHeader(title: "SSD Health", subtitle: ssd.info.model, icon: "heart.text.square.fill")

                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 14) {
                        RingGauge(progress: Double(result.score) / 100, colors: col, lineWidth: 18) {
                            VStack(spacing: 0) {
                                CountingText(value: Double(result.score), format: { String(Int($0)) })
                                    .font(.system(size: 54, weight: .bold, design: .rounded))
                                    .animation(.easeOut(duration: 1.2), value: result.score)
                                Text("health score").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 210, height: 210)
                        Pill(text: ssd.info.smartOK ? "S.M.A.R.T. Verified" : ssd.info.smartStatus, color: ssd.info.smartOK ? Theme.green : Theme.red)
                    }
                    .frame(width: 270)
                    .card(padding: 22, tint: col[0])

                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "What's affecting the score", icon: "list.bullet.clipboard.fill")
                        ForEach(result.factors) { f in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: f.level.icon).foregroundStyle(f.level.color).frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(f.title).font(.system(size: 12, weight: .semibold, design: .rounded))
                                    Text(f.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }

                HStack(spacing: 14) {
                    StatTile(title: "Capacity", value: Double(ssd.info.capacity), format: { Fmt.bytes($0) }, icon: "internaldrive", color: Theme.blue, footnote: ssd.info.model)
                    StatTile(title: "Read since boot", value: ssd.bootRead, format: { Fmt.bytes($0) }, icon: "arrow.down.doc.fill", color: Theme.cyan, footnote: "up \(Fmt.duration(ssd.uptime))")
                    StatTile(title: "Written since boot", value: ssd.bootWrite, format: { Fmt.bytes($0) }, icon: "square.and.pencil", color: Theme.pink, footnote: "writes wear flash")
                    StatTile(title: "Free space", value: Double(storage.volume.free), format: { Fmt.bytes($0) }, icon: "leaf.fill", color: Theme.green, footnote: Fmt.percent(storage.volume.total > 0 ? Double(storage.volume.importantFree) / Double(storage.volume.total) : 0) + " incl. purgeable")
                }

                liveIO
                enduranceCard
                HStack(alignment: .top, spacing: 18) {
                    deviceCard
                    benchCard
                }
                longevityTips
            }
            .padding(26)
        }
    }

    private var liveIO: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title: "Live disk activity", subtitle: "Read and write throughput of the internal SSD", icon: "waveform.path.ecg")
                Text("↓ \(Fmt.speed(ssd.readSpeed))").foregroundStyle(Theme.cyan).font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                Text("↑ \(Fmt.speed(ssd.writeSpeed))").foregroundStyle(Theme.pink).font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
            }
            Chart {
                ForEach(ssd.ioHistory) { p in
                    AreaMark(x: .value("t", p.t), y: .value("Read", p.read), series: .value("s", "r"))
                        .foregroundStyle(LinearGradient(colors: [Theme.cyan.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("t", p.t), y: .value("Read", p.read), series: .value("s", "r"))
                        .foregroundStyle(Theme.cyan).interpolationMethod(.catmullRom)
                    LineMark(x: .value("t", p.t), y: .value("Write", p.write), series: .value("s", "w"))
                        .foregroundStyle(Theme.pink).interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4])).foregroundStyle(Color.white.opacity(0.12))
                AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.speed(d)).font(.caption2) } } } }
            .frame(height: 150)
        }
        .card()
    }

    private var enduranceCard: some View {
        let i = ssd.info
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Wear & endurance", subtitle: "How much of the flash's rated life has been used", icon: "battery.75percent")
            if let used = i.percentUsed {
                HStack(spacing: 22) {
                    RingGauge(progress: Double(100 - used) / 100, colors: [Theme.green, Theme.cyan], lineWidth: 12) {
                        VStack(spacing: 0) { Text("\(100 - used)%").font(.system(size: 22, weight: .bold, design: .rounded)); Text("life left").font(.caption2).foregroundStyle(.secondary) }
                    }
                    .frame(width: 110, height: 110)
                    Grid(alignment: .leading, horizontalSpacing: 26, verticalSpacing: 8) {
                        GridRow { metric("Data written", i.bytesWritten.map { Fmt.bytes($0) } ?? "—"); metric("Data read", i.bytesRead.map { Fmt.bytes($0) } ?? "—") }
                        GridRow { metric("Power-on time", i.powerOnHours.map { "\($0) h (\($0 / 24) d)" } ?? "—"); metric("Power cycles", i.powerCycles.map(String.init) ?? "—") }
                        GridRow { metric("Spare blocks", i.availableSpare.map { "\($0)%" } ?? "—"); metric("Temperature", i.temperature.map { "\($0) °C" } ?? "—") }
                        GridRow { metric("Unsafe shutdowns", i.unsafeShutdowns.map(String.init) ?? "—"); metric("Media errors", i.mediaErrors.map(String.init) ?? "—") }
                    }
                }
            } else {
                BannerView(icon: "info.circle.fill", title: "Wear counters need smartmontools",
                           message: i.smartctlNote ?? "Not available.", color: Theme.blue,
                           actionTitle: "Copy install command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install smartmontools && sudo smartctl -a /dev/\(i.bsd)", forType: .string)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func metric(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.system(size: 13, weight: .semibold, design: .rounded))
        }
    }

    private var deviceCard: some View {
        let i = ssd.info
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Drive details", icon: "info.circle.fill")
            Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 8) {
                GridRow { metric("Model", i.model); metric("Firmware", i.revision) }
                GridRow { metric("Serial", i.serial); metric("Device", "/dev/" + i.bsd) }
                GridRow { metric("Type", i.isSolidState ? "Solid state (NVMe)" : "Disk"); metric("TRIM", i.trim ? "Supported" : "Unknown") }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var benchCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Speed test", subtitle: "Writes then reads a 1 GB temp file", icon: "speedometer")
            if let b = ssd.bench {
                HStack(spacing: 24) {
                    benchGauge("Write", b.writeMBps, Theme.pink)
                    benchGauge("Read", b.readMBps, Theme.cyan)
                }
            } else if ssd.benchmarking {
                HStack { ProgressView().controlSize(.small); Text(ssd.benchPhase).font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 18)
            } else {
                Text("Measure real sequential speed. Apple SSDs typically reach several GB/s.").font(.caption).foregroundStyle(.secondary)
            }
            Button(ssd.benchmarking ? "Running…" : "Run speed test") { ssd.runBenchmark() }
                .buttonStyle(GlowButtonStyle(color: Theme.purple)).disabled(ssd.benchmarking)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func benchGauge(_ title: String, _ v: Double, _ c: Color) -> some View {
        VStack(spacing: 6) {
            RingGauge(progress: min(v / 6000, 1), colors: [c, c.opacity(0.4)], lineWidth: 9) {
                VStack(spacing: 0) {
                    CountingText(value: v, format: { String(format: "%.0f", $0) }).font(.system(size: 17, weight: .bold, design: .rounded))
                        .animation(.easeOut(duration: 1.2), value: v)
                    Text("MB/s").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 84, height: 84)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var longevityTips: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Keeping the SSD healthy", icon: "shield.lefthalf.filled")
            let tips = [
                "Keep 15% or more of the drive free — flash needs spare room to spread wear.",
                "Do not worry about the Mac's swap: it writes little in normal use. Heavy video/VM work is what adds up.",
                "Keep Time Machine or another backup current — SSDs usually fail suddenly, not gradually.",
                "Avoid constantly filling and deleting hundreds of GB (e.g. repeated large exports to the internal drive).",
            ]
            ForEach(tips, id: \.self) { t in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green).font(.caption)
                    Text(t).font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
