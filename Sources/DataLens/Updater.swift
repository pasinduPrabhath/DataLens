import Foundation
import SwiftUI
import AppKit

struct ReleaseInfo: Equatable {
    let version: String
    let notes: String
    let dmgURL: URL
    let pageURL: URL
}

/// Checks GitHub Releases for a newer version and can download + install it on request.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle, checking, upToDate, available, downloading, installing
        case failed(String)
    }

    static let repo = "pasinduPrabhath/DataLens"

    @Published var state: State = .idle
    @Published var latest: ReleaseInfo?
    @Published var lastChecked: Date?
    @Published var autoCheck: Bool = UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "autoCheckUpdates") }
    }

    var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    var updateAvailable: Bool { latest != nil && (state == .available || state == .downloading || state == .installing) }

    private var timer: Timer?

    init() {
        guard !Demo.on else { return }
        if autoCheck { Task { await check() } }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.autoCheck == true { Task { await self?.check() } } }
        }
    }

    // MARK: Check

    func check() async {
        if state == .downloading || state == .installing { return }
        state = .checking
        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("DataLens/\(current)", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 20
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { throw UpdateError.message("GitHub returned no release information.") }
            lastChecked = Date()
            let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            guard Self.isNewer(version, than: current) else { latest = nil; state = .upToDate; return }
            let assets = (json["assets"] as? [[String: Any]]) ?? []
            guard let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
                  let urlString = dmg["browser_download_url"] as? String, let url = URL(string: urlString), url.scheme == "https" else {
                throw UpdateError.message("Release \(version) has no installer attached.")
            }
            latest = ReleaseInfo(version: version, notes: (json["body"] as? String) ?? "", dmgURL: url,
                                 pageURL: URL(string: (json["html_url"] as? String) ?? "https://github.com/\(Self.repo)/releases")!)
            state = .available
            if ProcessInfo.processInfo.environment["DATALENS_UPDATE_TEST"] != nil { install() }   // developer aid
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    // MARK: Install

    func install() {
        guard let info = latest, state == .available || { if case .failed = state { return true }; return false }() else { return }
        let appPath = Bundle.main.bundlePath
        let parent = (appPath as NSString).deletingLastPathComponent
        guard appPath.hasSuffix(".app"), FileManager.default.isWritableFile(atPath: parent) else {
            state = .failed("DataLens can't replace itself here. Download the installer from the release page instead.")
            return
        }
        state = .downloading
        Task {
            do {
                let (tmp, resp) = try await URLSession.shared.download(from: info.dmgURL)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.message("Download failed.") }
                state = .installing
                let work = NSTemporaryDirectory() + "DataLens-update-\(UUID().uuidString)"
                try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
                let dmg = work + "/update.dmg"
                try FileManager.default.moveItem(at: tmp, to: URL(fileURLWithPath: dmg))

                // mount, copy the app out, unmount
                let attach = await Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-plist", dmg], timeout: 120)
                guard let mount = Self.mountPoint(fromPlist: attach.out) else { throw UpdateError.message("Could not open the downloaded installer.") }
                defer { _ = Shell.runSync("/usr/bin/hdiutil", ["detach", "-quiet", mount]) }
                let src = mount + "/DataLens.app"
                guard FileManager.default.fileExists(atPath: src) else { throw UpdateError.message("The installer does not contain DataLens.app.") }
                let staged = work + "/DataLens.app"
                let copy = await Shell.run("/usr/bin/ditto", [src, staged], timeout: 120)
                guard copy.status == 0 else { throw UpdateError.message("Could not copy the new version.") }

                // verify before replacing anything
                let verify = await Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged])
                guard verify.status == 0 else { throw UpdateError.message("The downloaded app failed its signature check.") }
                guard Bundle(path: staged)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                    throw UpdateError.message("The downloaded app is not DataLens.")
                }

                // swap after we quit, then relaunch
                let script = work + "/swap.sh"
                try """
                #!/bin/bash
                while kill -0 "$1" 2>/dev/null; do sleep 0.3; done
                if rm -rf "$3" && /usr/bin/ditto "$2" "$3"; then
                  xattr -dr com.apple.quarantine "$3" 2>/dev/null
                  open "$3"
                else
                  open -R "$2"
                fi
                """.write(toFile: script, atomically: true, encoding: .utf8)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = [script, String(ProcessInfo.processInfo.processIdentifier), staged, appPath]
                try p.run()
                NSApp.terminate(nil)
            } catch {
                state = .failed(Self.describe(error))
            }
        }
    }

    // MARK: Helpers

    private enum UpdateError: Error { case message(String) }

    private static func describe(_ e: Error) -> String {
        if case UpdateError.message(let m) = e { return m }
        return e.localizedDescription
    }

    private static func mountPoint(fromPlist s: String) -> String? {
        guard let data = s.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        return entities.compactMap { $0["mount-point"] as? String }.first
    }
}

// MARK: - UI

struct UpdateBanner: View {
    @EnvironmentObject var updater: Updater

    var body: some View {
        if let info = updater.latest, updater.updateAvailable {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.cyan)
                VStack(alignment: .leading, spacing: 3) {
                    Text("DataLens \(info.version) is available").font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text("You have \(updater.current). The update is downloaded, verified and installed when you press the button; the app restarts itself.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                switch updater.state {
                case .downloading: ProgressView().controlSize(.small); Text("Downloading…").font(.caption)
                case .installing: ProgressView().controlSize(.small); Text("Installing…").font(.caption)
                default:
                    Button("What's new") { NSWorkspace.shared.open(info.pageURL) }.buttonStyle(GlowButtonStyle(color: Theme.purple))
                    Button("Download & install") { updater.install() }.buttonStyle(GlowButtonStyle(color: Theme.blue))
                }
            }
            .card(padding: 14, tint: Theme.cyan)
        }
    }
}

struct UpdateSettingsCard: View {
    @EnvironmentObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Updates", subtitle: "Version \(updater.current)", icon: "arrow.triangle.2.circlepath")
            HStack {
                Button(updater.state == .checking ? "Checking…" : "Check for updates") { Task { await updater.check() } }
                    .buttonStyle(GlowButtonStyle()).disabled(updater.state == .checking)
                switch updater.state {
                case .upToDate: Pill(text: "You're up to date", color: Theme.green)
                case .failed(let m): Text(m).font(.caption).foregroundStyle(Theme.orange)
                case .available: Pill(text: "Version \(updater.latest?.version ?? "") available", color: Theme.cyan)
                default: EmptyView()
                }
                Spacer()
                if let d = updater.lastChecked { Text("checked \(d.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary) }
            }
            if updater.updateAvailable { UpdateBanner() }
            Toggle("Check for updates automatically", isOn: $updater.autoCheck).toggleStyle(.switch).font(.system(size: 12))
            Text("DataLens only contacts GitHub (api.github.com) to read the latest release. Nothing about you is sent.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
