import Foundation
import SwiftUI

/// Demo mode (`DATALENS_DEMO=1`): runs on made-up data in a throw-away database,
/// so the app can be shown or screenshotted without exposing real networks, apps or files.
enum Demo {
    static let on = ProcessInfo.processInfo.environment["DATALENS_DEMO"] != nil
    static let ssid = "Home Wi-Fi"

    static var databasePath: String {
        NSTemporaryDirectory() + "datalens-demo.sqlite"
    }

    // MARK: Network history

    static func seed(_ db: UsageDB) {
        var seed: UInt64 = 42
        func rnd() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31)
        }
        let now = Int(Date().timeIntervalSince1970)
        let cal = Calendar.current
        let start = (now / 3600) * 3600 - 150 * 86400
        let apps: [(String, Double, Double)] = [   // name, share, upload ratio
            ("Safari", 0.24, 0.05), ("Google Chrome", 0.16, 0.05), ("YouTube", 0.12, 0.01), ("Spotify", 0.07, 0.01),
            ("Slack", 0.06, 0.25), ("zoom.us", 0.08, 0.45), ("Dropbox", 0.07, 0.6), ("Xcode", 0.06, 0.03),
            ("Mail", 0.04, 0.2), ("Notion", 0.03, 0.2), ("App Store", 0.05, 0.0), ("Messages", 0.02, 0.4),
        ]
        var totals: [(hour: Int, ssid: String, bin: Double, bout: Double)] = []
        var appRows: [(hour: Int, ssid: String, app: String, bin: Double, bout: Double)] = []
        var h = start
        while h <= now {
            let d = Date(timeIntervalSince1970: TimeInterval(h))
            let hour = cal.component(.hour, from: d)
            let weekday = (cal.component(.weekday, from: d) + 5) % 7
            let work = weekday < 5 && (9...17).contains(hour)
            let evening = (19...23).contains(hour)
            let ssid = work && rnd() < 0.7 ? "Office" : (rnd() < 0.03 ? "Coffee Shop" : "Home Wi-Fi")
            var base = 8e6
            if (8...23).contains(hour) { base = 60e6 }
            if work { base = 140e6 }
            if evening { base = 260e6 }
            if weekday >= 5 && (10...22).contains(hour) { base *= 1.5 }
            let bytes = base * (0.2 + rnd() * 1.6) * (rnd() < 0.05 ? 6 : 1)
            let up = bytes * (0.08 + rnd() * 0.1)
            totals.append((h, ssid, bytes - up, up))
            if h > now - 45 * 86400 {
                for a in apps {
                    let b = bytes * a.1 * (0.4 + rnd() * 1.2)
                    appRows.append((h, ssid, a.0, b * (1 - a.2), b * a.2))
                }
            }
            h += 3600
        }
        db.addTotals(totals)
        db.addApps(appRows)

        // free-space history
        var free = 205e9
        for day in stride(from: 40, through: 0, by: -1) {
            free -= rnd() * 3.5e9 - (day % 9 == 0 ? 9e9 : 0.3e9)
            db.db.exec("INSERT OR REPLACE INTO storage_hist(ts, total, free, purgeable) VALUES(?,?,?,?)",
                       [now - day * 86400, Int64(500e9), Int64(free), Int64(12e9)])
        }
    }

    // MARK: Storage

    static let volume: VolumeInfo = {
        var v = VolumeInfo()
        v.total = 500_000_000_000
        v.free = 142_000_000_000
        v.importantFree = 158_000_000_000
        return v
    }()

    @MainActor static func categories(home: String) -> ([StorageCategory], Int64) {
        var cats = StorageStore.categoryDefinitions(home: home)
        let gb: [String: Double] = ["apps": 31, "docs": 42, "desktop": 3, "downloads": 18, "movies": 36, "music": 12, "pictures": 27,
                                    "dev": 24, "caches": 7, "support": 22, "containers": 14, "mail": 5, "icloud": 9, "trash": 2,
                                    "otherhome": 28, "syslib": 19]
        for i in cats.indices { cats[i].bytes = Int64((gb[cats[i].id] ?? 1) * 1e9) }
        return (cats, 38_000_000_000)
    }

    static func apps() -> [AppFootprint] {
        func app(_ n: String, _ a: Double, _ d: Double, _ c: Double) -> AppFootprint {
            var f = AppFootprint(name: n, path: "/Applications/\(n).app", bundleID: "demo.\(n)")
            f.appBytes = Int64(a * 1e9); f.dataBytes = Int64(d * 1e9); f.cacheBytes = Int64(c * 1e9)
            return f
        }
        return [app("Xcode", 14.2, 6.1, 1.4), app("Final Cut Pro", 4.1, 9.8, 0.6), app("Docker", 1.1, 8.9, 0.2), app("Slack", 0.4, 2.8, 1.9),
                app("Google Chrome", 1.5, 1.1, 1.3), app("Android Studio", 3.1, 2.2, 0.9), app("Spotify", 0.3, 0.8, 3.1), app("Notion", 0.3, 3.9, 0.3),
                app("Adobe Photoshop", 5.2, 0.9, 1.2), app("Figma", 0.5, 1.2, 0.8), app("zoom.us", 0.5, 0.7, 0.1), app("Postman", 0.5, 1.2, 0.0),
                app("Microsoft Edge", 1.6, 0.9, 0.5), app("VLC", 0.2, 0.1, 0.0), app("Safari", 0.0, 0.8, 0.9)]
    }

    static func cleanup() -> [CleanupItem] {
        func i(_ id: String, _ t: String, _ d: String, _ icon: String, _ gb: Double, _ r: Risk, _ a: CleanupAction) -> CleanupItem {
            CleanupItem(id: id, title: t, detail: d, icon: icon, paths: ["/demo/\(id)"], bytes: Int64(gb * 1e9), risk: r, action: a)
        }
        return [
            i("sims", "iOS Simulators", "Simulator runtimes and data. Remove unused ones with Xcode ▸ Settings ▸ Platforms, or run the command.", "ipad.and.iphone", 12.4, .review, .command("xcrun simctl delete unavailable")),
            i("nm", "node_modules folders (31)", "Project dependencies. `npm install` restores them whenever you reopen a project.", "chevron.left.forwardslash.chevron.right", 9.6, .safe, .revealOnly),
            i("docker", "Docker Desktop data", "Images, containers and volumes. Prune from Docker rather than deleting the folder.", "shippingbox.fill", 8.9, .caution, .command("docker system prune -a --volumes")),
            i("caches", "App caches", "Temporary files apps rebuild on demand. Apps may start a little slower once afterwards.", "clock.arrow.circlepath", 6.9, .safe, .revealOnly),
            i("devsupport", "iOS device support files", "Debug symbols copied from every iPhone/iPad you connected. Re-downloaded when needed.", "iphone", 5.8, .safe, .revealOnly),
            i("installers", "Installers & archives in Downloads", "14 .dmg / .pkg / .zip files. Installers are usually not needed once the app is installed.", "shippingbox.and.arrow.backward.fill", 4.7, .review, .revealOnly),
            i("derived", "Xcode DerivedData", "Build products. Xcode regenerates them next build.", "hammer.fill", 3.2, .safe, .revealOnly),
            i("backups", "iPhone / iPad backups", "Local device backups made through Finder. Delete ones you no longer need.", "externaldrive.badge.timemachine", 2.1, .review, .revealOnly),
        ]
    }

    static func bigFiles() -> [BigFile] {
        let old = Date().addingTimeInterval(-300 * 86400)
        func f(_ p: String, _ gb: Double, old o: Bool = false) -> BigFile {
            BigFile(path: p, bytes: Int64(gb * 1e9), lastUsed: o ? old : Date().addingTimeInterval(-2 * 86400), modified: o ? old : Date())
        }
        return [f("/Users/demo/Movies/Project-Render-Final.mov", 9.8), f("/Users/demo/Downloads/ubuntu-24.04-desktop.iso", 5.9, old: true),
                f("/Users/demo/Documents/VMs/Windows11.pvm.zip", 4.6, old: true), f("/Users/demo/Pictures/Photos Library.photoslibrary/original.heic", 3.4),
                f("/Users/demo/Documents/datasets/training-data.csv", 2.7), f("/Users/demo/Downloads/Xcode_16.xip", 2.4, old: true)]
    }

    static func explorer() -> [FolderEntry] {
        let list: [(String, Double, Bool)] = [("Library", 61, true), ("Movies", 36, true), ("Documents", 42, true), ("Projects", 19, true), ("Downloads", 18, true),
                                              ("Pictures", 27, true), ("Music", 12, true), (".docker", 8, true), (".npm", 4, true), ("Desktop", 3, true),
                                              ("notes.md", 0.001, false)]
        return list.map { FolderEntry(name: $0.0, path: "/Users/demo/\($0.0)", bytes: Int64($0.1 * 1e9), isDir: $0.2) }
    }

    static func talkers() -> [TalkerRate] {
        [TalkerRate(name: "Safari", down: 2.4e6, up: 90e3), TalkerRate(name: "Spotify", down: 410e3, up: 12e3),
         TalkerRate(name: "Slack", down: 120e3, up: 40e3), TalkerRate(name: "Dropbox", down: 30e3, up: 900e3)]
    }
}
