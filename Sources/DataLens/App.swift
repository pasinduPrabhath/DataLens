import SwiftUI
import AppKit

@MainActor
final class AppEnv: ObservableObject {
    let usage = UsageDB()
    let monitor: NetworkMonitor
    let net: NetStore
    let storage: StorageStore
    let ssd = SSDMonitor()

    init() {
        monitor = NetworkMonitor(usage: usage)
        net = NetStore(monitor: monitor)
        storage = StorageStore(usage: usage)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Keep sampling in the menu bar after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first?.makeKeyAndOrderFront(nil) }
        return true
    }
}

@main
struct DataLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var env = AppEnv()

    var body: some Scene {
        WindowGroup("DataLens", id: "main") {
            RootView()
                .environmentObject(env.monitor)
                .environmentObject(env.net)
                .environmentObject(env.storage)
                .environmentObject(env.ssd)
                .frame(minWidth: 1180, minHeight: 760)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 860)

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(env.monitor)
                .environmentObject(env.net)
                .environmentObject(env.storage)
                .preferredColorScheme(.dark)
        } label: {
            MenuBarLabel().environmentObject(env.monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject var monitor: NetworkMonitor
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chart.bar.xaxis")
            Text("↓\(shortSpeed(monitor.downSpeed)) ↑\(shortSpeed(monitor.upSpeed))").monospacedDigit()
        }
    }

    private func shortSpeed(_ v: Double) -> String {
        if v >= 1e6 { return String(format: "%.1fM", v / 1e6) }
        if v >= 1e3 { return String(format: "%.0fK", v / 1e3) }
        return "0K"
    }
}

struct MenuBarPanel: View {
    @EnvironmentObject var monitor: NetworkMonitor
    @EnvironmentObject var net: NetStore
    @EnvironmentObject var storage: StorageStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "wifi").foregroundStyle(Theme.accent)
                Text(monitor.wifi.ssid ?? monitor.currentKey).font(.system(size: 14, weight: .bold, design: .rounded))
                Spacer()
                Pill(text: "\(monitor.wifi.rssi) dBm", color: monitor.wifi.quality > 0.5 ? Theme.green : Theme.orange)
            }
            HStack(spacing: 18) {
                VStack(alignment: .leading) {
                    Text("Download").font(.caption2).foregroundStyle(.secondary)
                    Text(Fmt.speed(monitor.downSpeed)).font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(Theme.cyan)
                }
                VStack(alignment: .leading) {
                    Text("Upload").font(.caption2).foregroundStyle(.secondary)
                    Text(Fmt.speed(monitor.upSpeed)).font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(Theme.pink)
                }
            }
            Divider()
            HStack {
                Text("This session").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("↓ \(Fmt.bytes(monitor.sessionDown))  ↑ \(Fmt.bytes(monitor.sessionUp))").font(.caption.monospacedDigit())
            }
            HStack {
                Text("Free disk space").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Fmt.bytes(Double(storage.volume.free))) of \(Fmt.bytes(Double(storage.volume.total)))").font(.caption.monospacedDigit())
            }
            Divider()
            HStack {
                Button("Open DataLens") {
                    NSApp.activate(ignoringOtherApps: true)
                    if let w = NSApp.windows.first(where: { $0.canBecomeMain }) { w.makeKeyAndOrderFront(nil) } else { openWindow(id: "main") }
                }
                .buttonStyle(GlowButtonStyle())
                Spacer()
                Button("Quit") { net.monitor.flush(); NSApp.terminate(nil) }.buttonStyle(GlowButtonStyle(color: Theme.red))
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}
