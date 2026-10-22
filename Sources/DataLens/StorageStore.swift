import Foundation
import SwiftUI
import AppKit

// MARK: - Models

struct VolumeInfo: Equatable {
    var total: Int64 = 0
    var free: Int64 = 0          // really free right now
    var importantFree: Int64 = 0 // free + purgeable
    var used: Int64 { max(total - free, 0) }
    var purgeable: Int64 { max(importantFree - free, 0) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct StorageCategory: Identifiable {
    let id: String
    let name: String
    let icon: String
    let color: Color
    var paths: [String]
    var bytes: Int64?
    var note: String? = nil
    var revealPath: String? { paths.first }
}

struct AppFootprint: Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let bundleID: String
    var appBytes: Int64 = 0
    var dataBytes: Int64 = 0
    var cacheBytes: Int64 = 0
    var cachePaths: [String] = []
    var total: Int64 { appBytes + dataBytes + cacheBytes }
}

enum Risk: String {
    case safe = "Safe", review = "Review first", caution = "Be careful"
    var color: Color {
        switch self { case .safe: return Theme.green; case .review: return Theme.yellow; case .caution: return Theme.orange }
    }
}

enum CleanupAction {
    case trashContents(String)
    case trashPaths([String])
    case emptyTrash
    case revealOnly
    case command(String)
}

struct CleanupItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    var paths: [String]
    var bytes: Int64
    let risk: Risk
    let action: CleanupAction
    /// true when this folder lives inside another item (excluded from the grand total)
    var nested = false
}

struct BigFile: Identifiable {
    var id: String { path }
    let path: String
    let bytes: Int64
    let lastUsed: Date?
    let modified: Date?
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath }
    var isStale: Bool { (lastUsed ?? modified).map { Date().timeIntervalSince($0) > 180 * 86400 } ?? false }
}

struct FolderEntry: Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let bytes: Int64
    let isDir: Bool
}

struct StorageChange: Identifiable {
    var id: String { name }
    let name: String
    let delta: Int64
}

// MARK: - Store

@MainActor
final class StorageStore: ObservableObject {
    let usage: UsageDB
    private let home = NSHomeDirectory()

    @Published var volume = VolumeInfo()
    @Published var categories: [StorageCategory] = []
    @Published var systemBytes: Int64 = 0           // remainder: macOS, snapshots, etc
    @Published var scanning = false
    @Published var scanProgress = 0.0
    @Published var scanStatus = ""
    @Published var lastScan: Date?
    @Published var apps: [AppFootprint] = []
    @Published var cleanup: [CleanupItem] = []
    @Published var bigFiles: [BigFile] = []
    @Published var recentHeavy: [BigFile] = []
    @Published var snapshotCount = 0
    @Published var changes: [StorageChange] = []
    @Published var changesSince: Date?
    @Published var history: [(Date, Int64, Int64)] = []
    @Published var lastActionMessage: String?

    // folder explorer
    @Published var explorerStack: [String] = []
    @Published var explorerEntries: [FolderEntry] = []
    @Published var explorerLoading = false
    private var explorerCache: [String: [FolderEntry]] = [:]

    private var scanTask: Task<Void, Never>?
    private var timer: Timer?

    init(usage: UsageDB) {
        self.usage = usage
        categories = Self.categoryDefinitions(home: home)
        if Demo.on {
            (categories, systemBytes) = Demo.categories(home: home)
            apps = Demo.apps(); cleanup = Demo.cleanup(); bigFiles = Demo.bigFiles(); recentHeavy = Array(Demo.bigFiles().prefix(3))
            snapshotCount = 2; lastScan = Date()
            explorerStack = ["/Users/demo"]; explorerEntries = Demo.explorer()
            changes = [StorageChange(name: "App · Docker", delta: 6_200_000_000), StorageChange(name: "Movies", delta: 4_100_000_000),
                       StorageChange(name: "Caches", delta: -2_300_000_000)]
            changesSince = Date().addingTimeInterval(-6 * 86400)
        }
        refreshVolume()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVolume() }
        }
        history = usage.storageHistory()
    }

    // MARK: Volume

    func refreshVolume() {
        if Demo.on {
            volume = Demo.volume
            history = usage.storageHistory()
            return
        }
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(fileURLWithPath: home).resourceValues(forKeys: keys) else { return }
        var info = VolumeInfo()
        info.total = Int64(v.volumeTotalCapacity ?? 0)
        info.free = Int64(v.volumeAvailableCapacity ?? 0)
        info.importantFree = v.volumeAvailableCapacityForImportantUsage ?? info.free
        if info != volume { volume = info }
        usage.recordStorage(total: info.total, free: info.free, purgeable: info.purgeable)
        history = usage.storageHistory()
    }

    // MARK: Definitions

    static func categoryDefinitions(home h: String) -> [StorageCategory] {
        func p(_ s: String) -> String { h + "/" + s }
        return [
            StorageCategory(id: "apps", name: "Applications", icon: "square.grid.2x2.fill", color: Theme.color(at: 0), paths: ["/Applications"]),
            StorageCategory(id: "docs", name: "Documents", icon: "doc.fill", color: Theme.color(at: 1), paths: [p("Documents")]),
            StorageCategory(id: "desktop", name: "Desktop", icon: "menubar.dock.rectangle", color: Theme.color(at: 2), paths: [p("Desktop")]),
            StorageCategory(id: "downloads", name: "Downloads", icon: "arrow.down.circle.fill", color: Theme.color(at: 3), paths: [p("Downloads")]),
            StorageCategory(id: "movies", name: "Movies", icon: "film.fill", color: Theme.color(at: 4), paths: [p("Movies")]),
            StorageCategory(id: "music", name: "Music", icon: "music.note", color: Theme.color(at: 5), paths: [p("Music")]),
            StorageCategory(id: "pictures", name: "Photos & Pictures", icon: "photo.fill", color: Theme.color(at: 6), paths: [p("Pictures")]),
            StorageCategory(id: "dev", name: "Developer (Xcode, simulators)", icon: "hammer.fill", color: Theme.color(at: 7), paths: [p("Library/Developer")]),
            StorageCategory(id: "caches", name: "Caches", icon: "clock.arrow.circlepath", color: Theme.color(at: 8), paths: [p("Library/Caches")], note: "Rebuilt automatically by apps"),
            StorageCategory(id: "support", name: "App Support Data", icon: "externaldrive.fill", color: Theme.color(at: 9), paths: [p("Library/Application Support")]),
            StorageCategory(id: "containers", name: "App Containers", icon: "shippingbox.fill", color: Theme.color(at: 10), paths: [p("Library/Containers"), p("Library/Group Containers")]),
            StorageCategory(id: "mail", name: "Mail & Messages", icon: "envelope.fill", color: Theme.color(at: 11), paths: [p("Library/Mail"), p("Library/Messages")]),
            StorageCategory(id: "icloud", name: "iCloud Drive (local)", icon: "icloud.fill", color: Theme.color(at: 12), paths: [p("Library/Mobile Documents")]),
            StorageCategory(id: "trash", name: "Trash", icon: "trash.fill", color: Theme.color(at: 13), paths: [p(".Trash")]),
            StorageCategory(id: "otherhome", name: "Other files in Home", icon: "folder.fill", color: Theme.color(at: 14), paths: [h], note: "Hidden folders (.npm, .docker …) and everything else"),
            StorageCategory(id: "syslib", name: "System libraries & tools", icon: "wrench.and.screwdriver.fill", color: Theme.color(at: 15), paths: ["/Library", "/opt", "/usr/local", "/private/var"], note: "/Library, Homebrew, swap files, logs"),
        ]
    }

    // MARK: Scan

    func scan() {
        guard !scanning else { return }
        scanning = true
        scanProgress = 0
        scanStatus = "Starting…"
        refreshVolume()
        var cats = Self.categoryDefinitions(home: home)
        for i in cats.indices { cats[i].bytes = nil }
        categories = cats
        systemBytes = 0

        scanTask = Task { [home] in
            // 1. Category sizes
            let defs = cats
            let totalSteps = Double(defs.count + 4)
            var done = 0.0
            var sizes: [String: Int64] = [:]

            await withTaskGroup(of: (String, Int64).self) { group in
                var iterator = defs.makeIterator()
                var running = 0
                func enqueue() {
                    guard let c = iterator.next() else { return }
                    running += 1
                    group.addTask {
                        var sum: Int64 = 0
                        for path in c.paths { sum += await Shell.sizeOf(path) }
                        return (c.id, sum)
                    }
                }
                for _ in 0..<5 { enqueue() }
                while let (id, bytes) = await group.next() {
                    running -= 1
                    sizes[id] = bytes
                    done += 1
                    await MainActor.run {
                        if let idx = self.categories.firstIndex(where: { $0.id == id }) {
                            withAnimation(.easeOut(duration: 0.6)) { self.categories[idx].bytes = bytes }
                        }
                        self.scanProgress = done / totalSteps
                        self.scanStatus = "Measured \(self.categories.first(where: { $0.id == id })?.name ?? "")"
                    }
                    enqueue()
                }
            }

            // "Other files in Home" = whole home − all other home-based categories
            let homeTotal = sizes["otherhome"] ?? 0
            let inHome = defs.filter { $0.id != "otherhome" && $0.id != "apps" && $0.id != "syslib" }
                .reduce(Int64(0)) { $0 + (sizes[$1.id] ?? 0) }
            let otherHome = max(homeTotal - inHome, 0)
            sizes["otherhome"] = otherHome
            let used = await MainActor.run { self.volume.used }
            let accounted = sizes.values.reduce(0, +)
            let sysRemainder = max(used - accounted, 0)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.6)) {
                    if let idx = self.categories.firstIndex(where: { $0.id == "otherhome" }) { self.categories[idx].bytes = otherHome }
                    self.systemBytes = sysRemainder
                }
            }

            // 2. Snapshots info
            await MainActor.run { self.scanStatus = "Checking Time Machine snapshots…" }
            let snaps = await Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
            let snapCount = snaps.out.split(separator: "\n").filter { $0.contains("com.apple") }.count
            done += 1
            await MainActor.run { self.snapshotCount = snapCount; self.scanProgress = done / totalSteps }

            // 3. App footprints
            await MainActor.run { self.scanStatus = "Measuring apps and their data…" }
            let footprints = await Self.scanApps(home: home)
            done += 1
            await MainActor.run {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { self.apps = footprints }
                self.scanProgress = done / totalSteps
            }

            // 4. Big files
            await MainActor.run { self.scanStatus = "Hunting for large files…" }
            let big = await Self.findBigFiles(home: home, minBytes: 300_000_000, recentDays: nil)
            let recent = await Self.findBigFiles(home: home, minBytes: 100_000_000, recentDays: 14)
            done += 1
            await MainActor.run {
                withAnimation { self.bigFiles = big; self.recentHeavy = recent }
                self.scanProgress = done / totalSteps
            }

            // 5. Cleanup candidates
            await MainActor.run { self.scanStatus = "Finding things you can safely remove…" }
            let items = await Self.buildCleanup(home: home)
            done += 1
            await MainActor.run {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { self.cleanup = items }
                self.scanProgress = 1
            }

            // 6. Compare with previous scan
            await MainActor.run { self.finishScan() }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanning = false
    }

    private func finishScan() {
        var snap: [String: Int64] = [:]
        for c in categories { if let b = c.bytes { snap["cat:\(c.name)"] = b } }
        for a in apps.prefix(60) { snap["app:\(a.name)"] = a.total }
        if let prev = usage.previousSnapshot() {
            var diffs: [StorageChange] = []
            for (k, now) in snap {
                let before = prev.1[k] ?? 0
                let d = now - before
                if abs(d) > 100_000_000 {
                    diffs.append(StorageChange(name: k.replacingOccurrences(of: "cat:", with: "").replacingOccurrences(of: "app:", with: "App · "), delta: d))
                }
            }
            changes = diffs.sorted { abs($0.delta) > abs($1.delta) }
            changesSince = prev.0
        }
        usage.saveSnapshot(snap)
        lastScan = Date()
        scanning = false
        scanStatus = "Done"
        refreshVolume()
    }

    // MARK: Apps

    nonisolated static func scanApps(home: String) async -> [AppFootprint] {
        let fm = FileManager.default
        var bundles: [String] = []
        for dir in ["/Applications", "/Applications/Utilities", home + "/Applications"] {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            bundles += items.filter { $0.hasSuffix(".app") }.map { dir + "/" + $0 }
        }
        let lib = home + "/Library"
        let groupDirs = (try? fm.contentsOfDirectory(atPath: lib + "/Group Containers")) ?? []

        return await withTaskGroup(of: AppFootprint?.self) { group in
            var out: [AppFootprint] = []
            var iterator = bundles.makeIterator()
            func enqueue() {
                guard let path = iterator.next() else { return }
                group.addTask {
                    let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                    let bid = Bundle(path: path)?.bundleIdentifier ?? ""
                    var fp = AppFootprint(name: name, path: path, bundleID: bid)
                    fp.appBytes = await Shell.sizeOf(path)

                    var dataPaths: [String] = []
                    var cachePaths: [String] = []
                    if !bid.isEmpty {
                        dataPaths += [lib + "/Containers/" + bid, lib + "/Application Support/" + bid,
                                      lib + "/WebKit/" + bid]
                        cachePaths += [lib + "/Caches/" + bid, lib + "/HTTPStorages/" + bid]
                        dataPaths += groupDirs.filter { $0.hasSuffix(bid) || $0.contains(bid) }.map { lib + "/Group Containers/" + $0 }
                    }
                    dataPaths.append(lib + "/Application Support/" + name)
                    cachePaths.append(lib + "/Caches/" + name)
                    for pth in dataPaths where fm.fileExists(atPath: pth) { fp.dataBytes += await Shell.sizeOf(pth) }
                    for pth in cachePaths where fm.fileExists(atPath: pth) {
                        fp.cacheBytes += await Shell.sizeOf(pth)
                        fp.cachePaths.append(pth)
                    }
                    return fp
                }
            }
            for _ in 0..<8 { enqueue() }
            while let r = await group.next() {
                if let r { out.append(r) }
                enqueue()
            }
            return out.sorted { $0.total > $1.total }
        }
    }

    // MARK: Big files via Spotlight

    nonisolated static func findBigFiles(home: String, minBytes: Int64, recentDays: Int?) async -> [BigFile] {
        var query = "kMDItemFSSize > \(minBytes)"
        if let d = recentDays { query += " && kMDItemFSContentChangeDate >= $time.today(-\(d))" }
        let r = await Shell.run("/usr/bin/mdfind", ["-onlyin", home, query], timeout: 60)
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey, .contentAccessDateKey, .contentModificationDateKey]
        var files: [BigFile] = []
        for line in r.out.split(separator: "\n") {
            let path = String(line)
            if path.contains(".app/Contents") { continue }
            guard let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            let size = Int64(v.totalFileAllocatedSize ?? 0)
            guard size >= minBytes / 2 else { continue }
            files.append(BigFile(path: path, bytes: size, lastUsed: v.contentAccessDate, modified: v.contentModificationDate))
        }
        return Array(files.sorted { $0.bytes > $1.bytes }.prefix(60))
    }

    // MARK: Cleanup candidates

    nonisolated static func buildCleanup(home h: String) async -> [CleanupItem] {
        let fm = FileManager.default
        func p(_ s: String) -> String { h + "/" + s }

        struct Def {
            let id, title, detail, icon: String
            let path: String
            let risk: Risk
            let action: CleanupAction
            var nested = false
        }
        var defs: [Def] = [
            Def(id: "caches", title: "App caches", detail: "Temporary files apps rebuild on demand. Apps may start a little slower once afterwards.", icon: "clock.arrow.circlepath",
                path: p("Library/Caches"), risk: .safe, action: .trashContents(p("Library/Caches"))),
            Def(id: "logs", title: "Logs", detail: "Old diagnostic logs from apps.", icon: "doc.text.fill",
                path: p("Library/Logs"), risk: .safe, action: .trashContents(p("Library/Logs"))),
            Def(id: "trash", title: "Trash", detail: "Already deleted files still taking space until the Trash is emptied.", icon: "trash.fill",
                path: p(".Trash"), risk: .review, action: .emptyTrash),
            Def(id: "derived", title: "Xcode DerivedData", detail: "Build products. Xcode regenerates them next build.", icon: "hammer.fill",
                path: p("Library/Developer/Xcode/DerivedData"), risk: .safe, action: .trashContents(p("Library/Developer/Xcode/DerivedData"))),
            Def(id: "devsupport", title: "iOS device support files", detail: "Debug symbols copied from every iPhone/iPad you connected. Re-downloaded when needed.", icon: "iphone",
                path: p("Library/Developer/Xcode/iOS DeviceSupport"), risk: .safe, action: .trashContents(p("Library/Developer/Xcode/iOS DeviceSupport"))),
            Def(id: "archives", title: "Xcode Archives", detail: "Old app archives. Keep the ones you may still need to symbolicate crashes for.", icon: "archivebox.fill",
                path: p("Library/Developer/Xcode/Archives"), risk: .review, action: .revealOnly),
            Def(id: "sims", title: "iOS Simulators", detail: "Simulator runtimes and data. Remove unused ones with Xcode ▸ Settings ▸ Platforms, or run the command.", icon: "ipad.and.iphone",
                path: p("Library/Developer/CoreSimulator"), risk: .review, action: .command("xcrun simctl delete unavailable")),
            Def(id: "backups", title: "iPhone / iPad backups", detail: "Local device backups made through Finder. Delete ones you no longer need.", icon: "externaldrive.badge.timemachine",
                path: p("Library/Application Support/MobileSync/Backup"), risk: .review, action: .revealOnly),
            Def(id: "docker", title: "Docker Desktop data", detail: "Images, containers and volumes. Prune from Docker rather than deleting the folder.", icon: "shippingbox.fill",
                path: p("Library/Containers/com.docker.docker"), risk: .caution, action: .command("docker system prune -a --volumes")),
            Def(id: "mailDl", title: "Mail downloads", detail: "Attachments Mail opened and saved locally.", icon: "envelope.fill",
                path: p("Library/Containers/com.apple.mail/Data/Library/Mail Downloads"), risk: .safe, action: .trashContents(p("Library/Containers/com.apple.mail/Data/Library/Mail Downloads"))),
            Def(id: "npm", title: "npm cache", detail: "Downloaded packages. `npm install` re-downloads when required.", icon: "shippingbox",
                path: p(".npm"), risk: .safe, action: .command("npm cache clean --force")),
            Def(id: "gradle", title: "Gradle caches", detail: "Build dependencies cached by Gradle / Android builds.", icon: "cube.fill",
                path: p(".gradle/caches"), risk: .safe, action: .trashContents(p(".gradle/caches"))),
            Def(id: "cargo", title: "Rust (cargo) registry", detail: "Downloaded crates and git checkouts.", icon: "gearshape.2.fill",
                path: p(".cargo/registry"), risk: .safe, action: .trashContents(p(".cargo/registry"))),
            Def(id: "conda", title: "Anaconda package cache", detail: "Downloaded conda packages and tarballs.", icon: "leaf.fill",
                path: p("anaconda3/pkgs"), risk: .safe, action: .command("conda clean --all")),
            Def(id: "brew", title: "Homebrew downloads", detail: "Old bottles and downloads. (Part of App caches, shown for the command.)", icon: "mug.fill",
                path: p("Library/Caches/Homebrew"), risk: .safe, action: .command("brew cleanup --prune=all"), nested: true),
            Def(id: "avd", title: "Android emulators", detail: "Virtual devices you created. Delete unused ones in Android Studio ▸ Device Manager.", icon: "apps.iphone",
                path: p(".android/avd"), risk: .review, action: .revealOnly),
            Def(id: "asdk", title: "Android SDK system images", detail: "Emulator system images — remove the ones you do not test on.", icon: "square.stack.3d.down.right.fill",
                path: p("Library/Android/sdk/system-images"), risk: .review, action: .revealOnly),
        ]
        defs = defs.filter { fm.fileExists(atPath: $0.path) }

        var items: [CleanupItem] = []
        await withTaskGroup(of: CleanupItem?.self) { group in
            var it = defs.makeIterator()
            func enqueue() {
                guard let d = it.next() else { return }
                group.addTask {
                    let b = await Shell.sizeOf(d.path)
                    guard b > 5_000_000 else { return nil }
                    return CleanupItem(id: d.id, title: d.title, detail: d.detail, icon: d.icon, paths: [d.path], bytes: b, risk: d.risk, action: d.action, nested: d.nested)
                }
            }
            for _ in 0..<5 { enqueue() }
            while let r = await group.next() { if let r { items.append(r) }; enqueue() }
        }

        // Installers & archives in Downloads
        let dl = p("Downloads")
        if let names = try? fm.contentsOfDirectory(atPath: dl) {
            let exts: Set<String> = ["dmg", "pkg", "iso", "zip", "xip"]
            let paths = names.filter { exts.contains(($0 as NSString).pathExtension.lowercased()) }.map { dl + "/" + $0 }
            if !paths.isEmpty {
                var total: Int64 = 0
                for path in paths { total += Int64((try? URL(fileURLWithPath: path).resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0) }
                if total > 20_000_000 {
                    items.append(CleanupItem(id: "installers", title: "Installers & archives in Downloads",
                                             detail: "\(paths.count) .dmg / .pkg / .zip files. Installers are usually not needed once the app is installed.",
                                             icon: "shippingbox.and.arrow.backward.fill", paths: paths, bytes: total, risk: .review, action: .trashPaths(paths)))
                }
            }
        }

        // node_modules
        let find = await Shell.run("/usr/bin/find", [h, "-maxdepth", "7", "-type", "d", "-name", "node_modules", "-prune", "-not", "-path", h + "/Library/*", "-not", "-path", "*/node_modules/*"], timeout: 90)
        let nm = find.out.split(separator: "\n").map(String.init)
        if !nm.isEmpty {
            var total: Int64 = 0
            var sized: [(String, Int64)] = []
            for chunk in stride(from: 0, to: min(nm.count, 200), by: 40) {
                let part = Array(nm[chunk..<min(chunk + 40, nm.count)])
                let r = await Shell.run("/usr/bin/du", ["-skx"] + part)
                for line in r.out.split(separator: "\n") {
                    let f = line.split(separator: "\t", maxSplits: 1)
                    if f.count == 2, let k = Int64(f[0]) { sized.append((String(f[1]), k * 1024)); total += k * 1024 }
                }
            }
            if total > 50_000_000 {
                items.append(CleanupItem(id: "node_modules", title: "node_modules folders (\(sized.count))",
                                         detail: "Project dependencies. `npm install` restores them whenever you reopen a project.",
                                         icon: "chevron.left.forwardslash.chevron.right", paths: sized.sorted { $0.1 > $1.1 }.map(\.0),
                                         bytes: total, risk: .safe, action: .trashPaths(sized.map(\.0))))
            }
        }

        return items.sorted { $0.bytes > $1.bytes }
    }

    var reclaimable: Int64 { cleanup.filter { !$0.nested && $0.risk == .safe }.reduce(0) { $0 + $1.bytes } }
    var reclaimableAll: Int64 { cleanup.filter { !$0.nested }.reduce(0) { $0 + $1.bytes } }

    // MARK: Cleanup actions

    func perform(_ item: CleanupItem) {
        switch item.action {
        case .revealOnly:
            if let p = item.paths.first { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
        case .command(let c):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(c, forType: .string)
            lastActionMessage = "Copied “\(c)” — paste it into Terminal."
        case .emptyTrash:
            guard confirm("Empty the Trash?", "This permanently deletes \(Fmt.bytes(Double(item.bytes))) and cannot be undone.") else { return }
            let script = NSAppleScript(source: "tell application \"Finder\" to empty the trash")
            var err: NSDictionary?
            script?.executeAndReturnError(&err)
            lastActionMessage = err == nil ? "Trash emptied." : "Finder refused to empty the Trash (check Automation permission)."
            rescan(item)
        case .trashContents(let dir):
            guard safeToTrash(dir) else { return }
            guard confirm("Move the contents of “\((dir as NSString).lastPathComponent)” to the Trash?",
                          "About \(Fmt.bytes(Double(item.bytes))). You can restore them from the Trash until you empty it.") else { return }
            let children = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            var failed = 0
            for c in children {
                do { try FileManager.default.trashItem(at: URL(fileURLWithPath: dir + "/" + c), resultingItemURL: nil) } catch { failed += 1 }
            }
            lastActionMessage = failed == 0 ? "Moved to Trash. Empty the Trash to actually free the space." : "Moved most items; \(failed) were in use or protected."
            rescan(item)
        case .trashPaths(let paths):
            guard paths.allSatisfy(safeToTrash) else { return }
            guard confirm("Move \(paths.count) item(s) to the Trash?", "About \(Fmt.bytes(Double(item.bytes))). You can restore them from the Trash until you empty it.") else { return }
            var failed = 0
            for p in paths {
                do { try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil) } catch { failed += 1 }
            }
            lastActionMessage = failed == 0 ? "Moved to Trash. Empty the Trash to actually free the space." : "Moved most items; \(failed) failed."
            rescan(item)
        }
    }

    func trashFile(_ file: BigFile) {
        guard safeToTrash(file.path) else { return }
        guard confirm("Move “\(file.name)” to the Trash?", "\(Fmt.bytes(Double(file.bytes))) · \(file.folder)") else { return }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: file.path), resultingItemURL: nil)
            withAnimation { bigFiles.removeAll { $0.id == file.id }; recentHeavy.removeAll { $0.id == file.id } }
            lastActionMessage = "Moved “\(file.name)” to the Trash."
        } catch {
            lastActionMessage = "Could not move file: \(error.localizedDescription)"
        }
    }

    func trashAppCaches(_ app: AppFootprint) {
        guard !app.cachePaths.isEmpty, app.cachePaths.allSatisfy(safeToTrash) else { return }
        guard confirm("Clear caches for \(app.name)?", "Moves \(Fmt.bytes(Double(app.cacheBytes))) of cache files to the Trash. The app rebuilds them as needed.") else { return }
        for p in app.cachePaths { try? FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil) }
        if let i = apps.firstIndex(where: { $0.id == app.id }) { withAnimation { apps[i].cacheBytes = 0; apps[i].cachePaths = [] } }
        lastActionMessage = "Cleared \(app.name) caches."
    }

    private func rescan(_ item: CleanupItem) {
        Task {
            let b = await Shell.sizeOf(item.paths.first ?? "")
            if let i = cleanup.firstIndex(where: { $0.id == item.id }) {
                withAnimation(.spring) {
                    if b < 5_000_000 { cleanup.remove(at: i) } else { cleanup[i].bytes = b }
                }
            }
            refreshVolume()
        }
    }

    private func safeToTrash(_ path: String) -> Bool {
        path.hasPrefix(home + "/") && path.count > home.count + 3 && !path.contains("..")
    }

    private func confirm(_ title: String, _ message: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = .warning
        a.addButton(withTitle: "Continue")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    // MARK: Folder explorer

    func openExplorer(_ path: String) {
        explorerStack = [path]
        loadExplorer(path)
    }

    func descend(_ entry: FolderEntry) {
        guard entry.isDir else { return }
        explorerStack.append(entry.path)
        loadExplorer(entry.path)
    }

    func ascend(to index: Int) {
        guard index < explorerStack.count else { return }
        explorerStack = Array(explorerStack.prefix(index + 1))
        loadExplorer(explorerStack[index])
    }

    private func loadExplorer(_ path: String) {
        if let cached = explorerCache[path] {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { explorerEntries = cached }
            return
        }
        explorerLoading = true
        Task {
            // `du -a` and `-d` cannot be combined on macOS: sizes of sub-folders come from du, files from FileManager.
            let r = await Shell.run("/usr/bin/du", ["-kx", "-d", "1", path], timeout: 900)
            var entries: [FolderEntry] = []
            for line in r.out.split(separator: "\n") {
                let f = line.split(separator: "\t", maxSplits: 1)
                guard f.count == 2, let kb = Int64(f[0]) else { continue }
                let full = String(f[1])
                if full == path || full == path + "/" { continue }
                entries.append(FolderEntry(name: (full as NSString).lastPathComponent, path: full, bytes: kb * 1024, isDir: true))
            }
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey]
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                let full = (path as NSString).appendingPathComponent(name)
                guard let v = try? URL(fileURLWithPath: full).resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
                entries.append(FolderEntry(name: name, path: full, bytes: Int64(v.totalFileAllocatedSize ?? 0), isDir: false))
            }
            entries.sort { $0.bytes > $1.bytes }
            explorerCache[path] = entries
            if explorerStack.last == path {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { explorerEntries = entries }
            }
            explorerLoading = false
        }
    }
}
