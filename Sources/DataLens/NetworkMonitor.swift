import Foundation
import CoreWLAN
import CoreLocation
import AppKit
import SwiftUI

struct WifiInfo: Equatable {
    var interfaceName = "en0"
    var powerOn = false
    var ssid: String? = nil
    var bssid: String? = nil
    var rssi = 0
    var noise = 0
    var txRate = 0.0
    var channel = 0
    var band = "—"
    var security = "—"
    var phy = "—"
    var snr: Int { rssi - noise }
    /// 0...1
    var quality: Double { min(max((Double(rssi) + 90) / 50, 0), 1) }
}

struct SpeedPoint: Identifiable {
    let id = UUID()
    let t: Date
    let down: Double
    let up: Double
}

struct TalkerRate: Identifiable {
    var id: String { name }
    let name: String
    var down: Double
    var up: Double
    var total: Double { down + up }
}

@MainActor
final class NetworkMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var wifi = WifiInfo()
    @Published var locationStatus: CLAuthorizationStatus = .notDetermined
    @Published var downSpeed = 0.0
    @Published var upSpeed = 0.0
    @Published var peakDown = 0.0
    @Published var peakUp = 0.0
    @Published var speedHistory: [SpeedPoint] = []
    @Published var talkers: [TalkerRate] = []
    @Published var sessionDown = 0.0
    @Published var sessionUp = 0.0
    @Published var dataVersion = 0

    let usage: UsageDB
    private let locationManager = CLLocationManager()
    private let client = CWWiFiClient.shared()

    private var prevCounters: (UInt32, UInt32)?
    private var lastTick = Date()
    private var tickTimer: Timer?
    private var nettopTimer: Timer?
    private var flushTimer: Timer?
    private var nettopBusy = false
    private var prevProc: [String: (Double, Double)] = [:]
    private var lastNettop = Date()

    private var pendingTotals: [String: (hour: Int, ssid: String, bin: Double, bout: Double)] = [:]
    private var pendingApps: [String: (hour: Int, ssid: String, app: String, bin: Double, bout: Double)] = [:]

    var ssidAccessible: Bool {
        Demo.on || locationStatus == .authorizedAlways
    }

    /// Name used to file traffic that is happening right now.
    var currentKey: String {
        if Demo.on { return Demo.ssid }
        if let s = wifi.ssid, !s.isEmpty { return s }
        return wifi.powerOn ? "Wi-Fi (name hidden)" : "Wi-Fi (off)"
    }

    init(usage: UsageDB) {
        self.usage = usage
        super.init()
        locationManager.delegate = self
        locationStatus = locationManager.authorizationStatus
        if locationStatus == .notDetermined { locationManager.requestWhenInUseAuthorization() }
        start()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    func requestLocation() {
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.locationManager.stopUpdatingLocation() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.locationStatus = status
            self.refreshWifi()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    // MARK: Timers

    private func start() {
        refreshWifi()
        prevCounters = readCounters(wifi.interfaceName)
        tickTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        nettopTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleApps() }
        }
        flushTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
        sampleApps()
    }

    // MARK: Wi-Fi details

    func refreshWifi() {
        guard let iface = client.interface() else {
            wifi = WifiInfo()
            return
        }
        var info = WifiInfo()
        info.interfaceName = iface.interfaceName ?? "en0"
        info.powerOn = iface.powerOn()
        info.ssid = Demo.on ? Demo.ssid : iface.ssid()
        info.bssid = Demo.on ? nil : iface.bssid()
        info.rssi = iface.rssiValue()
        info.noise = iface.noiseMeasurement()
        info.txRate = iface.transmitRate()
        if let ch = iface.wlanChannel() {
            info.channel = ch.channelNumber
            switch ch.channelBand {
            case .band2GHz: info.band = "2.4 GHz"
            case .band5GHz: info.band = "5 GHz"
            case .band6GHz: info.band = "6 GHz"
            default: info.band = "—"
            }
        }
        info.security = Self.securityName(iface.security())
        info.phy = Self.phyName(iface.activePHYMode())
        if info != wifi { wifi = info }
    }

    private static func securityName(_ s: CWSecurity) -> String {
        switch s {
        case .none: return "Open"
        case .WEP: return "WEP"
        case .wpaPersonal, .wpaPersonalMixed: return "WPA"
        case .wpa2Personal: return "WPA2"
        case .personal: return "WPA/WPA2"
        case .dynamicWEP: return "Dynamic WEP"
        case .wpaEnterprise, .wpaEnterpriseMixed: return "WPA Enterprise"
        case .wpa2Enterprise: return "WPA2 Enterprise"
        case .enterprise: return "Enterprise"
        case .wpa3Personal: return "WPA3"
        case .wpa3Enterprise: return "WPA3 Enterprise"
        case .wpa3Transition: return "WPA3 Transition"
        case .OWE, .oweTransition: return "Enhanced Open"
        default: return "—"
        }
    }

    private static func phyName(_ p: CWPHYMode) -> String {
        switch p {
        case .mode11a: return "802.11a"
        case .mode11b: return "802.11b"
        case .mode11g: return "802.11g"
        case .mode11n: return "Wi-Fi 4"
        case .mode11ac: return "Wi-Fi 5"
        case .mode11ax: return "Wi-Fi 6"
        default: return "—"
        }
    }

    // MARK: Interface counters

    private func readCounters(_ name: String) -> (UInt32, UInt32)? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            if String(cString: a.pointee.ifa_name) == name,
               let addr = a.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               let data = a.pointee.ifa_data {
                let d = data.assumingMemoryBound(to: if_data.self).pointee
                return (d.ifi_ibytes, d.ifi_obytes)
            }
            p = a.pointee.ifa_next
        }
        return nil
    }

    private func tick() {
        refreshWifi()
        let now = Date()
        let dt = max(now.timeIntervalSince(lastTick), 0.5)
        lastTick = now
        guard let cur = readCounters(wifi.interfaceName) else { return }
        defer { prevCounters = cur }
        guard let prev = prevCounters else { return }
        let din = Double(cur.0 &- prev.0)
        let dout = Double(cur.1 &- prev.1)
        // ignore absurd jumps (interface reset)
        guard din < 4e9, dout < 4e9 else { return }

        downSpeed = din / dt
        upSpeed = dout / dt
        peakDown = max(peakDown, downSpeed)
        peakUp = max(peakUp, upSpeed)
        sessionDown += din
        sessionUp += dout
        speedHistory.append(SpeedPoint(t: now, down: downSpeed, up: upSpeed))
        if speedHistory.count > 90 { speedHistory.removeFirst(speedHistory.count - 90) }

        if din > 0 || dout > 0 {
            let hour = Int(now.timeIntervalSince1970 / 3600) * 3600
            let ssid = currentKey
            let key = "\(hour)|\(ssid)"
            var e = pendingTotals[key] ?? (hour, ssid, 0, 0)
            e.bin += din; e.bout += dout
            pendingTotals[key] = e
        }
    }

    // MARK: Per-app sampling (nettop)

    private func sampleApps() {
        guard !nettopBusy else { return }
        nettopBusy = true
        Task {
            let r = await Shell.run("/usr/bin/nettop", ["-P", "-L", "1", "-t", "wifi", "-J", "bytes_in,bytes_out", "-x"], timeout: 20)
            self.ingestNettop(r.out)
            self.nettopBusy = false
        }
    }

    private func ingestNettop(_ out: String) {
        let now = Date()
        let dt = max(now.timeIntervalSince(lastNettop), 1)
        lastNettop = now
        let primed = !prevProc.isEmpty
        var seen: [String: (Double, Double)] = [:]
        var byApp: [String: (Double, Double)] = [:]

        for line in out.split(separator: "\n").dropFirst() {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 3, let bi = Double(f[1]), let bo = Double(f[2]) else { continue }
            let procKey = String(f[0])
            seen[procKey] = (bi, bo)
            guard primed else { continue }
            let prev = prevProc[procKey] ?? (0, 0)
            let di = bi >= prev.0 ? bi - prev.0 : bi
            let dOut = bo >= prev.1 ? bo - prev.1 : bo
            guard di > 0 || dOut > 0 else { continue }
            let app = Self.canonicalName(procKey)
            var e = byApp[app] ?? (0, 0)
            e.0 += di; e.1 += dOut
            byApp[app] = e
        }
        prevProc = seen
        guard primed else { return }

        let hour = Int(now.timeIntervalSince1970 / 3600) * 3600
        let ssid = currentKey
        for (app, v) in byApp {
            let key = "\(hour)|\(ssid)|\(app)"
            var e = pendingApps[key] ?? (hour, ssid, app, 0, 0)
            e.bin += v.0; e.bout += v.1
            pendingApps[key] = e
        }
        if Demo.on { talkers = Demo.talkers(); return }
        talkers = byApp.map { TalkerRate(name: $0.key, down: $0.value.0 / dt, up: $0.value.1 / dt) }
            .sorted { $0.total > $1.total }
            .prefix(8).map { $0 }
    }

    private static func canonicalName(_ procKey: String) -> String {
        var name = procKey
        var pid: Int32?
        if let dot = procKey.lastIndex(of: "."), let p = Int32(procKey[procKey.index(after: dot)...]) {
            pid = p
            name = String(procKey[..<dot])
        }
        if let pid, let app = NSRunningApplication(processIdentifier: pid), let url = app.bundleURL {
            let comps = url.pathComponents
            if let idx = comps.firstIndex(where: { $0.hasSuffix(".app") }) {
                return String(comps[idx].dropLast(4))
            }
        }
        if name.hasPrefix("com.apple.WebKi") { return "Safari / WebKit" }
        if name.hasPrefix("com.apple.") { name = String(name.dropFirst(10)) }
        if let r = name.range(of: " Helper") { name = String(name[..<r.lowerBound]) }
        return name
    }

    // MARK: Persistence

    func flush() {
        let t = Array(pendingTotals.values)
        let a = Array(pendingApps.values)
        pendingTotals.removeAll()
        pendingApps.removeAll()
        let db = usage
        Task.detached {
            db.addTotals(t)
            db.addApps(a)
            await MainActor.run { self.dataVersion += 1 }
        }
    }
}
