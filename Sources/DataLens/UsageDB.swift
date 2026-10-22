import Foundation

// MARK: - Models

enum Period: String, CaseIterable, Identifiable {
    case day = "24 Hours"
    case week = "7 Days"
    case month = "30 Days"
    case year = "12 Months"
    case all = "All Time"

    var id: String { rawValue }

    var short: String {
        switch self {
        case .day: return "Today"
        case .week: return "Week"
        case .month: return "Month"
        case .year: return "Year"
        case .all: return "All"
        }
    }

    func start(from now: Date = Date()) -> Date? {
        let c = Calendar.current
        switch self {
        case .day: return now.addingTimeInterval(-86400)
        case .week: return c.date(byAdding: .day, value: -7, to: c.startOfDay(for: now))
        case .month: return c.date(byAdding: .day, value: -30, to: c.startOfDay(for: now))
        case .year: return c.date(byAdding: .month, value: -11, to: c.dateInterval(of: .month, for: now)?.start ?? now)
        case .all: return nil
        }
    }
}

struct SeriesPoint: Identifiable {
    var id: Date { date }
    let date: Date
    var down: Double
    var up: Double
    var total: Double { down + up }
}

struct AppUsage: Identifiable {
    var id: String { name }
    let name: String
    var down: Double
    var up: Double
    var total: Double { down + up }
}

struct NetworkSummary: Identifiable {
    var id: String { ssid }
    let ssid: String
    var down: Double
    var up: Double
    var first: Date
    var last: Date
    var total: Double { down + up }
}

struct HeatCell: Identifiable {
    var id: Int { weekday * 24 + hour }
    let weekday: Int   // 0 = Monday
    let hour: Int
    var bytes: Double
}

enum Bucket { case hour, day, month
    var component: Calendar.Component {
        switch self { case .hour: return .hour; case .day: return .day; case .month: return .month }
    }
}

// MARK: - Database

final class UsageDB: @unchecked Sendable {
    let db: SQLiteDB
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("DataLens", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        if Demo.on { try? FileManager.default.removeItem(atPath: Demo.databasePath) }
        let path = Demo.on ? Demo.databasePath : Self.directory.appendingPathComponent("usage.sqlite").path
        db = SQLiteDB(path: path) ?? SQLiteDB(path: ":memory:")!
        db.exec("PRAGMA journal_mode=WAL")
        db.exec("CREATE TABLE IF NOT EXISTS totals(hour INTEGER, ssid TEXT, bin INTEGER, bout INTEGER, PRIMARY KEY(hour, ssid))")
        db.exec("CREATE TABLE IF NOT EXISTS usage(hour INTEGER, ssid TEXT, app TEXT, bin INTEGER, bout INTEGER, PRIMARY KEY(hour, ssid, app))")
        db.exec("CREATE INDEX IF NOT EXISTS usage_hour ON usage(hour)")
        db.exec("CREATE TABLE IF NOT EXISTS storage_hist(ts INTEGER PRIMARY KEY, total INTEGER, free INTEGER, purgeable INTEGER)")
        db.exec("CREATE TABLE IF NOT EXISTS scan_snap(ts INTEGER, key TEXT, bytes INTEGER)")
        if Demo.on { Demo.seed(self) }
    }

    // MARK: Writes

    func addTotals(_ rows: [(hour: Int, ssid: String, bin: Double, bout: Double)]) {
        guard !rows.isEmpty else { return }
        db.transaction {
            for r in rows {
                db.exec("""
                INSERT INTO totals(hour, ssid, bin, bout) VALUES(?,?,?,?)
                ON CONFLICT(hour, ssid) DO UPDATE SET bin = bin + excluded.bin, bout = bout + excluded.bout
                """, [r.hour, r.ssid, Int64(r.bin), Int64(r.bout)])
            }
        }
    }

    func addApps(_ rows: [(hour: Int, ssid: String, app: String, bin: Double, bout: Double)]) {
        guard !rows.isEmpty else { return }
        db.transaction {
            for r in rows {
                db.exec("""
                INSERT INTO usage(hour, ssid, app, bin, bout) VALUES(?,?,?,?,?)
                ON CONFLICT(hour, ssid, app) DO UPDATE SET bin = bin + excluded.bin, bout = bout + excluded.bout
                """, [r.hour, r.ssid, r.app, Int64(r.bin), Int64(r.bout)])
            }
        }
    }

    func recordStorage(total: Int64, free: Int64, purgeable: Int64) {
        let now = Int(Date().timeIntervalSince1970)
        // at most one row every 3 hours
        let last = db.query("SELECT MAX(ts) AS m FROM storage_hist").first?.int("m") ?? 0
        if now - Int(last) < 3 * 3600 { return }
        db.exec("INSERT OR REPLACE INTO storage_hist(ts, total, free, purgeable) VALUES(?,?,?,?)", [now, total, free, purgeable])
    }

    // MARK: Reads

    private func ssidClause(_ ssid: String?) -> (String, [Any?]) {
        guard let ssid else { return ("", []) }
        return (" AND ssid = ?", [ssid])
    }

    func networks() -> [NetworkSummary] {
        db.query("SELECT ssid, SUM(bin) AS bi, SUM(bout) AS bo, MIN(hour) AS f, MAX(hour) AS l FROM totals GROUP BY ssid ORDER BY SUM(bin)+SUM(bout) DESC")
            .map {
                NetworkSummary(ssid: $0.str("ssid"), down: $0.dbl("bi"), up: $0.dbl("bo"),
                               first: Date(timeIntervalSince1970: $0.dbl("f")),
                               last: Date(timeIntervalSince1970: $0.dbl("l")))
            }
    }

    func totals(ssid: String?, from: Date?, to: Date? = nil) -> (down: Double, up: Double) {
        let (clause, p) = ssidClause(ssid)
        let lo = Int(from?.timeIntervalSince1970 ?? 0)
        let hi = Int(to?.timeIntervalSince1970 ?? Date().timeIntervalSince1970 + 3600)
        let r = db.query("SELECT SUM(bin) AS bi, SUM(bout) AS bo FROM totals WHERE hour >= ? AND hour < ?" + clause, [lo, hi] + p)
        return (r.first?.dbl("bi") ?? 0, r.first?.dbl("bo") ?? 0)
    }

    func firstHour(ssid: String?) -> Date? {
        let (clause, p) = ssidClause(ssid)
        let r = db.query("SELECT MIN(hour) AS m FROM totals WHERE 1=1" + clause, p)
        guard let m = r.first?.dbl("m"), m > 0 else { return nil }
        return Date(timeIntervalSince1970: m)
    }

    func bucket(for period: Period, ssid: String?) -> Bucket {
        switch period {
        case .day: return .hour
        case .week, .month: return .day
        case .year: return .month
        case .all:
            let first = firstHour(ssid: ssid) ?? Date()
            let span = Date().timeIntervalSince(first)
            return span <= 2 * 86400 ? .hour : (span <= 150 * 86400 ? .day : .month)
        }
    }

    func series(ssid: String?, period: Period) -> [SeriesPoint] {
        let cal = Calendar.current
        let now = Date()
        let b = bucket(for: period, ssid: ssid)
        var from = period.start(from: now) ?? firstHour(ssid: ssid) ?? now.addingTimeInterval(-86400)
        if let interval = cal.dateInterval(of: b.component, for: from) { from = interval.start }

        let (clause, p) = ssidClause(ssid)
        let rows = db.query("SELECT hour, SUM(bin) AS bi, SUM(bout) AS bo FROM totals WHERE hour >= ?" + clause + " GROUP BY hour",
                            [Int(from.timeIntervalSince1970)] + p)
        var map: [Date: SeriesPoint] = [:]
        for r in rows {
            let d = Date(timeIntervalSince1970: r.dbl("hour"))
            let key = cal.dateInterval(of: b.component, for: d)?.start ?? d
            var pt = map[key] ?? SeriesPoint(date: key, down: 0, up: 0)
            pt.down += r.dbl("bi"); pt.up += r.dbl("bo")
            map[key] = pt
        }
        var out: [SeriesPoint] = []
        var cursor = from
        var guardCount = 0
        while cursor <= now, guardCount < 5000 {
            out.append(map[cursor] ?? SeriesPoint(date: cursor, down: 0, up: 0))
            guard let next = cal.date(byAdding: b.component, value: 1, to: cursor) else { break }
            cursor = next
            guardCount += 1
        }
        return out
    }

    func apps(ssid: String?, period: Period) -> [AppUsage] {
        let (clause, p) = ssidClause(ssid)
        let from = Int(period.start()?.timeIntervalSince1970 ?? 0)
        return db.query("SELECT app, SUM(bin) AS bi, SUM(bout) AS bo FROM usage WHERE hour >= ?" + clause + " GROUP BY app ORDER BY SUM(bin)+SUM(bout) DESC LIMIT 60",
                        [from] + p)
            .map { AppUsage(name: $0.str("app"), down: $0.dbl("bi"), up: $0.dbl("bo")) }
            .filter { $0.total > 0 }
    }

    /// Per-app usage for one app over time (for the detail sheet).
    func appSeries(app: String, ssid: String?, period: Period) -> [SeriesPoint] {
        let cal = Calendar.current
        let b = bucket(for: period, ssid: ssid)
        let (clause, p) = ssidClause(ssid)
        let from = Int(period.start()?.timeIntervalSince1970 ?? 0)
        let rows = db.query("SELECT hour, SUM(bin) AS bi, SUM(bout) AS bo FROM usage WHERE hour >= ? AND app = ?" + clause + " GROUP BY hour",
                            [from, app] + p)
        var map: [Date: SeriesPoint] = [:]
        for r in rows {
            let d = Date(timeIntervalSince1970: r.dbl("hour"))
            let key = cal.dateInterval(of: b.component, for: d)?.start ?? d
            var pt = map[key] ?? SeriesPoint(date: key, down: 0, up: 0)
            pt.down += r.dbl("bi"); pt.up += r.dbl("bo")
            map[key] = pt
        }
        return map.values.sorted { $0.date < $1.date }
    }

    func heat(ssid: String?, period: Period) -> [HeatCell] {
        let cal = Calendar.current
        let (clause, p) = ssidClause(ssid)
        let start = period.start() ?? Date().addingTimeInterval(-90 * 86400)
        let from = Int(min(start, Date().addingTimeInterval(-28 * 86400)).timeIntervalSince1970)
        let rows = db.query("SELECT hour, SUM(bin)+SUM(bout) AS t FROM totals WHERE hour >= ?" + clause + " GROUP BY hour", [from] + p)
        var grid = [Int: Double]()
        for r in rows {
            let d = Date(timeIntervalSince1970: r.dbl("hour"))
            let wd = (cal.component(.weekday, from: d) + 5) % 7  // Monday = 0
            let h = cal.component(.hour, from: d)
            grid[wd * 24 + h, default: 0] += r.dbl("t")
        }
        return (0..<7).flatMap { w in (0..<24).map { h in HeatCell(weekday: w, hour: h, bytes: grid[w * 24 + h] ?? 0) } }
    }

    func storageHistory() -> [(Date, Int64, Int64)] {
        db.query("SELECT ts, total, free FROM storage_hist ORDER BY ts").map {
            (Date(timeIntervalSince1970: $0.dbl("ts")), $0.int("total"), $0.int("free"))
        }
    }

    // scan snapshots for "what changed"
    func saveSnapshot(_ items: [String: Int64]) {
        let ts = Int(Date().timeIntervalSince1970)
        db.transaction {
            for (k, v) in items { db.exec("INSERT INTO scan_snap(ts, key, bytes) VALUES(?,?,?)", [ts, k, v]) }
        }
        db.exec("DELETE FROM scan_snap WHERE ts < ?", [ts - 400 * 86400])
    }

    func previousSnapshot(olderThan seconds: Int = 3600) -> (Date, [String: Int64])? {
        let cutoff = Int(Date().timeIntervalSince1970) - seconds
        guard let ts = db.query("SELECT MAX(ts) AS m FROM scan_snap WHERE ts < ?", [cutoff]).first?.int("m"), ts > 0 else { return nil }
        let rows = db.query("SELECT key, bytes FROM scan_snap WHERE ts = ?", [ts])
        var d: [String: Int64] = [:]
        for r in rows { d[r.str("key")] = r.int("bytes") }
        return (Date(timeIntervalSince1970: TimeInterval(ts)), d)
    }
}
