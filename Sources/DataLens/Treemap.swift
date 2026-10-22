import SwiftUI
import AppKit

enum Squarify {
    /// Lays out values (must be sorted descending) inside `rect`. Returns one rect per value.
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var out: [CGRect] = []
        var rem = rect
        var i = 0

        func worst(_ row: [Double], _ side: Double) -> Double {
            let s = row.reduce(0, +)
            guard s > 0, let mx = row.max(), let mn = row.min(), mn > 0 else { return .infinity }
            return max(side * side * mx / (s * s), s * s / (side * side * mn))
        }

        while i < areas.count {
            let side = Double(min(rem.width, rem.height))
            var row: [Double] = []
            while i < areas.count {
                let cand = row + [areas[i]]
                if row.isEmpty || worst(cand, side) <= worst(row, side) { row = cand; i += 1 } else { break }
            }
            let s = row.reduce(0, +)
            if rem.width >= rem.height {
                let colW = CGFloat(s) / rem.height
                var y = rem.minY
                for a in row {
                    let h = CGFloat(a) / colW
                    out.append(CGRect(x: rem.minX, y: y, width: colW, height: h))
                    y += h
                }
                rem = CGRect(x: rem.minX + colW, y: rem.minY, width: max(rem.width - colW, 0), height: rem.height)
            } else {
                let rowH = CGFloat(s) / rem.width
                var x = rem.minX
                for a in row {
                    let w = CGFloat(a) / rowH
                    out.append(CGRect(x: x, y: rem.minY, width: w, height: rowH))
                    x += w
                }
                rem = CGRect(x: rem.minX, y: rem.minY + rowH, width: rem.width, height: max(rem.height - rowH, 0))
            }
        }
        return out
    }
}

struct TreemapView: View {
    let entries: [FolderEntry]
    var onOpen: (FolderEntry) -> Void

    private func makeItems() -> [(String, String, Int64, Bool, FolderEntry?)] {
        var items: [(String, String, Int64, Bool, FolderEntry?)] = entries.prefix(28).map { ($0.path, $0.name, $0.bytes, $0.isDir, $0) }
        let rest = entries.dropFirst(28)
        let restBytes = rest.reduce(Int64(0)) { $0 + $1.bytes }
        if restBytes > 0 { items.append(("__rest", "\(rest.count) smaller items", restBytes, false, nil)) }
        return items
    }

    var body: some View {
        GeometryReader { geo in
            let items = makeItems()
            let rects = Squarify.layout(items.map { Double(max($0.2, 1)) }, in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.enumerated()), id: \.element.0) { idx, item in
                    if idx < rects.count {
                        let r = rects[idx].insetBy(dx: 1.5, dy: 1.5)
                        TreemapCell(name: item.1, bytes: item.2, isDir: item.3, color: item.0 == "__rest" ? .gray : Theme.color(at: idx), size: r.size)
                            .frame(width: max(r.width, 0), height: max(r.height, 0))
                            .position(x: r.midX, y: r.midY)
                            .onTapGesture { if let e = item.4, e.isDir { onOpen(e) } }
                            .contextMenu {
                                if let e = item.4 {
                                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: e.path)]) }
                                    Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(e.path, forType: .string) }
                                }
                            }
                            .transition(.scale(scale: 0.92).combined(with: .opacity))
                    }
                }
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.85), value: entries.map(\.path))
        }
    }
}

struct TreemapCell: View {
    let name: String
    let bytes: Int64
    let isDir: Bool
    let color: Color
    let size: CGSize
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: [color.opacity(hover ? 0.95 : 0.75), color.opacity(hover ? 0.7 : 0.4)], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(hover ? 0.6 : 0.18), lineWidth: 1)
            if size.width > 64 && size.height > 34 {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Image(systemName: isDir ? "folder.fill" : "doc.fill").font(.system(size: 9))
                        Text(name).lineLimit(size.height > 70 ? 2 : 1)
                    }
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    Text(Fmt.bytes(Double(bytes))).font(.system(size: 10, design: .rounded)).opacity(0.85)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 2)
                .padding(7)
            }
        }
        .scaleEffect(hover ? 1.015 : 1)
        .animation(.easeOut(duration: 0.15), value: hover)
        .onHover { hover = $0 }
        .help("\(name) — \(Fmt.bytes(Double(bytes)))" + (isDir ? " (click to open)" : ""))
    }
}
