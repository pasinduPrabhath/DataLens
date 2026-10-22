import Foundation
import SwiftUI
import Combine

struct NetSnapshot {
    var series: [SeriesPoint] = []
    var apps: [AppUsage] = []
    var networks: [NetworkSummary] = []
    var heat: [HeatCell] = []
    var down = 0.0
    var up = 0.0
    var prevTotal = 0.0
    var monthTotal = 0.0
    var firstSeen: Date?
    var bucket: Bucket = .day
}

@MainActor
final class NetStore: ObservableObject {
    let monitor: NetworkMonitor

    @Published var selectedSSID: String? = nil { didSet { reload() } }
    @Published var period: Period = .week { didSet { reload() } }
    @Published var snap = NetSnapshot()
    @Published var capGB: Double = UserDefaults.standard.double(forKey: "monthlyCapGB") {
        didSet { UserDefaults.standard.set(capGB, forKey: "monthlyCapGB") }
    }

    private var bag = Set<AnyCancellable>()
    private var loading = false

    init(monitor: NetworkMonitor) {
        self.monitor = monitor
        monitor.$dataVersion
            .throttle(for: .seconds(2), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &bag)
        reload()
    }

    var total: Double { snap.down + snap.up }

    var daysInPeriod: Double {
        switch period {
        case .day: return 1
        case .week: return 7
        case .month: return 30
        case .year: return 365
        case .all:
            guard let f = snap.firstSeen else { return 1 }
            return max(Date().timeIntervalSince(f) / 86400, 1)
        }
    }

    func reload() {
        let db = monitor.usage
        let ssid = selectedSSID
        let period = period
        Task.detached(priority: .userInitiated) {
            let now = Date()
            var s = NetSnapshot()
            s.series = db.series(ssid: ssid, period: period)
            s.apps = db.apps(ssid: ssid, period: period)
            s.networks = db.networks()
            s.heat = db.heat(ssid: ssid, period: period)
            s.bucket = db.bucket(for: period, ssid: ssid)
            s.firstSeen = db.firstHour(ssid: ssid)
            let t = db.totals(ssid: ssid, from: period.start(from: now))
            s.down = t.down; s.up = t.up
            if let start = period.start(from: now) {
                let prevStart = start.addingTimeInterval(-now.timeIntervalSince(start))
                let p = db.totals(ssid: ssid, from: prevStart, to: start)
                s.prevTotal = p.down + p.up
            }
            let monthStart = Calendar.current.dateInterval(of: .month, for: now)?.start
            let m = db.totals(ssid: ssid, from: monthStart)
            s.monthTotal = m.down + m.up
            let final = s
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.7)) { self.snap = final }
            }
        }
    }

    /// Short human sentences derived from the data.
    var insights: [(icon: String, text: String, color: Color)] {
        var out: [(String, String, Color)] = []
        let t = total
        guard t > 0 else { return out }

        if let top = snap.apps.first, snap.apps.count > 0 {
            let share = top.total / max(snap.apps.reduce(0) { $0 + $1.total }, 1)
            out.append(("flame.fill", "\(top.name) used \(Fmt.percent(share)) of your tracked data (\(Fmt.bytes(top.total))).", Theme.orange))
        }
        if let busiest = snap.series.max(by: { $0.total < $1.total }), busiest.total > 0 {
            let f = DateFormatter()
            f.dateFormat = snap.bucket == .month ? "MMMM yyyy" : (snap.bucket == .day ? "EEE d MMM" : "ha, d MMM")
            out.append(("calendar", "Heaviest \(snap.bucket == .month ? "month" : snap.bucket == .day ? "day" : "hour"): \(f.string(from: busiest.date)) with \(Fmt.bytes(busiest.total)).", Theme.purple))
        }
        if snap.down > 0 {
            let ratio = snap.up / snap.down
            if ratio > 0.5 {
                out.append(("arrow.up.circle.fill", "You upload a lot — \(Fmt.percent(ratio)) as much as you download. Cloud backups or video calls?", Theme.pink))
            } else {
                out.append(("arrow.down.circle.fill", "Downloads outweigh uploads \(String(format: "%.1f", 1 / max(ratio, 0.01)))×.", Theme.cyan))
            }
        }
        if snap.prevTotal > 0, period != .all {
            let delta = (t - snap.prevTotal) / snap.prevTotal
            let up = delta >= 0
            out.append((up ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis",
                        "\(up ? "Up" : "Down") \(Fmt.percent(abs(delta))) compared with the previous \(period.rawValue.lowercased()).",
                        up ? Theme.red : Theme.green))
        }
        if let peak = snap.heat.max(by: { $0.bytes < $1.bytes }), peak.bytes > 0 {
            let days = ["Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays", "Sundays"]
            out.append(("clock.fill", "You are busiest on \(days[peak.weekday]) around \(String(format: "%02d:00", peak.hour)).", Theme.blue))
        }
        return out.map { (icon: $0.0, text: $0.1, color: $0.2) }
    }
}
