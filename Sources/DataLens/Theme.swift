import SwiftUI
import AppKit

// MARK: - Palette

enum Theme {
    static let cyan = Color(red: 0.24, green: 0.84, blue: 1.00)
    static let blue = Color(red: 0.36, green: 0.52, blue: 1.00)
    static let purple = Color(red: 0.64, green: 0.42, blue: 1.00)
    static let pink = Color(red: 1.00, green: 0.42, blue: 0.72)
    static let orange = Color(red: 1.00, green: 0.62, blue: 0.28)
    static let yellow = Color(red: 1.00, green: 0.84, blue: 0.30)
    static let green = Color(red: 0.30, green: 0.90, blue: 0.58)
    static let red = Color(red: 1.00, green: 0.36, blue: 0.40)

    static let down = cyan
    static let up = pink

    static let bgTop = Color(red: 0.035, green: 0.04, blue: 0.09)
    static let bgBottom = Color(red: 0.06, green: 0.05, blue: 0.13)

    static let palette: [Color] = [cyan, purple, pink, orange, green, blue, yellow, red,
                                   Color(red: 0.45, green: 0.85, blue: 0.95),
                                   Color(red: 0.80, green: 0.55, blue: 1.0)]

    static func color(at index: Int) -> Color { palette[index % palette.count] }

    static let accent = LinearGradient(colors: [cyan, blue, purple], startPoint: .leading, endPoint: .trailing)
    static let hot = LinearGradient(colors: [orange, pink], startPoint: .leading, endPoint: .trailing)
}

// MARK: - Formatting

enum Fmt {
    static func bytes(_ v: Double, decimals: Int? = nil) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = abs(v)
        var i = 0
        while value >= 1000, i < units.count - 1 { value /= 1000; i += 1 }
        let d = decimals ?? (i == 0 ? 0 : (value >= 100 ? 0 : (value >= 10 ? 1 : 2)))
        return String(format: "%.\(d)f %@", value, units[i])
    }

    static func speed(_ v: Double) -> String { bytes(v) + "/s" }

    static func percent(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static let shortDate: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()
}

// MARK: - Animated counting number

struct CountingText: View, Animatable {
    var value: Double
    var format: (Double) -> String
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View { Text(format(value)) }
}

// MARK: - Backgrounds & cards

struct AuroraBackground: View {
    @State private var phase = false
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.bgTop, Theme.bgBottom], startPoint: .top, endPoint: .bottom)
            GeometryReader { geo in
                ZStack {
                    blob(Theme.blue, size: 520)
                        .offset(x: phase ? -geo.size.width * 0.25 : geo.size.width * 0.05,
                                y: phase ? -geo.size.height * 0.30 : -geo.size.height * 0.15)
                    blob(Theme.purple, size: 460)
                        .offset(x: phase ? geo.size.width * 0.35 : geo.size.width * 0.15,
                                y: phase ? geo.size.height * 0.25 : geo.size.height * 0.40)
                    blob(Theme.cyan, size: 380)
                        .offset(x: phase ? geo.size.width * 0.05 : -geo.size.width * 0.20,
                                y: phase ? geo.size.height * 0.45 : geo.size.height * 0.20)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .opacity(0.30)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 16).repeatForever(autoreverses: true)) { phase = true }
        }
    }

    private func blob(_ color: Color, size: CGFloat) -> some View {
        Circle().fill(RadialGradient(colors: [color, color.opacity(0)], center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
    }
}

struct Card: ViewModifier {
    var padding: CGFloat = 18
    var tint: Color? = nil
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.045))
                    if let tint {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(LinearGradient(colors: [tint.opacity(0.16), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.03)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            )
    }
}

extension View {
    func card(padding: CGFloat = 18, tint: Color? = nil) -> some View { modifier(Card(padding: padding, tint: tint)) }
}

struct HoverLift: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.012 : 1)
            .shadow(color: .black.opacity(hovering ? 0.35 : 0), radius: 18, y: 8)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverLift() -> some View { modifier(HoverLift()) }
}

// MARK: - Components

struct SectionTitle: View {
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold, design: .rounded))
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
        }
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String
    var icon: String
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accent).frame(width: 46, height: 46)
                Image(systemName: icon).font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
            }
            .shadow(color: Theme.blue.opacity(0.5), radius: 14, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 28, weight: .bold, design: .rounded))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct RingGauge<Center: View>: View {
    var progress: Double
    var colors: [Color]
    var lineWidth: CGFloat = 16
    @ViewBuilder var center: () -> Center
    @State private var shown = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.07), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: shown ? min(max(progress, 0.001), 1) : 0.001)
                .stroke(AngularGradient(colors: colors + [colors.first ?? .white], center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: (colors.first ?? .white).opacity(0.5), radius: 10)
            center()
        }
        .onAppear { withAnimation(.easeOut(duration: 1.2)) { shown = true } }
        .animation(.easeOut(duration: 0.8), value: progress)
    }
}

struct StatTile: View {
    let title: String
    let value: Double
    var format: (Double) -> String
    var icon: String
    var color: Color
    var footnote: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(color)
                    .frame(width: 26, height: 26)
                    .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
            }
            CountingText(value: value, format: format)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
                .animation(.easeOut(duration: 0.9), value: value)
            if let footnote {
                Text(footnote).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14, tint: color)
        .hoverLift()
    }
}

struct Pill: View {
    let text: String
    var color: Color = Theme.cyan
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct GlowButtonStyle: ButtonStyle {
    var color: Color = Theme.blue
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(color.opacity(configuration.isPressed ? 0.55 : 0.30)))
            .overlay(Capsule().strokeBorder(color.opacity(0.6), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct BannerView: View {
    let icon: String
    let title: String
    let message: String
    var color: Color = Theme.orange
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(GlowButtonStyle(color: color))
            }
        }
        .card(padding: 14, tint: color)
    }
}

/// Shimmering placeholder bar used while scans are running.
struct ShimmerBar: View {
    @State private var move = false
    var body: some View {
        RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06))
            .overlay(
                GeometryReader { g in
                    LinearGradient(colors: [.clear, .white.opacity(0.18), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.5)
                        .offset(x: move ? g.size.width : -g.size.width * 0.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            )
            .onAppear { withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { move = true } }
    }
}

// MARK: - App icons

@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(forAppNamed name: String) -> NSImage? {
        if let c = cache[name] { return c }
        let candidates = ["/Applications/\(name).app", "/System/Applications/\(name).app",
                          "/System/Applications/Utilities/\(name).app",
                          NSHomeDirectory() + "/Applications/\(name).app"]
        for p in candidates where FileManager.default.fileExists(atPath: p) {
            let img = NSWorkspace.shared.icon(forFile: p)
            cache[name] = img
            return img
        }
        return nil
    }

    static func icon(forPath path: String) -> NSImage {
        if let c = cache[path] { return c }
        let img = NSWorkspace.shared.icon(forFile: path)
        cache[path] = img
        return img
    }
}

struct AppIconView: View {
    let name: String
    var path: String? = nil
    var size: CGFloat = 28
    var body: some View {
        Group {
            if let path {
                Image(nsImage: IconCache.icon(forPath: path)).resizable()
            } else if let img = IconCache.icon(forAppNamed: name) {
                Image(nsImage: img).resizable()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                    Image(systemName: "gearshape.2.fill").font(.system(size: size * 0.45)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
    }
}
