import Foundation
import IOKit
import SwiftUI

struct SSDInfo {
    var model = "—"
    var serial = "—"
    var revision = "—"
    var capacity: Int64 = 0
    var smartStatus = "Unknown"
    var trim = false
    var bsd = "disk0"
    var isSolidState = true

    // Only available when `smartctl` can read the drive
    var percentUsed: Int?
    var availableSpare: Int?
    var bytesWritten: Double?
    var bytesRead: Double?
    var powerOnHours: Int?
    var powerCycles: Int?
    var unsafeShutdowns: Int?
    var mediaErrors: Int?
    var temperature: Int?
    var smartctlPath: String?
    var smartctlNote: String?

    var smartOK: Bool { smartStatus.lowercased().contains("verified") || smartStatus.lowercased().contains("passed") }
}

struct HealthFactor: Identifiable {
    enum Level { case good, warn, bad, info
        var color: Color { switch self { case .good: return Theme.green; case .warn: return Theme.yellow; case .bad: return Theme.red; case .info: return Theme.blue } }
        var icon: String { switch self { case .good: return "checkmark.seal.fill"; case .warn: return "exclamationmark.triangle.fill"; case .bad: return "xmark.octagon.fill"; case .info: return "info.circle.fill" } }
    }
    let id = UUID()
    let title: String
    let detail: String
    let level: Level
}

struct IOPoint: Identifiable {
    let id = UUID()
    let t: Date
    let read: Double
    let write: Double
}

struct BenchResult {
    var writeMBps = 0.0
    var readMBps = 0.0
}

@MainActor
final class SSDMonitor: ObservableObject {
    @Published var info = SSDInfo()
    @Published var loaded = false
    @Published var readSpeed = 0.0
    @Published var writeSpeed = 0.0
    @Published var ioHistory: [IOPoint] = []
    @Published var bootRead: Double = 0
    @Published var bootWrite: Double = 0
    @Published var uptime: TimeInterval = 0
    @Published var benchmarking = false
    @Published var bench: BenchResult?
    @Published var benchPhase = ""

    private var prev: (UInt64, UInt64)?
    private var prevT = Date()
    private var timer: Timer?

    init() {
        Task { await load() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    // MARK: Live I/O

    private func tick() {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 {
            uptime = Date().timeIntervalSince1970 - Double(tv.tv_sec)
        }
        guard let cur = Self.readDiskStats() else { return }
        bootRead = Double(cur.0); bootWrite = Double(cur.1)
        let now = Date()
        defer { prev = cur; prevT = now }
        guard let p = prev else { return }
        let dt = max(now.timeIntervalSince(prevT), 0.5)
        readSpeed = Double(cur.0 &- p.0) / dt
        writeSpeed = Double(cur.1 &- p.1) / dt
        ioHistory.append(IOPoint(t: now, read: readSpeed, write: writeSpeed))
        if ioHistory.count > 90 { ioHistory.removeFirst(ioHistory.count - 90) }
    }

    nonisolated static func readDiskStats() -> (UInt64, UInt64)? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        var internalSum: (UInt64, UInt64) = (0, 0)
        var foundInternal = false
        var largest: (UInt64, UInt64) = (0, 0)

        var svc = IOIteratorNext(iter)
        while svc != 0 {
            var propsRef: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(svc, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = propsRef?.takeRetainedValue() as? [String: Any],
               let stats = dict["Statistics"] as? [String: Any] {
                let r = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                let w = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
                if r > largest.0 { largest = (r, w) }
                if isInternalNVMe(svc) {
                    foundInternal = true
                    internalSum.0 &+= r; internalSum.1 &+= w
                }
            }
            IOObjectRelease(svc)
            svc = IOIteratorNext(iter)
        }
        return foundInternal ? internalSum : largest
    }

    nonisolated private static func isInternalNVMe(_ entry: io_registry_entry_t) -> Bool {
        var current = entry
        IOObjectRetain(current)
        for _ in 0..<8 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { IOObjectRelease(current); return false }
            IOObjectRelease(current)
            current = parent
            if let cls = IOObjectCopyClass(current)?.takeRetainedValue() as String? {
                if cls.contains("ANS") || cls.contains("NVMe") { IOObjectRelease(current); return true }
                if cls.contains("DiskImage") || cls.contains("HDIX") { IOObjectRelease(current); return false }
            }
        }
        IOObjectRelease(current)
        return false
    }

    // MARK: Static info

    func load() async {
        var i = SSDInfo()

        let sp = await Shell.run("/usr/sbin/system_profiler", ["SPNVMeDataType", "-json"], timeout: 60)
        if let data = sp.out.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ctrls = root["SPNVMeDataType"] as? [[String: Any]] {
            for c in ctrls {
                for item in (c["_items"] as? [[String: Any]]) ?? [] {
                    i.model = (item["device_model"] as? String) ?? (item["_name"] as? String) ?? i.model
                    i.serial = (item["device_serial"] as? String) ?? i.serial
                    i.revision = (item["device_revision"] as? String) ?? i.revision
                    i.capacity = (item["size_in_bytes"] as? Int64) ?? Int64((item["size_in_bytes"] as? Int) ?? 0)
                    i.smartStatus = (item["smart_status"] as? String) ?? i.smartStatus
                    i.trim = ((item["spnvme_trim_support"] as? String) ?? "").lowercased() == "yes"
                    i.bsd = (item["bsd_name"] as? String) ?? i.bsd
                }
            }
        }
        if i.smartStatus == "Unknown" {
            let du = await Shell.run("/usr/sbin/diskutil", ["info", "/"])
            if let l = du.out.split(separator: "\n").first(where: { $0.contains("SMART Status") }) {
                i.smartStatus = l.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "Unknown"
            }
        }

        // Optional deep SMART data through smartmontools
        let candidates = ["/opt/homebrew/bin/smartctl", "/usr/local/bin/smartctl", "/usr/sbin/smartctl"]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            i.smartctlPath = path
            let r = await Shell.run(path, ["-a", "-j", "/dev/" + i.bsd], timeout: 30)
            if let data = r.out.data(using: .utf8),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let log = root["nvme_smart_health_information_log"] as? [String: Any] {
                i.percentUsed = log["percentage_used"] as? Int
                i.availableSpare = log["available_spare"] as? Int
                if let u = (log["data_units_written"] as? NSNumber)?.doubleValue { i.bytesWritten = u * 512_000 }
                if let u = (log["data_units_read"] as? NSNumber)?.doubleValue { i.bytesRead = u * 512_000 }
                i.powerOnHours = log["power_on_hours"] as? Int
                i.powerCycles = log["power_cycles"] as? Int
                i.unsafeShutdowns = log["unsafe_shutdowns"] as? Int
                i.mediaErrors = log["media_errors"] as? Int
                i.temperature = log["temperature"] as? Int
            } else {
                i.smartctlNote = "smartctl is installed but could not read the Apple SSD without administrator rights. Run `sudo smartctl -a /dev/\(i.bsd)` in Terminal to see the wear counters."
            }
        } else {
            i.smartctlNote = "Apple does not expose wear counters (percentage used, TB written) to normal apps. Install smartmontools — `brew install smartmontools` — and DataLens will show them."
        }
        info = i
        loaded = true
    }

    // MARK: Health scoring

    func score(volume: VolumeInfo) -> (score: Int, factors: [HealthFactor]) {
        var s = 100
        var f: [HealthFactor] = []

        if info.smartOK {
            f.append(HealthFactor(title: "S.M.A.R.T. status: Verified", detail: "macOS's built-in self-monitoring reports no predicted failure.", level: .good))
        } else {
            s -= 60
            f.append(HealthFactor(title: "S.M.A.R.T. status: \(info.smartStatus)", detail: "Back up now and have the drive checked.", level: .bad))
        }

        let freeFrac = volume.total > 0 ? Double(volume.importantFree) / Double(volume.total) : 1
        if freeFrac < 0.05 {
            s -= 25
            f.append(HealthFactor(title: "Only \(Fmt.percent(freeFrac)) free", detail: "Very little free space slows the SSD (less room for wear levelling) and can break updates. Aim for 15%+.", level: .bad))
        } else if freeFrac < 0.12 {
            s -= 12
            f.append(HealthFactor(title: "\(Fmt.percent(freeFrac)) free — getting tight", detail: "Keep at least 10–15% free for best SSD performance and longevity.", level: .warn))
        } else {
            f.append(HealthFactor(title: "\(Fmt.percent(freeFrac)) free space", detail: "Healthy headroom for the SSD to wear-level and for macOS updates.", level: .good))
        }

        if let used = info.percentUsed {
            s -= min(used / 2, 30)
            f.append(HealthFactor(title: "\(used)% of rated endurance used", detail: used < 50 ? "Plenty of write life left." : "Getting up there — keep backups current.", level: used < 50 ? .good : (used < 80 ? .warn : .bad)))
        }
        if let spare = info.availableSpare {
            f.append(HealthFactor(title: "\(spare)% spare blocks available", detail: "Reserve flash used to replace worn cells.", level: spare > 50 ? .good : .warn))
            if spare <= 50 { s -= 10 }
        }
        if let m = info.mediaErrors, m > 0 {
            s -= 20
            f.append(HealthFactor(title: "\(m) media errors logged", detail: "The controller has hit unrecoverable data errors.", level: .bad))
        }
        if let u = info.unsafeShutdowns {
            f.append(HealthFactor(title: "\(u) unsafe shutdowns", detail: "Power loss / force-quits while the drive was writing. A few is normal.", level: u > 200 ? .warn : .info))
        }
        if let t = info.temperature {
            f.append(HealthFactor(title: "Drive temperature \(t) °C", detail: t < 60 ? "Normal." : "Running hot — check airflow and heavy background tasks.", level: t < 60 ? .good : .warn))
        }
        if info.trim {
            f.append(HealthFactor(title: "TRIM enabled", detail: "macOS tells the SSD which blocks are free, keeping writes fast.", level: .good))
        }
        return (max(min(s, 100), 0), f)
    }

    // MARK: Benchmark

    func runBenchmark() {
        guard !benchmarking else { return }
        benchmarking = true
        bench = nil
        benchPhase = "Writing 1 GB…"
        Task.detached {
            let path = NSTemporaryDirectory() + "datalens-bench-\(UUID().uuidString).bin"
            let chunk = 8 * 1024 * 1024
            let count = 128 // 1 GiB
            var buffer = [UInt8](repeating: 0, count: chunk)
            for i in 0..<chunk { buffer[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
            var result = BenchResult()

            let fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
            if fd >= 0 {
                _ = fcntl(fd, F_NOCACHE, 1)
                let t0 = Date()
                for _ in 0..<count { _ = buffer.withUnsafeBytes { write(fd, $0.baseAddress, chunk) } }
                fsync(fd)
                close(fd)
                result.writeMBps = Double(chunk * count) / 1e6 / max(Date().timeIntervalSince(t0), 0.001)
            }
            await MainActor.run { self.benchPhase = "Reading it back…" }
            let rfd = open(path, O_RDONLY)
            if rfd >= 0 {
                _ = fcntl(rfd, F_NOCACHE, 1)
                let t0 = Date()
                while buffer.withUnsafeMutableBytes({ read(rfd, $0.baseAddress, chunk) }) > 0 {}
                close(rfd)
                result.readMBps = Double(chunk * count) / 1e6 / max(Date().timeIntervalSince(t0), 0.001)
            }
            try? FileManager.default.removeItem(atPath: path)
            let final = result
            await MainActor.run {
                self.bench = final
                self.benchmarking = false
                self.benchPhase = ""
            }
        }
    }
}
