import Foundation
import CoreGraphics

/// Geometry and automatic layout for maps. Pure functions, independent of the UI.
enum DiagramLayout {
    static let canvas = CGSize(width: 3200, height: 2200)
    static let grid: Double = 10

    static func size(of node: DiagramNode) -> CGSize {
        node.entryID == nil && node.kind == .note ? CGSize(width: 190, height: noteHeight(node.label)) : CGSize(width: 196, height: 62)
    }

    /// Sticky notes grow with their text (about 26 characters a line) so nothing is cut off.
    static func noteHeight(_ text: String) -> Double {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, Int((Double($1.count) / 26).rounded(.up))) }
        return min(400, max(110, 24 + Double(lines) * 17))
    }

    /// Everything on the map, for fitting it on screen. Nil when the map is empty.
    static func contentBounds(_ diagram: Diagram) -> CGRect? {
        let rects = diagram.nodes.map { rect(of: $0) } + diagram.groups.map { rect(of: $0) }
        return rects.isEmpty ? nil : rects.reduce(CGRect.null) { $0.union($1) }
    }

    static func rect(of node: DiagramNode, offset: CGSize = .zero) -> CGRect {
        let size = size(of: node)
        return CGRect(x: node.x + offset.width - size.width / 2, y: node.y + offset.height - size.height / 2, width: size.width, height: size.height)
    }

    static func snap(_ value: Double) -> Double { (value / grid).rounded() * grid }

    // MARK: Groups

    static let minimumGroupSize = CGSize(width: 240, height: 140)
    /// The title strip along the top of a group, which is what you drag.
    static let groupHeader: Double = 34

    static func rect(of group: DiagramGroup, offset: CGSize = .zero, grow: CGSize = .zero) -> CGRect {
        CGRect(x: group.x + offset.width, y: group.y + offset.height,
               width: max(minimumGroupSize.width, group.width + grow.width), height: max(minimumGroupSize.height, group.height + grow.height))
    }

    /// The boxes inside a group: those whose centre lies within its frame.
    static func members(of group: DiagramGroup, in diagram: Diagram) -> [UUID] {
        let frame = rect(of: group)
        return diagram.nodes.filter { frame.contains(CGPoint(x: $0.x, y: $0.y)) }.map(\.id)
    }

    /// A group framing the given boxes with some breathing room, or a default-sized group at `point` when there are none.
    static func group(around nodes: [DiagramNode], or point: CGPoint, title: String = "", color: String = "slate") -> DiagramGroup {
        guard !nodes.isEmpty else {
            let size = CGSize(width: 420, height: 260)
            return DiagramGroup(title: title, color: color, x: snap(point.x - size.width / 2), y: snap(point.y - size.height / 2),
                                width: size.width, height: size.height)
        }
        let bounds = nodes.map { rect(of: $0) }.reduce(CGRect.null) { $0.union($1) }
        let pad = 30.0
        let width = max(minimumGroupSize.width, bounds.width + pad * 2), height = max(minimumGroupSize.height, bounds.height + pad * 2 + groupHeader)
        return DiagramGroup(title: title, color: color, x: snap(bounds.midX - width / 2), y: snap(bounds.minY - pad - groupHeader),
                            width: snap(width), height: snap(height))
    }

    /// Keeps a group's frame on the canvas.
    static func clamp(_ group: DiagramGroup) -> DiagramGroup {
        var result = group
        result.width = min(max(minimumGroupSize.width, snap(group.width)), canvas.width - 20)
        result.height = min(max(minimumGroupSize.height, snap(group.height)), canvas.height - 20)
        result.x = snap(min(max(10, group.x), canvas.width - result.width - 10))
        result.y = snap(min(max(10, group.y), canvas.height - result.height - 10))
        return result
    }

    static func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(110, point.x), canvas.width - 110), y: min(max(50, point.y), canvas.height - 70))
    }

    /// Keeps a whole box on the canvas, tall sticky notes included: `point` is where its centre should go.
    static func clamp(_ point: CGPoint, for node: DiagramNode) -> CGPoint {
        let size = size(of: node), margin = 12.0
        return CGPoint(x: min(max(size.width / 2 + margin, point.x), canvas.width - size.width / 2 - margin),
                       y: min(max(size.height / 2 + margin, point.y), canvas.height - size.height / 2 - margin))
    }

    // MARK: Connections

    enum Side: Equatable {
        case top, right, bottom, left
        var isHorizontal: Bool { self == .left || self == .right }
        /// Pointing out of the box.
        var normal: CGVector {
            switch self {
            case .top: return CGVector(dx: 0, dy: -1)
            case .bottom: return CGVector(dx: 0, dy: 1)
            case .left: return CGVector(dx: -1, dy: 0)
            case .right: return CGVector(dx: 1, dy: 0)
            }
        }
    }

    /// A connection's drawn shape. `points` are the corners of an elbow or straight line,
    /// or the start, two control points, and end of a curve.
    struct Route: Equatable {
        var points: [CGPoint]
        var style: LineStyle
        var startSide: Side
        var endSide: Side
        var start: CGPoint { points[0] }
        var end: CGPoint { points[points.count - 1] }
        /// Where a label sits: halfway along the line.
        var labelPoint: CGPoint
        /// The direction the arrowhead points, into the target box.
        var arrow: CGVector
    }

    /// Which sides two boxes connect on. Boxes side by side join left-to-right; stacked boxes join top-to-bottom;
    /// diagonal boxes leave sideways and enter the target from above or below (or the reverse when they're far apart sideways).
    static func sides(from a: CGRect, to b: CGRect) -> (Side, Side) {
        let clearance = 24.0
        let hGap = max(b.minX - a.maxX, a.minX - b.maxX)
        let vGap = max(b.minY - a.maxY, a.minY - b.maxY)
        let horizontal: (Side, Side) = b.midX >= a.midX ? (.right, .left) : (.left, .right)
        let vertical: (Side, Side) = b.midY >= a.midY ? (.bottom, .top) : (.top, .bottom)
        switch (hGap >= clearance, vGap >= clearance) {
        case (true, false): return horizontal
        case (false, true): return vertical
        case (true, true): return vGap >= hGap ? (horizontal.0, vertical.1) : (vertical.0, horizontal.1)
        case (false, false): return abs(b.midX - a.midX) >= abs(b.midY - a.midY) ? horizontal : vertical
        }
    }

    /// The sides to connect on, trying the other ways of joining the two boxes when the usual one
    /// would run through another box (or back through one of the two).
    static func sides(from a: CGRect, to b: CGRect, style: LineStyle, avoiding others: [CGRect]) -> (Side, Side) {
        let preferred = sides(from: a, to: b)
        let horizontal: (Side, Side) = b.midX >= a.midX ? (.right, .left) : (.left, .right)
        let vertical: (Side, Side) = b.midY >= a.midY ? (.bottom, .top) : (.top, .bottom)
        let obstacles = others + [a.insetBy(dx: 1, dy: 1), b.insetBy(dx: 1, dy: 1)]
        func clear(_ pair: (Side, Side)) -> Bool {
            let line = polyline(route(from: a, pair.0, to: b, pair.1, style: style))
            return !zip(line, line.dropFirst()).contains { p, q in obstacles.contains { segment(p, q, crosses: $0) } }
        }
        if clear(preferred) { return preferred }
        return [(horizontal.0, vertical.1), (vertical.0, horizontal.1), horizontal, vertical].first(where: clear) ?? preferred
    }

    /// A route as straight segments: its corners, or a curve sampled finely enough to test against boxes.
    static func polyline(_ route: Route) -> [CGPoint] {
        guard route.style == .curved else { return route.points }
        let p = route.points
        return (0...16).map { step in
            let t = Double(step) / 16, u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return CGPoint(x: a * p[0].x + b * p[1].x + c * p[2].x + d * p[3].x, y: a * p[0].y + b * p[1].y + c * p[2].y + d * p[3].y)
        }
    }

    /// Whether the segment from p to q passes through the rectangle (Liang–Barsky clipping).
    static func segment(_ p: CGPoint, _ q: CGPoint, crosses r: CGRect) -> Bool {
        let dx = q.x - p.x, dy = q.y - p.y
        var enter = 0.0, exit = 1.0
        for (direction, distance) in [(-dx, p.x - r.minX), (dx, r.maxX - p.x), (-dy, p.y - r.minY), (dy, r.maxY - p.y)] {
            if direction == 0 {
                if distance < 0 { return false }
            } else {
                let t = distance / direction
                if direction < 0 { enter = max(enter, t) } else { exit = min(exit, t) }
                if enter > exit { return false }
            }
        }
        return true
    }

    /// A point on a side, `offset` points from its middle.
    static func port(_ rect: CGRect, _ side: Side, offset: Double = 0) -> CGPoint {
        switch side {
        case .top: return CGPoint(x: rect.midX + offset, y: rect.minY)
        case .bottom: return CGPoint(x: rect.midX + offset, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY + offset)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY + offset)
        }
    }

    static func route(from a: CGRect, _ startSide: Side, offset startOffset: Double = 0,
                      to b: CGRect, _ endSide: Side, offset endOffset: Double = 0, style: LineStyle) -> Route {
        let start = port(a, startSide, offset: startOffset), end = port(b, endSide, offset: endOffset)
        let inward = CGVector(dx: -endSide.normal.dx, dy: -endSide.normal.dy)
        switch style {
        case .straight:
            let length = max(hypot(end.x - start.x, end.y - start.y), 0.001)
            return Route(points: [start, end], style: style, startSide: startSide, endSide: endSide,
                         labelPoint: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2),
                         arrow: CGVector(dx: (end.x - start.x) / length, dy: (end.y - start.y) / length))
        case .curved:
            let reach = max(36, hypot(end.x - start.x, end.y - start.y) * 0.4)
            let c1 = CGPoint(x: start.x + startSide.normal.dx * reach, y: start.y + startSide.normal.dy * reach)
            let c2 = CGPoint(x: end.x + endSide.normal.dx * reach, y: end.y + endSide.normal.dy * reach)
            let mid = CGPoint(x: (start.x + 3 * c1.x + 3 * c2.x + end.x) / 8, y: (start.y + 3 * c1.y + 3 * c2.y + end.y) / 8)
            return Route(points: [start, c1, c2, end], style: style, startSide: startSide, endSide: endSide, labelPoint: mid, arrow: inward)
        case .elbow:
            var points = [start]
            switch (startSide.isHorizontal, endSide.isHorizontal) {
            case (true, true):
                if abs(start.y - end.y) > 0.5 {
                    let x = (start.x + end.x) / 2
                    points += [CGPoint(x: x, y: start.y), CGPoint(x: x, y: end.y)]
                }
            case (false, false):
                if abs(start.x - end.x) > 0.5 {
                    let y = (start.y + end.y) / 2
                    points += [CGPoint(x: start.x, y: y), CGPoint(x: end.x, y: y)]
                }
            case (true, false): points.append(CGPoint(x: end.x, y: start.y))
            case (false, true): points.append(CGPoint(x: start.x, y: end.y))
            }
            points.append(end)
            return Route(points: points, style: style, startSide: startSide, endSide: endSide, labelPoint: halfway(points), arrow: inward)
        }
    }

    /// The point halfway along a polyline.
    static func halfway(_ points: [CGPoint]) -> CGPoint {
        let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        var remaining = lengths.reduce(0, +) / 2
        for (index, length) in lengths.enumerated() {
            if remaining <= length, length > 0 {
                let a = points[index], b = points[index + 1], t = remaining / length
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            remaining -= length
        }
        return points.last ?? .zero
    }

    /// Routes for every connection. Where several lines meet the same side of a box they're spread out along it,
    /// ordered to avoid crossing, instead of piling onto one point.
    static func routes(for diagram: Diagram, rects: [UUID: CGRect]) -> [UUID: Route] {
        struct End { let edge: UUID; let isStart: Bool; let node: UUID; let side: Side; let other: CGPoint }
        var sides: [UUID: (Side, Side)] = [:]
        var ends: [End] = []
        for edge in diagram.edges where edge.from != edge.to {
            guard let a = rects[edge.from], let b = rects[edge.to] else { continue }
            let others = rects.filter { $0.key != edge.from && $0.key != edge.to }.map(\.value)
            let pair = Self.sides(from: a, to: b, style: diagram.lineStyle, avoiding: others)
            sides[edge.id] = pair
            ends.append(End(edge: edge.id, isStart: true, node: edge.from, side: pair.0, other: CGPoint(x: b.midX, y: b.midY)))
            ends.append(End(edge: edge.id, isStart: false, node: edge.to, side: pair.1, other: CGPoint(x: a.midX, y: a.midY)))
        }
        var offsets: [String: Double] = [:]
        for group in Dictionary(grouping: ends, by: { "\($0.node)-\($0.side)" }).values where group.count > 1 {
            guard let rect = rects[group[0].node] else { continue }
            let horizontalSide = !group[0].side.isHorizontal
            let length = horizontalSide ? rect.width : rect.height
            let spacing = min(26, (length - 28) / Double(group.count - 1))
            let sorted = group.sorted { horizontalSide ? $0.other.x < $1.other.x : $0.other.y < $1.other.y }
            for (index, end) in sorted.enumerated() {
                offsets["\(end.edge)-\(end.isStart)"] = (Double(index) - Double(group.count - 1) / 2) * spacing
            }
        }
        var result: [UUID: Route] = [:]
        for edge in diagram.edges {
            guard let pair = sides[edge.id], let a = rects[edge.from], let b = rects[edge.to] else { continue }
            result[edge.id] = route(from: a, pair.0, offset: offsets["\(edge.id)-true"] ?? 0,
                                    to: b, pair.1, offset: offsets["\(edge.id)-false"] ?? 0, style: diagram.lineStyle)
        }
        return result
    }

    // MARK: Snapping

    /// Where a dragged box should land: lined up with another box's centre when it's within a few points of it
    /// (returning the guides to draw), otherwise on the grid.
    static func snap(_ point: CGPoint, for id: UUID, among others: [DiagramNode], threshold: Double = 7) -> (point: CGPoint, guideX: Double?, guideY: Double?) {
        var x = snap(point.x), y = snap(point.y)
        var guideX: Double?, guideY: Double?
        if let match = others.filter({ $0.id != id }).map(\.x).min(by: { abs($0 - point.x) < abs($1 - point.x) }), abs(match - point.x) <= threshold {
            x = match; guideX = match
        }
        if let match = others.filter({ $0.id != id }).map(\.y).min(by: { abs($0 - point.y) < abs($1 - point.y) }), abs(match - point.y) <= threshold {
            y = match; guideY = match
        }
        return (CGPoint(x: x, y: y), guideX, guideY)
    }

    /// Arranges nodes in columns that follow the arrows, left to right. Unconnected nodes go in a row underneath.
    static func tidy(_ diagram: Diagram) -> Diagram {
        var result = diagram
        let ids = diagram.nodes.map(\.id)
        guard !ids.isEmpty else { return result }
        var outgoing: [UUID: [UUID]] = [:], incoming: [UUID: [UUID]] = [:]
        for edge in diagram.edges where edge.from != edge.to {
            outgoing[edge.from, default: []].append(edge.to)
            incoming[edge.to, default: []].append(edge.from)
        }
        let connected = ids.filter { outgoing[$0] != nil || incoming[$0] != nil }
        let loose = ids.filter { outgoing[$0] == nil && incoming[$0] == nil }

        // Longest-path layering; edges that would close a cycle are ignored.
        var layer: [UUID: Int] = [:]
        var visiting = Set<UUID>()
        func depth(_ id: UUID) -> Int {
            if let known = layer[id] { return known }
            if visiting.contains(id) { return 0 }
            visiting.insert(id)
            let value = (incoming[id] ?? []).filter { !visiting.contains($0) || layer[$0] != nil }.map { depth($0) + 1 }.max() ?? 0
            visiting.remove(id)
            layer[id] = value
            return value
        }
        for id in connected { _ = depth(id) }

        let layerCount = (layer.values.max() ?? -1) + 1
        var columns: [[UUID]] = Array(repeating: [], count: max(layerCount, 0))
        for id in connected { columns[layer[id] ?? 0].append(id) }

        // Order each column by the average row of the nodes pointing at it, so arrows cross less.
        var row: [UUID: Double] = [:]
        for (index, id) in (columns.first ?? []).enumerated() { row[id] = Double(index) }
        for c in columns.indices.dropFirst() {
            columns[c].sort { a, b in
                let ka = (incoming[a] ?? []).compactMap { row[$0] }, kb = (incoming[b] ?? []).compactMap { row[$0] }
                let ma = ka.isEmpty ? .infinity : ka.reduce(0, +) / Double(ka.count), mb = kb.isEmpty ? .infinity : kb.reduce(0, +) / Double(kb.count)
                return ma < mb
            }
            for (index, id) in columns[c].enumerated() { row[id] = Double(index) }
        }

        let columnGap = 280.0, rowGap = 92.0, left = 190.0, top = 110.0
        let tallest = Double(columns.map(\.count).max() ?? 0)
        var position: [UUID: CGPoint] = [:]
        for (c, column) in columns.enumerated() {
            let offset = (tallest - Double(column.count)) * rowGap / 2
            for (r, id) in column.enumerated() { position[id] = CGPoint(x: left + Double(c) * columnGap, y: top + offset + Double(r) * rowGap) }
        }
        let looseTop = top + (columns.isEmpty ? 0 : tallest * rowGap + 50)
        let perRow = 5
        for (index, id) in loose.enumerated() {
            let size = diagram.nodes.first { $0.id == id }.map(size(of:)) ?? CGSize(width: 196, height: 62)
            position[id] = CGPoint(x: left + Double(index % perRow) * 226, y: looseTop + Double(index / perRow) * (Double(size.height) + 40))
        }
        for index in result.nodes.indices {
            if let p = position[result.nodes[index].id] { result.nodes[index].x = snap(p.x); result.nodes[index].y = snap(p.y) }
        }
        return result
    }

    /// A ready-made map: the project in the middle, its links grouped by type around it.
    static func fromLinks(project: Project, entries: [Entry], title: String = "Overview") -> Diagram {
        var diagram = Diagram(projectID: project.id, title: title)
        let hub = DiagramNode(label: project.name, x: 0, y: 0, kind: .app, color: project.color)
        diagram.nodes.append(hub)
        for kind in EntryKind.linkKinds {
            let group = entries.filter { $0.projectID == project.id && $0.kind == kind }.sorted { $0.title.lowercased() < $1.title.lowercased() }
            guard !group.isEmpty else { continue }
            let header = DiagramNode(label: kind.groupName, x: 0, y: 0, kind: nodeKind(for: kind))
            diagram.nodes.append(header)
            diagram.edges.append(DiagramEdge(from: hub.id, to: header.id))
            for entry in group {
                let node = DiagramNode(label: entry.title, entryID: entry.id, x: 0, y: 0)
                diagram.nodes.append(node)
                diagram.edges.append(DiagramEdge(from: header.id, to: node.id))
            }
        }
        return tidy(diagram)
    }

    static func nodeKind(for kind: EntryKind) -> NodeKind {
        switch kind {
        case .service: return .api
        case .social: return .person
        case .repository: return .storage
        case .link: return .app
        case .document: return .step
        case .conversation: return .cloud
        default: return .step
        }
    }

    /// A free position for a new node near `point`, stepping away until it doesn't sit on top of another node.
    static func freeSpot(near point: CGPoint, in diagram: Diagram) -> CGPoint {
        var candidate = clamp(point)
        var attempt = 0
        while attempt < 40, diagram.nodes.contains(where: { abs($0.x - candidate.x) < 150 && abs($0.y - candidate.y) < 60 }) {
            attempt += 1
            candidate = clamp(CGPoint(x: point.x + Double(attempt % 4) * 40, y: point.y + Double(attempt) * 30))
        }
        return CGPoint(x: snap(candidate.x), y: snap(candidate.y))
    }
}
