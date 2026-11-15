import SwiftUI
import UniformTypeIdentifiers

/// The formats form one continuous frosted band around the open notch (left side, under the card, right side), split into
/// segments like the radial menu in the reference. The band is one drop target that follows the dragged file: the segment
/// under it lights up and swells, and its neighbours swell a little, like the Dock.
struct ConversionPetalRing: View {
    static let bandWidth: CGFloat = 38
    /// Clearance between the card and the band
    static let cardGap: CGFloat = 12
    /// Where the hit area (and the hover zone) of the ring ends: under the 175 pt card, the band and room to swell
    static let bottom: CGFloat = 175 + cardGap + bandWidth + 34
    private static let segmentGap: CGFloat = 5
    
    let targets: [ConversionTarget]
    let files: [URL]
    let size: CGSize
    let cardSize: CGSize
    @State private var cursor: CGPoint?
    
    /// Center line of the band, following the card outline with rounded corners: down the left side, along the bottom, up the
    /// right side. It starts below the menu bar: dragging to the very top edge of the screen opens Mission Control.
    private var track: BandTrack {
        let cx = size.width / 2
        let half = Self.bandWidth / 2
        let xl = cx - cardSize.width / 2 - Self.cardGap - half
        let xr = cx + cardSize.width / 2 + Self.cardGap + half
        let yBottom = cardSize.height + Self.cardGap + half
        let radius: CGFloat = 44
        var points = [CGPoint(x: xl, y: 56)]
        // Quarter-circle corners, sampled finely enough to look round
        for k in 0...10 {
            let a = Double.pi - Double.pi / 2 * Double(k) / 10
            points.append(CGPoint(x: xl + radius + radius * CGFloat(cos(a)), y: yBottom - radius + radius * CGFloat(sin(a))))
        }
        for k in 0...10 {
            let a = Double.pi / 2 - Double.pi / 2 * Double(k) / 10
            points.append(CGPoint(x: xr - radius + radius * CGFloat(cos(a)), y: yBottom - radius + radius * CGFloat(sin(a))))
        }
        points.append(CGPoint(x: xr, y: 56))
        // points[1...11] are the left corner, points[12...22] the right one
        return BandTrack(points: points, corners: [
            (1...11, CGPoint(x: xl + radius, y: yBottom - radius), radius, .pi, .pi / 2),
            (12...22, CGPoint(x: xr - radius, y: yBottom - radius), radius, .pi / 2, 0)
        ])
    }
    
    private var bounds: [CGFloat] { track.boundaries(count: targets.count) }
    
    /// Segment under the cursor (the band is "hit" within a generous margin around its center line)
    private func index(at location: CGPoint) -> Int? {
        guard !targets.isEmpty else { return nil }
        let hit = track.project(location)
        guard hit.distance < Self.bandWidth / 2 + 22 else { return nil }
        let b = bounds
        return (0..<targets.count).last(where: { b[$0] <= hit.along }) ?? 0
    }
    
    var body: some View {
        let track = self.track
        let b = bounds
        let hit = cursor.map { track.project($0) }
        let active = cursor.flatMap { index(at: $0) }
        let center = CGPoint(x: size.width / 2, y: cardSize.height * 0.45)
        ZStack(alignment: .topLeading) {
            ForEach(Array(targets.enumerated()), id: \.element.id) { i, target in
                let seg = b[i + 1] - b[i]
                let mid = (b[i] + b[i + 1]) / 2
                // Dock-style swell: 1 under the cursor, falling off over about one segment
                let g: CGFloat = hit.map { h in
                    guard h.distance < Self.bandWidth / 2 + 44 else { return 0 }
                    let d = (h.along - mid) / (seg * 0.85)
                    return exp(-d * d)
                } ?? 0
                let isActive = active == i
                let m = track.point(at: mid)
                // Pushed away from the card as it swells
                let dx = m.x - center.x, dy = m.y - center.y
                let norm = max(hypot(dx, dy), 1)
                
                Group {
                SegmentShape(track: track,
                             from: b[i] + Self.segmentGap / 2 - 14 * g,
                             to: b[i + 1] - Self.segmentGap / 2 + 14 * g,
                             thickness: Self.bandWidth + 30 * g,
                             isActive: isActive)
                    .offset(x: dx / norm * 9 * g, y: dy / norm * 9 * g)
                    .zIndex(Double(g))
                
                Text(target.title)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundColor(isActive ? .black : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    // corner tiles are curved: their straight width is well under their length along the band
                    .frame(width: min(seg * 0.7, Self.bandWidth + 26))
                    .scaleEffect(1 + 0.45 * g)
                    .position(x: m.x + dx / norm * 9 * g, y: m.y + dy / norm * 9 * g)
                    .zIndex(Double(g) + 1)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.7), value: cursor)
        // The card itself is left out of the ring's hit area: dropping on it saves to the clipboard
        .contentShape(RingHitShape(hole: CGRect(x: (size.width - cardSize.width) / 2 - 6, y: 0, width: cardSize.width + 12, height: cardSize.height + 6)), eoFill: true)
        .onDrop(of: [.fileURL], delegate: PetalDropDelegate(cursor: $cursor, files: files, targets: targets, indexAt: index(at:)))
    }
}

/// One frosted section of the band with rounded corners: the center line is stroked thinner, then grown by the corner radius.
private struct SegmentShape: View {
    let track: BandTrack
    let from: CGFloat
    let to: CGFloat
    let thickness: CGFloat
    let isActive: Bool
    private let radius: CGFloat = 9
    
    /// Core of the shape (before it is grown by the corner radius): the ribbon over the stretch, shortened and thinned by the
    /// radius; the rounded stroke below grows it back to full size with rounded corners.
    private var core: Path {
        track.ribbon(from: from + radius, to: to - radius, thickness: max(thickness - 2 * radius, 1))
    }
    
    var body: some View {
        let core = self.core
        let round = StrokeStyle(lineWidth: 2 * radius, lineJoin: .round)
        // translucent tile: drawn opaque, then faded as one layer so stroke and fill don't double up
        ZStack { core.stroke(style: round); core.fill() }
            .foregroundColor(isActive ? .white : Color(white: 0.1))
            .compositingGroup()
            .opacity(isActive ? 0.92 : 0.55)
            // Light glow around the segment being hovered
            .shadow(color: Color.white.opacity(isActive ? 0.6 : 0), radius: isActive ? 12 : 0)
    }
}

/// A polyline with distance helpers: where a distance along it lies, the stretch between two distances, and the nearest point to a location.
private struct BandTrack {
    let points: [CGPoint]
    let lengths: [CGFloat]
    let total: CGFloat
    /// The two rounded corners: where they lie along the track, and their exact circle
    struct Corner {
        let range: ClosedRange<CGFloat>
        let center: CGPoint
        let radius: CGFloat
        let startAngle: CGFloat
        let endAngle: CGFloat
    }
    let corners: [Corner]
    
    init(points: [CGPoint], corners specs: [(indexes: ClosedRange<Int>, center: CGPoint, radius: CGFloat, start: CGFloat, end: CGFloat)] = []) {
        let lens = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        self.points = points
        lengths = lens
        total = lens.reduce(0, +)
        corners = specs.map {
            Corner(range: lens.prefix($0.indexes.lowerBound).reduce(0, +)...lens.prefix($0.indexes.upperBound).reduce(0, +),
                   center: $0.center, radius: $0.radius, startAngle: $0.start, endAngle: $0.end)
        }
    }
    
    /// The corner a stretch of the track lies in, if it is exactly one corner's span
    func corner(from: CGFloat, to: CGFloat) -> Corner? {
        corners.first { $0.range.lowerBound - 12 <= from && to <= $0.range.upperBound + 12 }
    }
    
    /// Segment boundaries. Each rounded corner is one segment of its own, with an equal straight stub before and after the arc,
    /// so its two ends are both flat and mirror each other. The rest of the track is split evenly into the straight pieces.
    func boundaries(count: Int) -> [CGFloat] {
        guard corners.count == 2, count >= 2 else {
            return (0...max(count, 1)).map { total * CGFloat($0) / CGFloat(max(count, 1)) }
        }
        let stub: CGFloat = 16
        let c1 = corners[0].range.lowerBound - stub, c1End = corners[0].range.upperBound + stub
        let c2 = corners[1].range.lowerBound - stub, c2End = corners[1].range.upperBound + stub
        let perSide = count >= 8 ? 1 : 0                 // straight pieces on each vertical side
        let bottom = count - 2 - 2 * perSide             // straight pieces along the bottom
        func even(_ from: CGFloat, _ to: CGFloat, _ n: Int) -> [CGFloat] {
            n > 0 ? (1...n).map { from + (to - from) * CGFloat($0) / CGFloat(n) } : []
        }
        // Without straight side pieces the band simply starts at the first corner, so the corner segment stays symmetric
        var edges: [CGFloat] = perSide > 0 ? [0] + even(0, c1, perSide) : [c1]
        edges.append(c1End)
        if bottom > 0 { edges += even(c1End, c2, bottom) } else { edges.append(c2) }
        edges.append(c2End)
        if perSide > 0 { edges += even(c2End, total, perSide) }
        // keep exactly count + 1 edges, strictly increasing
        var cleaned: [CGFloat] = []
        for e in edges where cleaned.last.map({ e > $0 + 0.5 }) ?? true { cleaned.append(e) }
        // Never let a layout surprise crash the overlay: fall back to equal parts
        return cleaned.count == count + 1 ? cleaned : (0...count).map { total * CGFloat($0) / CGFloat(count) }
    }
    
    func point(at distance: CGFloat) -> CGPoint {
        var d = max(0, min(distance, total))
        for (k, len) in lengths.enumerated() {
            if d <= len || k == lengths.count - 1 {
                let t = len == 0 ? 0 : min(d / len, 1)
                return CGPoint(x: points[k].x + (points[k + 1].x - points[k].x) * t, y: points[k].y + (points[k + 1].y - points[k].y) * t)
            }
            d -= len
        }
        return points[0]
    }
    
    /// Unit tangent of the track at a distance (averaged over a vertex, which keeps arcs smooth)
    func tangent(at distance: CGFloat) -> CGPoint {
        let d = max(0, min(distance, total))
        var cumulative: CGFloat = 0
        for (k, len) in lengths.enumerated() where len > 0 {
            if d <= cumulative + len || k == lengths.count - 1 {
                let f = (d - cumulative) / len
                func dir(_ i: Int) -> CGPoint {
                    let l = max(lengths[i], 0.0001)
                    return CGPoint(x: (points[i + 1].x - points[i].x) / l, y: (points[i + 1].y - points[i].y) / l)
                }
                // Blend with the neighbouring chord so the normal turns smoothly around corners
                let here = dir(k)
                let other = f < 0.5 ? (k > 0 ? dir(k - 1) : here) : (k < lengths.count - 1 ? dir(k + 1) : here)
                let w: CGFloat = abs(f - 0.5)   // 0 at chord middle .. 0.5 at its ends
                let mix = CGPoint(x: here.x * (1 - w) + other.x * w, y: here.y * (1 - w) + other.y * w)
                let m = max(hypot(mix.x, mix.y), 0.0001)
                return CGPoint(x: mix.x / m, y: mix.y / m)
            }
            cumulative += len
        }
        return CGPoint(x: 0, y: 1)
    }
    
    /// A band of the given thickness over a stretch of the track. Both ends are cut exactly along the normal there:
    /// square on a straight run, radial on a corner, so neighbouring pieces mirror each other.
    func ribbon(from start: CGFloat, to end: CGFloat, thickness: CGFloat) -> Path {
        guard end > start else { return Path() }
        var stops: [CGFloat] = [start]
        var cumulative: CGFloat = 0
        for len in lengths {
            cumulative += len
            if cumulative > start + 0.5 && cumulative < end - 0.5 { stops.append(cumulative) }
        }
        stops.append(end)
        // Extra samples keep long straight stretches and arcs well resolved
        var dense: [CGFloat] = []
        for (a, b) in zip(stops, stops.dropFirst()) {
            let steps = max(Int((b - a) / 3), 1)
            for k in 0..<steps { dense.append(a + (b - a) * CGFloat(k) / CGFloat(steps)) }
        }
        dense.append(end)
        let half = thickness / 2
        var outer: [CGPoint] = [], inner: [CGPoint] = []
        for d in dense {
            let p = point(at: d), t = tangent(at: d)
            let n = CGPoint(x: -t.y, y: t.x)
            outer.append(CGPoint(x: p.x + n.x * half, y: p.y + n.y * half))
            inner.append(CGPoint(x: p.x - n.x * half, y: p.y - n.y * half))
        }
        var path = Path()
        path.move(to: outer[0])
        outer.dropFirst().forEach { path.addLine(to: $0) }
        inner.reversed().forEach { path.addLine(to: $0) }
        path.closeSubpath()
        return path
    }
    
    func subpath(from start: CGFloat, to end: CGFloat) -> Path {
        var path = Path()
        path.move(to: point(at: start))
        var cumulative: CGFloat = 0
        for (k, len) in lengths.enumerated() {
            cumulative += len
            if cumulative > start && cumulative < end { path.addLine(to: points[k + 1]) }
        }
        path.addLine(to: point(at: end))
        return path
    }
    
    /// Nearest point on the polyline: how far along it, and how far away
    func project(_ p: CGPoint) -> (along: CGFloat, distance: CGFloat) {
        var best: (along: CGFloat, distance: CGFloat) = (0, .greatestFiniteMagnitude)
        var cumulative: CGFloat = 0
        for (k, len) in lengths.enumerated() {
            let a = points[k], b = points[k + 1]
            let t = len == 0 ? 0 : max(0, min(1, ((p.x - a.x) * (b.x - a.x) + (p.y - a.y) * (b.y - a.y)) / (len * len)))
            let q = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            let dist = hypot(p.x - q.x, p.y - q.y)
            if dist < best.distance { best = (cumulative + t * len, dist) }
            cumulative += len
        }
        return best
    }
}

private struct RingHitShape: Shape {
    let hole: CGRect
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addRect(rect)
        p.addRect(hole)
        return p
    }
}

private struct PetalDropDelegate: DropDelegate {
    @Binding var cursor: CGPoint?
    let files: [URL]
    let targets: [ConversionTarget]
    let indexAt: (CGPoint) -> Int?
    
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }
    func dropEntered(info: DropInfo) { cursor = info.location }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        cursor = info.location
        return DropProposal(operation: .copy)
    }
    func dropExited(info: DropInfo) { cursor = nil }
    func performDrop(info: DropInfo) -> Bool {
        defer { cursor = nil }
        guard let index = indexAt(info.location) else { return false }
        let target = targets[index]
        // The drop gives the real file URLs; fall back to what the drag pasteboard showed when it started
        loadFileURLs(from: info.itemProviders(for: [.fileURL])) { urls in
            ConversionCenter.shared.start(urls.isEmpty ? files : urls, target: target)
        }
        return true
    }
}

/// Inside the card while dragging: dropping here saves to the clipboard.
struct ConversionCenterZone: View {
    let centerTargeted: Bool
    let topInset: CGFloat
    @ObservedObject private var l10n = LocalizationService.shared
    
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: centerTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                .font(.system(size: 24, weight: .semibold))
            Text(tr("Отпустите, чтобы сохранить в буфер", "Drop to save to the clipboard"))
                .font(.system(size: 12, weight: .bold, design: .rounded))
            Text(tr("Форматы по бокам: конвертировать в Загрузки", "Formats on the sides: convert to Downloads"))
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.55))
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(centerTargeted ? 0.16 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(centerTargeted ? 0.7 : 0.25), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        )
        .padding(EdgeInsets(top: topInset, leading: 10, bottom: 10, trailing: 10))
        .background(Color.black)
        .allowsHitTesting(false) // the card-level drop saves to the clipboard
        .transition(.opacity)
    }
}

/// Reads file URLs out of drop providers.
func loadFileURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    var urls: [URL] = []
    let lock = NSLock()
    let group = DispatchGroup()
    for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else if let u = item as? URL { url = u }
            lock.lock(); if let url = url { urls.append(url) }; lock.unlock()
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(urls) }
}

/// Progress and result of a conversion; tapping the result reveals the file.
struct ConversionToast: View {
    @ObservedObject private var center = ConversionCenter.shared
    
    var body: some View {
        if let status = center.status {
            HStack(spacing: 7) {
                switch status {
                case .running(let title):
                    ProgressView().controlSize(.small).colorScheme(.dark)
                    Text(tr("Конвертация {0}", "Converting {0}", title))
                case .done(let name, let url):
                    Image(systemName: "checkmark.circle.fill").foregroundColor(Color(red: 0.2, green: 0.85, blue: 0.4))
                    Text(tr("{0} — в Загрузках", "{0} — in Downloads", name))
                    Button(action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }) {
                        Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
                    Text(message).lineLimit(1)
                }
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color(white: 0.16)))
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.6))
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
