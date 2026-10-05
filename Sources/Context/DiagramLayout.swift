import Foundation
import CoreGraphics

/// Geometry and automatic layout for maps. Pure functions, independent of the UI.
enum DiagramLayout {
    static let canvas = CGSize(width: 3200, height: 2200)
    static let grid: Double = 10

    static func size(of node: DiagramNode) -> CGSize {
        node.entryID == nil && node.kind == .note ? CGSize(width: 190, height: 110) : CGSize(width: 196, height: 62)
    }

    static func rect(of node: DiagramNode, offset: CGSize = .zero) -> CGRect {
        let size = size(of: node)
        return CGRect(x: node.x + offset.width - size.width / 2, y: node.y + offset.height - size.height / 2, width: size.width, height: size.height)
    }

    static func snap(_ value: Double) -> Double { (value / grid).rounded() * grid }

    static func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(110, point.x), canvas.width - 110), y: min(max(50, point.y), canvas.height - 70))
    }

    /// A smooth connector between two node rectangles: leaves and enters on the sides that face each other.
    static func connector(from a: CGRect, to b: CGRect) -> (start: CGPoint, c1: CGPoint, c2: CGPoint, end: CGPoint) {
        let dx = b.midX - a.midX, dy = b.midY - a.midY
        let gap: CGFloat = 5
        if abs(dx) >= abs(dy) * 0.9 {
            let right = dx >= 0
            let start = CGPoint(x: right ? a.maxX : a.minX, y: a.midY)
            let end = CGPoint(x: right ? b.minX - gap : b.maxX + gap, y: b.midY)
            let bend = max(36, abs(end.x - start.x) * 0.5) * (right ? 1 : -1)
            return (start, CGPoint(x: start.x + bend, y: start.y), CGPoint(x: end.x - bend, y: end.y), end)
        }
        let down = dy >= 0
        let start = CGPoint(x: a.midX, y: down ? a.maxY : a.minY)
        let end = CGPoint(x: b.midX, y: down ? b.minY - gap : b.maxY + gap)
        let bend = max(30, abs(end.y - start.y) * 0.5) * (down ? 1 : -1)
        return (start, CGPoint(x: start.x, y: start.y + bend), CGPoint(x: end.x, y: end.y - bend), end)
    }

    static func midpoint(_ c: (start: CGPoint, c1: CGPoint, c2: CGPoint, end: CGPoint)) -> CGPoint {
        // Cubic Bézier at t = 0.5.
        CGPoint(x: (c.start.x + 3 * c.c1.x + 3 * c.c2.x + c.end.x) / 8, y: (c.start.y + 3 * c.c1.y + 3 * c.c2.y + c.end.y) / 8)
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
