import SwiftUI

/// The project's map: boxes for people, apps, services, and saved links, joined by arrows. Links are managed here too.
struct DiagramSection: View {
    @EnvironmentObject var store: Store
    let project: Project
    @State private var selectedID: UUID?

    var diagrams: [Diagram] {
        store.workspace.diagrams.filter { $0.projectID == project.id }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        let current = diagrams.first { $0.id == selectedID } ?? diagrams.max { $0.updatedAt < $1.updatedAt }
        Group {
            if let current {
                DiagramEditor(diagram: current, others: diagrams, select: { selectedID = $0 }, create: create)
                    .id(current.id)
            } else {
                Color.clear
            }
        }
        // Every project has a map: it's where its links live too.
        .onAppear { if diagrams.isEmpty { create(fromLinks: false) } }
    }

    func create(fromLinks: Bool) {
        let title = diagrams.isEmpty ? "Overview" : "Map \(diagrams.count + 1)"
        let diagram = fromLinks ? DiagramLayout.fromLinks(project: project, entries: store.workspace.entries, title: title)
                                : Diagram(projectID: project.id, title: title)
        if store.upsert(diagram, in: \.diagrams) { selectedID = diagram.id }
    }
}

struct DiagramEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.present) var present
    @Environment(\.pageTint) var tint
    @Environment(\.undoManager) var undoManager
    @State var diagram: Diagram
    @State private var canUndo = false
    @State private var canRedo = false
    let others: [Diagram]
    let select: (UUID) -> Void
    let create: (_ fromLinks: Bool) -> Void
    /// A box to select when the map first appears (used by the snapshot script).
    var initialSelection: UUID? = nil
    /// Open the links panel when the map first appears (used by the snapshot script).
    var initiallyShowLinks = false

    @State private var selectedNodes: Set<UUID> = []
    @State private var selectedEdge: UUID?
    @State private var selectedGroup: UUID?
    @State private var editingNode: UUID?
    @State private var hoveredEdge: UUID?
    /// Boxes being dragged together, and how far.
    @State private var dragging: Set<UUID> = []
    @State private var dragOffset: CGSize = .zero
    @State private var guideX: Double?
    @State private var guideY: Double?
    /// A group being dragged, with the boxes that were inside it when the drag began.
    @State private var groupDrag: (id: UUID, offset: CGSize, members: [UUID])?
    @State private var groupResize: (id: UUID, grow: CGSize)?
    /// A connection being dragged out from a box's handle.
    @State private var linking: (from: UUID, to: CGPoint)?
    /// Dragging empty space pans; with Shift held it draws a selection rectangle.
    @State private var marquee: CGRect?
    @State private var backgroundPanning = false
    /// Where a double-click asked to add something.
    @State private var quickAdd: CGPoint = .zero
    @State private var showingQuickAdd = false
    @State private var showLinks = false
    /// A link being created in the editor sheet, to be placed on the map once it's saved.
    @State private var pendingPlacement: (id: UUID, at: CGPoint)?
    @StateObject private var viewport = MapViewport()
    @State private var keyMonitor: Any?
    @State private var confirmDelete = false
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var saveTask: Task<Void, Never>?

    /// The one selected box, when exactly one is selected.
    var selectedNode: UUID? {
        get { selectedNodes.count == 1 ? selectedNodes.first : nil }
        nonmutating set { selectedNodes = newValue.map { [$0] } ?? [] }
    }
    var hasSelection: Bool { !selectedNodes.isEmpty || selectedEdge != nil || selectedGroup != nil }

    var projectLinks: [Entry] {
        store.workspace.entries.filter { $0.projectID == diagram.projectID && EntryKind.linkKinds.contains($0.kind) }
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                MapScrollView(viewport: viewport, size: DiagramLayout.canvas, onReady: fitToContent) {
                    canvas
                        .frame(width: DiagramLayout.canvas.width, height: DiagramLayout.canvas.height, alignment: .topLeading)
                        .environmentObject(store)
                        .environment(\.pageTint, tint)
                        .environment(\.present, present)
                        .tint(tint)
                }
                .background(Theme.background)

                toolbar.padding(12)
                if diagram.nodes.isEmpty { emptyHint }
                Text(hint)
                    .font(T.caption).foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.card.opacity(0.92), in: Capsule()).overlay(Capsule().strokeBorder(Theme.border))
                    .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(false)
            }
            if hasSelection {
                Rectangle().fill(Theme.border).frame(width: 1)
                ScrollView { inspectorContent }
                    .frame(width: 300)
                    .background(Theme.card)
            } else if showLinks {
                Rectangle().fill(Theme.border).frame(width: 1)
                MapLinksPanel(projectID: diagram.projectID, onMap: Set(diagram.nodes.compactMap(\.entryID)),
                              place: { place($0) }, locate: { locate($0) }, newLink: { newLink(at: visibleCenter) }, close: { showLinks = false })
                    .frame(width: 300)
                    .background(Theme.card)
            }
        }
        .onAppear {
            if let initialSelection, selectedNodes.isEmpty { selectedNodes = [initialSelection] }
            if initiallyShowLinks { showLinks = true }
            installKeys()
        }
        .onDisappear(perform: removeKeys)
        .onChange(of: store.workspace.diagrams.first { $0.id == diagram.id }) { _, stored in
            if let stored, dragging.isEmpty, linking == nil, groupDrag == nil, groupResize == nil, stored != diagram {
                // Changed elsewhere, e.g. by Undo: show it, and drop anything selected that no longer exists.
                saveTask?.cancel()
                diagram = stored
                selectedNodes = selectedNodes.filter { id in stored.nodes.contains { $0.id == id } }
                if let id = editingNode, !stored.nodes.contains(where: { $0.id == id }) { editingNode = nil }
                if let id = selectedEdge, !stored.edges.contains(where: { $0.id == id }) { selectedEdge = nil }
                if let id = selectedGroup, !stored.groups.contains(where: { $0.id == id }) { selectedGroup = nil }
            }
        }
        .onChange(of: store.workspace.entries.map(\.id)) { _, ids in
            // A link made in the editor sheet lands where it was asked for.
            if let pending = pendingPlacement, ids.contains(pending.id), let entry = store.entry(pending.id) {
                pendingPlacement = nil
                addNode(entry: entry, at: pending.at)
            }
        }
        .onAppear(perform: refreshUndo)
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidCloseUndoGroup)) { _ in refreshUndo() }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { _ in refreshUndo() }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) { _ in refreshUndo() }
        .confirmationDialog("Delete the map “\(diagram.title)”?", isPresented: $confirmDelete) {
            Button("Delete Map", role: .destructive) { store.remove(diagram.id, in: \.diagrams) }
        } message: { Text("Your saved links are not affected.") }
        .alert("Rename map", isPresented: $renaming) {
            TextField("Name", text: $newTitle)
            Button("Rename") { let name = newTitle.trimmingCharacters(in: .whitespaces); if !name.isEmpty { diagram.title = name; save() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    var hint: String {
        if diagram.nodes.isEmpty { return "Double-click anywhere to add a box or a link" }
        if selectedNodes.count > 1 { return "\(selectedNodes.count) boxes selected · drag one to move them all · Delete removes them" }
        return "Double-click to add · drag empty space to move · Shift-drag to select several · drag a ● onto another box to connect"
    }

    var emptyHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 26, weight: .medium)).foregroundStyle(tint)
            Text("Map this project").font(T.h2).foregroundStyle(Theme.ink)
            Text("Double-click anywhere to add a box, or paste a link to add it with its logo.")
                .font(T.small).foregroundStyle(Theme.ink2).multilineTextAlignment(.center)
            if !projectLinks.isEmpty {
                HStack(spacing: 8) {
                    Button { buildFromLinks() } label: {
                        Label("Build from my \(projectLinks.count) links", systemImage: "wand.and.stars")
                    }.buttonStyle(.primaryCompact)
                    Button("Show Links") { showLinks = true }.buttonStyle(.softCompact)
                }
            }
        }
        .padding(24).frame(width: 380)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func buildFromLinks() {
        guard let project = store.project(diagram.projectID) else { return }
        diagram = DiagramLayout.fromLinks(project: project, entries: store.workspace.entries, title: diagram.title).with(id: diagram.id)
        save()
        DispatchQueue.main.async { fitToContent() }
    }

    // MARK: Canvas

    var canvas: some View {
        let rects = Dictionary(uniqueKeysWithValues: diagram.nodes.map { ($0.id, rect($0)) })
        let routes = DiagramLayout.routes(for: diagram, rects: rects)
        let hitPaths = routes.mapValues { path($0).cgPath.copy(strokingWithWidth: 12, lineCap: .round, lineJoin: .round, miterLimit: 1) }
        return ZStack(alignment: .topLeading) {
            DotGrid()
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { location in openQuickAdd(at: location) }
                .simultaneousGesture(TapGesture().onEnded { if !NSEvent.modifierFlags.contains(.shift) { clearSelection() } })
                .gesture(backgroundDrag)
            ForEach(diagram.groups) { group in groupView(group, part: .frame) }
            edgeLayer(routes, rects: rects)
            edgeHits(hitPaths)
            ForEach(diagram.groups) { group in groupView(group, part: .controls) }
            ForEach(diagram.edges.filter { !$0.label.isEmpty }) { edge in
                if let route = routes[edge.id] { edgeLabel(edge, at: route.labelPoint) }
            }
            guides(rects)
            ForEach(diagram.nodes) { node in nodeView(node) }
            if let marquee {
                Rectangle().fill(tint.opacity(0.08)).overlay(Rectangle().strokeBorder(tint.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .frame(width: marquee.width, height: marquee.height).position(x: marquee.midX, y: marquee.midY)
                    .allowsHitTesting(false)
            }
            // Always in place (only moved), because a popover can't open from a view that has only just appeared.
            Color.clear.frame(width: 1, height: 1).position(quickAdd).allowsHitTesting(false)
                .popover(isPresented: $showingQuickAdd, arrowEdge: .bottom) {
                    let point = quickAdd
                    QuickAddPanel(projectID: diagram.projectID, onMap: Set(diagram.nodes.compactMap(\.entryID)),
                                  addBox: { label, kind in showingQuickAdd = false; addNode(kind: kind, label: label, at: point) },
                                  addLink: { entry in showingQuickAdd = false; if store.save(entry) { addNode(entry: entry, at: point) } },
                                  place: { entry in showingQuickAdd = false; addNode(entry: entry, at: point) },
                                  locate: { entry in showingQuickAdd = false; locate(entry) },
                                  detailed: { showingQuickAdd = false; newLink(at: point) })
                        .environmentObject(store).environment(\.pageTint, tint)
                }
        }
        .coordinateSpace(name: "canvas")
    }

    var backgroundDrag: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if marquee == nil && !backgroundPanning {
                    if NSEvent.modifierFlags.contains(.shift) { marquee = .zero } else { backgroundPanning = true }
                }
                if marquee != nil {
                    marquee = CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
                                     width: abs(value.location.x - value.startLocation.x), height: abs(value.location.y - value.startLocation.y))
                } else {
                    viewport.pan(to: NSEvent.mouseLocation)
                }
            }
            .onEnded { _ in
                if let marquee {
                    let hit = diagram.nodes.filter { DiagramLayout.rect(of: $0).intersects(marquee) }.map(\.id)
                    selectedEdge = nil; selectedGroup = nil
                    selectedNodes.formUnion(hit)
                }
                marquee = nil
                if backgroundPanning { backgroundPanning = false; viewport.endPan() }
            }
    }

    @ViewBuilder func nodeView(_ node: DiagramNode) -> some View {
        let offset = offset(of: node.id)
        DiagramNodeView(node: node, info: info(node), selected: selectedNodes.contains(node.id), editing: editingNode == node.id,
                        linkTarget: linkTarget == node.id, linkSource: linking?.from == node.id,
                        label: Binding(get: { node.label }, set: { setLabel($0, for: node.id) }),
                        onSelect: { selectNode(node.id, extending: NSEvent.modifierFlags.contains(.shift)) },
                        onOpen: { open(node) },
                        onCommit: { editingNode = nil; save() },
                        onDrag: { drag(node, by: $0) },
                        onDragEnd: { _ in finishDrag() },
                        onLink: { linking = (node.id, $0) },
                        onLinkEnd: { finishLink(from: node.id, at: $0) })
            .equatable()
            .position(x: node.x + offset.width, y: node.y + offset.height)
            .contextMenu { nodeMenu(node) }
    }

    /// How far a box is currently being dragged, on its own or as part of a group.
    func offset(of id: UUID) -> CGSize {
        if dragging.contains(id) { return dragOffset }
        if let groupDrag, groupDrag.members.contains(id) { return groupDrag.offset }
        return .zero
    }

    func rect(_ node: DiagramNode) -> CGRect { DiagramLayout.rect(of: node, offset: offset(of: node.id)) }

    /// The box under a connection being dragged out.
    var linkTarget: UUID? {
        guard let linking else { return nil }
        return diagram.nodes.last { $0.id != linking.from && DiagramLayout.rect(of: $0).insetBy(dx: -8, dy: -8).contains(linking.to) }?.id
    }

    func clearSelection() {
        if editingNode != nil { editingNode = nil; save() }
        selectedNodes = []; selectedEdge = nil; selectedGroup = nil
    }

    /// Selects a box. With Shift, adds it to (or removes it from) the selection.
    func selectNode(_ id: UUID, extending: Bool = false) {
        // Selecting another box finishes renaming the previous one.
        if let editing = editingNode, editing != id { editingNode = nil; save() }
        selectedEdge = nil; selectedGroup = nil
        if extending {
            if selectedNodes.contains(id) { selectedNodes.remove(id) } else { selectedNodes.insert(id) }
        } else if !selectedNodes.contains(id) || selectedNodes.count == 1 {
            selectedNodes = [id]
        }
    }
    func selectGroup(_ id: UUID) { selectedGroup = id; selectedNodes = []; selectedEdge = nil; editingNode = nil }
    func selectEdge(_ id: UUID) { selectedEdge = id; selectedNodes = []; selectedGroup = nil; if editingNode != nil { editingNode = nil; save() } }

    // MARK: Dragging

    func drag(_ node: DiagramNode, by translation: CGSize) {
        if dragging.isEmpty {
            if !selectedNodes.contains(node.id) { selectNode(node.id, extending: false) }
            dragging = selectedNodes.isEmpty ? [node.id] : selectedNodes
        }
        // The box being dragged lines up with the others (or the grid); everything selected moves with it.
        let target = CGPoint(x: node.x + translation.width, y: node.y + translation.height)
        let snapped = DiagramLayout.snap(target, for: node.id, among: diagram.nodes.filter { !dragging.contains($0.id) })
        dragOffset = CGSize(width: snapped.point.x - node.x, height: snapped.point.y - node.y)
        if guideX != snapped.guideX { guideX = snapped.guideX }
        if guideY != snapped.guideY { guideY = snapped.guideY }
    }

    func finishDrag() {
        let moved = dragging, offset = dragOffset
        dragging = []; dragOffset = .zero; guideX = nil; guideY = nil
        guard offset != .zero else { return }
        for index in diagram.nodes.indices where moved.contains(diagram.nodes[index].id) {
            let point = DiagramLayout.clamp(CGPoint(x: diagram.nodes[index].x + offset.width, y: diagram.nodes[index].y + offset.height))
            diagram.nodes[index].x = point.x; diagram.nodes[index].y = point.y
        }
        save()
    }

    /// Lines showing what a dragged box has lined up with.
    @ViewBuilder func guides(_ rects: [UUID: CGRect]) -> some View {
        if guideX != nil || guideY != nil {
            let moving = dragging.compactMap { rects[$0] }.reduce(CGRect.null) { $0.union($1) }
            Canvas { context, _ in
                let style = StrokeStyle(lineWidth: 1, dash: [5, 4])
                if let x = guideX {
                    let aligned = diagram.nodes.filter { !dragging.contains($0.id) && $0.x == x }.compactMap { rects[$0.id] }
                    let span = aligned.reduce(moving) { $0.union($1) }
                    var line = Path(); line.move(to: CGPoint(x: x, y: span.minY - 16)); line.addLine(to: CGPoint(x: x, y: span.maxY + 16))
                    context.stroke(line, with: .color(tint.opacity(0.8)), style: style)
                }
                if let y = guideY {
                    let aligned = diagram.nodes.filter { !dragging.contains($0.id) && $0.y == y }.compactMap { rects[$0.id] }
                    let span = aligned.reduce(moving) { $0.union($1) }
                    var line = Path(); line.move(to: CGPoint(x: span.minX - 16, y: y)); line.addLine(to: CGPoint(x: span.maxX + 16, y: y))
                    context.stroke(line, with: .color(tint.opacity(0.8)), style: style)
                }
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: Groups

    @ViewBuilder func groupView(_ group: DiagramGroup, part: DiagramGroupView.Part) -> some View {
        let offset = groupDrag?.id == group.id ? groupDrag!.offset : .zero
        let grow = groupResize?.id == group.id ? groupResize!.grow : .zero
        DiagramGroupView(group: group, part: part, frame: DiagramLayout.rect(of: group, offset: offset, grow: grow),
                         count: groupDrag?.id == group.id ? groupDrag!.members.count : DiagramLayout.members(of: group, in: diagram).count,
                         selected: selectedGroup == group.id,
                         onSelect: { selectGroup(group.id) },
                         onDrag: { translation in
                             let members = groupDrag?.id == group.id ? groupDrag!.members : DiagramLayout.members(of: group, in: diagram)
                             if groupDrag?.id != group.id { selectGroup(group.id) }
                             groupDrag = (group.id, CGSize(width: DiagramLayout.snap(translation.width), height: DiagramLayout.snap(translation.height)), members)
                         },
                         onDragEnd: { _ in finishGroupDrag(group.id, groupDrag?.offset ?? .zero) },
                         onResize: { groupResize = (group.id, $0) },
                         onResizeEnd: { finishGroupResize(group.id, $0) })
            .contextMenu {
                Button("Rename") { selectGroup(group.id) }
                Button("Fit to Its Boxes") { fitGroup(group.id) }
                Divider()
                Button("Delete Group, Keep Boxes") { deleteGroup(group.id, withBoxes: false) }
                Button("Delete Group and Its Boxes", role: .destructive) { deleteGroup(group.id, withBoxes: true) }
            }
    }

    func addGroup(around nodes: [DiagramNode] = [], at point: CGPoint) {
        let colors = ["slate", "blue", "purple", "teal", "gold", "rose", "orange", "sage"]
        let color = colors[diagram.groups.count % colors.count]
        let group = DiagramLayout.clamp(DiagramLayout.group(around: nodes, or: point, color: color))
        diagram.groups.append(group)
        selectGroup(group.id)
        save()
    }

    func finishGroupDrag(_ id: UUID, _ translation: CGSize) {
        let members = groupDrag?.members ?? []
        groupDrag = nil
        guard let index = diagram.groups.firstIndex(where: { $0.id == id }) else { return }
        var moved = diagram.groups[index]
        moved.x += translation.width; moved.y += translation.height
        moved = DiagramLayout.clamp(moved)
        // Move the boxes by however far the group actually moved, so they stay inside it.
        let dx = moved.x - diagram.groups[index].x, dy = moved.y - diagram.groups[index].y
        diagram.groups[index] = moved
        for i in diagram.nodes.indices where members.contains(diagram.nodes[i].id) {
            let point = DiagramLayout.clamp(CGPoint(x: diagram.nodes[i].x + dx, y: diagram.nodes[i].y + dy))
            diagram.nodes[i].x = point.x; diagram.nodes[i].y = point.y
        }
        save()
    }

    func finishGroupResize(_ id: UUID, _ grow: CGSize) {
        groupResize = nil
        guard let index = diagram.groups.firstIndex(where: { $0.id == id }) else { return }
        diagram.groups[index].width += grow.width; diagram.groups[index].height += grow.height
        diagram.groups[index] = DiagramLayout.clamp(diagram.groups[index])
        save()
    }

    func fitGroup(_ id: UUID) {
        guard let index = diagram.groups.firstIndex(where: { $0.id == id }) else { return }
        let old = diagram.groups[index]
        let members = Set(DiagramLayout.members(of: old, in: diagram))
        guard !members.isEmpty else { return }
        var fitted = DiagramLayout.group(around: diagram.nodes.filter { members.contains($0.id) }, or: .zero)
        fitted.id = old.id; fitted.title = old.title; fitted.color = old.color
        diagram.groups[index] = DiagramLayout.clamp(fitted)
        save()
    }

    func deleteGroup(_ id: UUID, withBoxes: Bool) {
        guard let group = diagram.groups.first(where: { $0.id == id }) else { return }
        if withBoxes {
            let members = Set(DiagramLayout.members(of: group, in: diagram))
            diagram.edges.removeAll { members.contains($0.from) || members.contains($0.to) }
            diagram.nodes.removeAll { members.contains($0.id) }
        }
        diagram.groups.removeAll { $0.id == id }
        if selectedGroup == id { selectedGroup = nil }
        save()
    }

    struct NodeInfo: Equatable { let title: String; let subtitle: String; let missing: Bool; let entry: Entry? }

    func info(_ node: DiagramNode) -> NodeInfo {
        guard let id = node.entryID else { return NodeInfo(title: node.label, subtitle: node.kind.name, missing: false, entry: nil) }
        if let entry = store.entry(id) {
            return NodeInfo(title: entry.title, subtitle: BrandCatalog.host(of: entry.url) ?? entry.kind.shortName, missing: false, entry: entry)
        }
        return NodeInfo(title: node.label.isEmpty ? "Removed link" : node.label, subtitle: "This link was deleted", missing: true, entry: nil)
    }

    // MARK: Connections

    /// A route as a path, with rounded elbows, stopping short of the arrowhead's tip.
    func path(_ route: DiagramLayout.Route) -> Path {
        var points = route.points
        let end = route.end
        points[points.count - 1] = CGPoint(x: end.x - route.arrow.dx * 6, y: end.y - route.arrow.dy * 6)
        var path = Path()
        path.move(to: points[0])
        switch route.style {
        case .straight: path.addLine(to: points[1])
        case .curved: path.addCurve(to: points[3], control1: points[1], control2: points[2])
        case .elbow:
            for index in 1..<max(1, points.count - 1) {
                let previous = points[index - 1], corner = points[index], next = points[index + 1]
                let radius = min(12, hypot(corner.x - previous.x, corner.y - previous.y) / 2, hypot(next.x - corner.x, next.y - corner.y) / 2)
                if radius > 0.5 { path.addArc(tangent1End: corner, tangent2End: next, radius: radius) } else { path.addLine(to: corner) }
            }
            path.addLine(to: points[points.count - 1])
        }
        return path
    }

    func edgeLayer(_ routes: [UUID: DiagramLayout.Route], rects: [UUID: CGRect]) -> some View {
        Canvas { context, _ in
            for edge in diagram.edges {
                guard let route = routes[edge.id] else { continue }
                let color = selectedEdge == edge.id ? tint : (hoveredEdge == edge.id ? Theme.ink2 : Theme.ink3)
                draw(route, color: color, bold: selectedEdge == edge.id || hoveredEdge == edge.id, dashed: edge.dashed, in: &context)
            }
            if let linking, let source = rects[linking.from] {
                let target = linkTarget.flatMap { rects[$0] } ?? CGRect(x: linking.to.x - 1, y: linking.to.y - 1, width: 2, height: 2)
                let sides = DiagramLayout.sides(from: source, to: target)
                draw(DiagramLayout.route(from: source, sides.0, to: target, sides.1, style: diagram.lineStyle), color: tint, bold: true, dashed: true, in: &context)
            }
        }
        .allowsHitTesting(false)
    }

    func draw(_ route: DiagramLayout.Route, color: Color, bold: Bool, dashed: Bool, in context: inout GraphicsContext) {
        context.stroke(path(route), with: .color(color),
                       style: StrokeStyle(lineWidth: bold ? 2.4 : 1.7, lineCap: .round, lineJoin: .round, dash: dashed ? [6, 5] : []))
        let tip = route.end, angle = atan2(route.arrow.dy, route.arrow.dx)
        var arrow = Path()
        arrow.move(to: tip)
        arrow.addLine(to: CGPoint(x: tip.x - 10 * cos(angle - 0.42), y: tip.y - 10 * sin(angle - 0.42)))
        arrow.addLine(to: CGPoint(x: tip.x - 10 * cos(angle + 0.42), y: tip.y - 10 * sin(angle + 0.42)))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(color))
    }

    /// Lines are clickable along their whole length, and highlight under the pointer.
    func edgeHits(_ hitPaths: [UUID: CGPath]) -> some View {
        var region = Path()
        for path in hitPaths.values { region.addPath(Path(path)) }
        func edge(at point: CGPoint) -> UUID? { diagram.edges.last { hitPaths[$0.id]?.contains(point) == true }?.id }
        return Color.clear
            .contentShape(region)
            .onTapGesture { location in if let id = edge(at: location) { selectEdge(id) } }
            .onContinuousHover { phase in
                let id: UUID? = if case .active(let point) = phase { edge(at: point) } else { nil }
                if id != hoveredEdge { hoveredEdge = id }
            }
            .contextMenu {
                if let id = hoveredEdge ?? selectedEdge, let edge = diagram.edges.first(where: { $0.id == id }) { edgeMenu(edge) }
            }
    }

    func edgeLabel(_ edge: DiagramEdge, at point: CGPoint) -> some View {
        let selected = selectedEdge == edge.id
        return Button { selectEdge(edge.id) } label: {
            Text(edge.label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(selected ? tint : Theme.ink2)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.background, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? tint : Theme.border))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .position(point)
        .contextMenu { edgeMenu(edge) }
    }

    @ViewBuilder func edgeMenu(_ edge: DiagramEdge) -> some View {
        Button("Edit Label…") { selectEdge(edge.id) }
        Button("Reverse Direction") { mutateEdge(edge.id) { let from = $0.from; $0.from = $0.to; $0.to = from } }
        Button(edge.dashed ? "Solid Line" : "Dashed Line") { mutateEdge(edge.id) { $0.dashed.toggle() } }
        Divider()
        Button("Delete Connection", role: .destructive) { diagram.edges.removeAll { $0.id == edge.id }; selectedEdge = nil; save() }
    }

    // MARK: Toolbar

    var toolbar: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(others) { other in
                    Button { select(other.id) } label: { Label(other.title, systemImage: other.id == diagram.id ? "checkmark" : "map") }
                }
                Divider()
                Picker("Lines", selection: Binding(get: { diagram.lineStyle }, set: { diagram.lineStyle = $0; save() })) {
                    ForEach(LineStyle.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
                }
                Divider()
                Button("New Blank Map") { create(false) }
                Button("New Map from My Links") { create(true) }
                Divider()
                Button("Rename…") { newTitle = diagram.title; renaming = true }
                Button("Delete This Map…", role: .destructive) { confirmDelete = true }
            } label: { MenuLabel(title: diagram.title, icon: "map", compact: true) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()

            divider
            Menu {
                Button { quickAddAtCenter() } label: { Label("Box or Link…", systemImage: "plus.square") }
                Button { newLink(at: visibleCenter) } label: { Label("New Link with Details…", systemImage: "link.badge.plus") }
                Section("Box") {
                    ForEach(NodeKind.allCases) { kind in
                        Button { addNode(kind: kind, label: "", at: visibleCenter, edit: true) } label: { Label(kind.name, systemImage: kind.icon) }
                    }
                }
                Section("Organise") {
                    Button { addGroup(around: diagram.nodes.filter { selectedNodes.contains($0.id) }, at: visibleCenter) } label: {
                        Label(selectedNodes.count > 1 ? "Group the Selected Boxes" : "Group", systemImage: "square.dashed.inset.filled")
                    }
                }
            } label: { MenuLabel(title: "Add", icon: "plus", primary: true, compact: true) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()

            Button { showLinks.toggle(); if showLinks { clearSelection() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "link").font(.system(size: 11, weight: .semibold))
                    Text("Links").font(.system(size: 12.5, weight: .medium))
                    Text("\(projectLinks.count)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.ink3)
                }
                .foregroundStyle(showLinks ? tint : Theme.ink)
                .padding(.horizontal, 10).padding(.vertical, 5.5)
                .background(showLinks ? tint.opacity(0.14) : Theme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
            }.buttonStyle(.plain).help("All of this project's links: open, edit, or place them on the map")

            divider
            IconButton(icon: "arrow.uturn.backward", help: undoManager?.undoActionName.isEmpty == false ? "Undo \(undoManager!.undoActionName) (⌘Z)" : "Undo (⌘Z)", size: 26,
                       tint: canUndo ? Theme.ink2 : Theme.ink3.opacity(0.5)) { undoManager?.undo() }
                .disabled(!canUndo)
            IconButton(icon: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", size: 26, tint: canRedo ? Theme.ink2 : Theme.ink3.opacity(0.5)) { undoManager?.redo() }
                .disabled(!canRedo)
            divider
            IconButton(icon: "minus", help: "Zoom out (⌘−)", size: 26) { viewport.zoomOut() }
            Text("\(Int((viewport.zoom * 100).rounded()))%").font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Theme.ink2).frame(width: 40)
                .contentShape(Rectangle()).onTapGesture { viewport.setZoom(1) }.help("Click to show at 100%")
            IconButton(icon: "plus", help: "Zoom in (⌘+)", size: 26) { viewport.zoomIn() }
            IconButton(icon: "arrow.up.left.and.down.right.magnifyingglass", help: "Fit the whole map on screen (⌘0)", size: 26) { fitToContent() }
        }
        .padding(6)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
    }

    var divider: some View { Rectangle().fill(Theme.border).frame(width: 1, height: 20).padding(.horizontal, 3) }

    /// The middle of what's currently visible, in canvas coordinates.
    var visibleCenter: CGPoint { viewport.visibleCenter }

    func quickAddAtCenter() { openQuickAdd(at: visibleCenter) }

    /// Opens the add panel at a point: the anchor moves there first, and the panel opens once it has.
    func openQuickAdd(at point: CGPoint) {
        clearSelection()
        showingQuickAdd = false
        quickAdd = point
        DispatchQueue.main.async { showingQuickAdd = true }
    }

    func fitToContent() {
        if let bounds = DiagramLayout.contentBounds(diagram) { viewport.fit(bounds) }
        else { viewport.setZoom(1); viewport.center(on: CGPoint(x: 640, y: 380)) }
    }

    // MARK: Links

    /// Opens the link editor for a new link, which is placed on the map when it's saved.
    func newLink(at point: CGPoint) {
        let entry = Entry(projectID: diagram.projectID, kind: .link)
        pendingPlacement = (entry.id, point)
        present(.entry(entry))
    }

    func place(_ entry: Entry) {
        if let existing = diagram.nodes.first(where: { $0.entryID == entry.id }) { locateNode(existing); return }
        addNode(entry: entry, at: visibleCenter)
    }

    func locate(_ entry: Entry) {
        if let node = diagram.nodes.first(where: { $0.entryID == entry.id }) { locateNode(node) }
    }

    func locateNode(_ node: DiagramNode) {
        selectNode(node.id)
        viewport.center(on: CGPoint(x: node.x, y: node.y))
    }

    // MARK: Inspector

    @ViewBuilder var inspectorContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if selectedNodes.count > 1 {
                multiInspector
            } else if let id = selectedNode, let index = diagram.nodes.firstIndex(where: { $0.id == id }) {
                nodeInspector(index)
            } else if let id = selectedEdge, let index = diagram.edges.firstIndex(where: { $0.id == id }) {
                edgeInspector(index)
            } else if let id = selectedGroup, let index = diagram.groups.firstIndex(where: { $0.id == id }) {
                groupInspector(index)
            }
        }
        .padding(14)
    }

    func field(_ placeholder: String, _ text: Binding<String>, lines: ClosedRange<Int> = 1...4) -> some View {
        TextField(placeholder, text: text, axis: .vertical)
            .textFieldStyle(.plain).font(T.body).lineLimit(lines)
            .padding(8).background(Theme.background, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
    }

    func detailRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink3).frame(width: 14)
            Text(text).font(T.small).foregroundStyle(Theme.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    func inspectorHeader(_ title: String, close: @escaping () -> Void) -> some View {
        HStack {
            Eyebrow(text: title)
            Spacer()
            IconButton(icon: "xmark", help: "Close", size: 22, action: close)
        }
    }

    /// The boxes this one points to and is pointed at by, with the connection labels.
    @ViewBuilder func connections(of node: DiagramNode) -> some View {
        let links = diagram.edges.compactMap { edge -> (edge: DiagramEdge, other: DiagramNode, outgoing: Bool)? in
            if edge.from == node.id, let other = diagram.nodes.first(where: { $0.id == edge.to }) { return (edge, other, true) }
            if edge.to == node.id, let other = diagram.nodes.first(where: { $0.id == edge.from }) { return (edge, other, false) }
            return nil
        }
        if !links.isEmpty {
            Eyebrow(text: "Connections")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(links, id: \.edge.id) { link in
                    Button { locateNode(link.other) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: link.outgoing ? "arrow.right" : "arrow.left").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.ink3)
                            Text(info(link.other).title.ifEmpty(link.other.kind.name)).font(T.small).foregroundStyle(Theme.ink).lineLimit(1)
                            if !link.edge.label.isEmpty { Text(link.edge.label).font(T.caption).foregroundStyle(Theme.ink2).lineLimit(1) }
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Go to this box")
                }
            }
        }
    }

    @ViewBuilder var multiInspector: some View {
        let nodes = diagram.nodes.filter { selectedNodes.contains($0.id) }
        inspectorHeader("\(nodes.count) boxes selected") { selectedNodes = [] }
        Text("Drag any of them to move them together, or tidy them up:").font(T.caption).foregroundStyle(Theme.ink2)
        VStack(alignment: .leading, spacing: 6) {
            Button { align(horizontally: true) } label: { Label("Line up in a row", systemImage: "align.vertical.center") }
            Button { align(horizontally: false) } label: { Label("Line up in a column", systemImage: "align.horizontal.center") }
            Button { distribute() } label: { Label("Space evenly", systemImage: "distribute.horizontal.center") }.disabled(nodes.count < 3)
            Button { addGroup(around: nodes, at: visibleCenter) } label: { Label("Put in a new group", systemImage: "square.dashed.inset.filled") }
        }
        .buttonStyle(.softCompact)
        Rectangle().fill(Theme.border).frame(height: 1)
        Button(role: .destructive) { deleteSelection() } label: { Label("Remove \(nodes.count) boxes from the map", systemImage: "trash").font(T.small) }
            .buttonStyle(.plain).foregroundStyle(Theme.overdue)
        Text("Links stay saved; they're only taken off the map.").font(T.caption).foregroundStyle(Theme.ink3)
    }

    @ViewBuilder func nodeInspector(_ index: Int) -> some View {
        let node = diagram.nodes[index]
        let details = info(node)
        inspectorHeader(node.entryID == nil ? (node.kind == .note ? "Sticky note" : "Box") : "Link") { selectedNodes = [] }
        if let entry = details.entry {
            HStack(spacing: 10) {
                EntryIcon(entry: entry, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(T.bodyMedium).foregroundStyle(Theme.ink).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(entry.category.ifEmpty(entry.kind.shortName)).font(T.caption).foregroundStyle(Theme.ink2).lineLimit(1)
                        if !entry.environment.isEmpty { Pill(text: entry.environment, color: environmentColor(entry.environment)) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if !entry.url.isEmpty { detailRow("link", entry.url) }
                if !entry.account.isEmpty { detailRow("person.crop.circle", entry.account) }
                if !entry.tags.isEmpty { detailRow("tag", entry.tags.joined(separator: " · ")) }
                if !entry.credentials.isEmpty {
                    detailRow("lock.fill", entry.credentials.count == 1 ? "1 password saved in the Keychain" : "\(entry.credentials.count) passwords saved in the Keychain")
                }
            }
            HStack {
                if webURL(entry.url) != nil { Button("Open") { store.open(entry) }.buttonStyle(.primaryCompact) }
                Button("Edit…") { present(.entry(entry)) }.buttonStyle(.softCompact)
                if let url = webURL(entry.url) { Button { copyToClipboard(url.absoluteString) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.softCompact).help("Copy link") }
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            Eyebrow(text: "Notes")
            if entry.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { present(.entry(entry)) } label: { Label("Add notes, account, or passwords", systemImage: "square.and.pencil").font(T.small) }
                    .buttonStyle(.plain).foregroundStyle(tint)
            } else {
                MarkdownDocumentView(source: entry.body, baseSize: 13).textSelection(.enabled)
            }
            connections(of: node)
        } else if details.missing {
            Label("The link this box pointed to was deleted.", systemImage: "exclamationmark.triangle.fill").font(T.small).foregroundStyle(Theme.overdue)
                .fixedSize(horizontal: false, vertical: true)
            Button("Keep as a plain box") { diagram.nodes[index].entryID = nil; save() }.buttonStyle(.softCompact)
            connections(of: node)
        } else if node.kind == .note {
            field("Write a note", Binding(get: { diagram.nodes[index].label }, set: { setLabel($0, for: node.id) }), lines: 3...14)
            colorPicker(index)
            connections(of: node)
        } else {
            field("Name", Binding(get: { diagram.nodes[index].label }, set: { setLabel($0, for: node.id) }))
            Eyebrow(text: "Notes")
            field("What it is, who owns it, anything to remember", Binding(get: { diagram.nodes[index].notes }, set: { diagram.nodes[index].notes = $0; scheduleSave() }), lines: 3...12)
            connections(of: node)
            Eyebrow(text: "Type")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                ForEach(NodeKind.allCases) { kind in
                    let selected = node.kind == kind
                    Button { diagram.nodes[index].kind = kind; diagram.nodes[index].color = ""; save() } label: {
                        Image(systemName: kind.icon).font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selected ? .white : Theme.color(kind.tint))
                            .frame(maxWidth: .infinity).frame(height: 32)
                            .background(selected ? Theme.color(kind.tint) : Theme.color(kind.tint).opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }.buttonStyle(.plain).help(kind.name)
                }
            }
            colorPicker(index)
        }
        Rectangle().fill(Theme.border).frame(height: 1)
        Button(role: .destructive) { deleteSelection() } label: {
            Label(node.entryID == nil ? "Delete box" : "Remove from map (the link stays saved)", systemImage: "trash").font(T.small)
        }
        .buttonStyle(.plain).foregroundStyle(Theme.overdue)
    }

    @ViewBuilder func colorPicker(_ index: Int) -> some View {
        let node = diagram.nodes[index]
        Eyebrow(text: "Colour")
        swatches(selected: node.color.isEmpty ? node.kind.tint : node.color) { diagram.nodes[index].color = $0; save() }
    }

    func swatches(selected: String, choose: @escaping (String) -> Void) -> some View {
        HStack(spacing: 7) {
            ForEach(Theme.projectColors, id: \.id) { option in
                Button { choose(option.id) } label: {
                    Circle().fill(Theme.color(option.id)).frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Theme.ink.opacity(selected == option.id ? 0.85 : 0), lineWidth: 2).padding(-3))
                }.buttonStyle(.plain).help(option.name)
            }
        }
    }

    @ViewBuilder func groupInspector(_ index: Int) -> some View {
        let group = diagram.groups[index]
        let members = Set(DiagramLayout.members(of: group, in: diagram))
        inspectorHeader("Group") { selectedGroup = nil }
        field("Group name, e.g. “Backend”", Binding(get: { diagram.groups[index].title }, set: { diagram.groups[index].title = $0; scheduleSave() }), lines: 1...2)
        Text(members.isEmpty ? "Drag boxes into the frame to add them. Drag the name tag to move the group with everything in it."
                             : "\(members.count) box\(members.count == 1 ? "" : "es") inside. Drag the name tag to move them together; drag a box out to remove it.")
            .font(T.caption).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
        if !members.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(diagram.nodes.filter { members.contains($0.id) }) { node in
                    Button { locateNode(node) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: node.entryID == nil ? node.kind.icon : "link").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.ink3).frame(width: 14)
                            Text(info(node).title.ifEmpty(node.kind.name)).font(T.small).foregroundStyle(Theme.ink).lineLimit(1)
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
        Eyebrow(text: "Colour")
        swatches(selected: group.color) { diagram.groups[index].color = $0; save() }
        Button("Fit to its boxes") { fitGroup(group.id) }.buttonStyle(.softCompact).disabled(members.isEmpty)
        Rectangle().fill(Theme.border).frame(height: 1)
        Button(role: .destructive) { deleteGroup(group.id, withBoxes: false) } label: { Label("Delete group (keeps the boxes)", systemImage: "trash").font(T.small) }
            .buttonStyle(.plain).foregroundStyle(Theme.overdue)
    }

    func environmentColor(_ environment: String) -> Color {
        switch environment {
        case "Production": return Theme.success
        case "Staging": return Theme.today
        case "Development": return Theme.upcoming
        default: return Theme.ink2
        }
    }

    @ViewBuilder func edgeInspector(_ index: Int) -> some View {
        let edge = diagram.edges[index]
        inspectorHeader("Connection") { selectedEdge = nil }
        if let a = diagram.nodes.first(where: { $0.id == edge.from }), let b = diagram.nodes.first(where: { $0.id == edge.to }) {
            Text("\(info(a).title.ifEmpty("Untitled")) → \(info(b).title.ifEmpty("Untitled"))").font(T.bodyMedium).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
        }
        TextField("Label, e.g. “deploys to”", text: Binding(get: { diagram.edges[index].label }, set: { diagram.edges[index].label = $0; scheduleSave() }))
            .textFieldStyle(.plain).font(T.body)
            .padding(8).background(Theme.background, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        Toggle("Dashed line", isOn: Binding(get: { diagram.edges[index].dashed }, set: { diagram.edges[index].dashed = $0; save() })).font(T.small)
        Button("Reverse direction") { mutateEdge(edge.id) { let from = $0.from; $0.from = $0.to; $0.to = from } }.buttonStyle(.softCompact)
        Eyebrow(text: "Lines on this map")
        Picker("", selection: Binding(get: { diagram.lineStyle }, set: { diagram.lineStyle = $0; save() })) {
            ForEach(LineStyle.allCases) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).labelsHidden()
        Rectangle().fill(Theme.border).frame(height: 1)
        Button(role: .destructive) { deleteSelection() } label: { Label("Delete connection", systemImage: "trash").font(T.small) }
            .buttonStyle(.plain).foregroundStyle(Theme.overdue)
    }

    @ViewBuilder func nodeMenu(_ node: DiagramNode) -> some View {
        if let entry = info(node).entry {
            if webURL(entry.url) != nil { Button("Open Link") { store.open(entry) } }
            Button("Edit Link…") { present(.entry(entry)) }
        } else {
            Button("Rename") { selectNode(node.id); editingNode = node.id }
            Menu("Type") {
                ForEach(NodeKind.allCases) { kind in
                    Button { mutateNode(node.id) { $0.kind = kind; $0.color = "" } } label: { Label(kind.name, systemImage: kind.icon) }
                }
            }
        }
        let targets = diagram.nodes.filter { $0.id != node.id }
        if !targets.isEmpty {
            Menu("Connect to") {
                ForEach(targets) { target in Button(info(target).title.ifEmpty("Untitled")) { connect(node.id, target.id) } }
            }
        }
        Button("Duplicate") { duplicate(node.id) }
        Button("Put in a New Group") { addGroup(around: selectedNodes.contains(node.id) ? diagram.nodes.filter { selectedNodes.contains($0.id) } : [node], at: CGPoint(x: node.x, y: node.y)) }
        Divider()
        Button(node.entryID == nil ? "Delete" : "Remove from Map", role: .destructive) {
            if !selectedNodes.contains(node.id) { selectNode(node.id) }
            deleteSelection()
        }
    }

    // MARK: Actions

    func open(_ node: DiagramNode) {
        if let entry = info(node).entry { present(.entry(entry)) }
        else if node.entryID == nil { selectNode(node.id); editingNode = node.id }
    }

    func setLabel(_ label: String, for id: UUID) {
        guard let index = diagram.nodes.firstIndex(where: { $0.id == id }) else { return }
        diagram.nodes[index].label = label
        scheduleSave()
    }

    func mutateNode(_ id: UUID, _ change: (inout DiagramNode) -> Void) {
        guard let index = diagram.nodes.firstIndex(where: { $0.id == id }) else { return }
        change(&diagram.nodes[index]); save()
    }

    func mutateEdge(_ id: UUID, _ change: (inout DiagramEdge) -> Void) {
        guard let index = diagram.edges.firstIndex(where: { $0.id == id }) else { return }
        change(&diagram.edges[index]); save()
    }

    func addNode(kind: NodeKind, label: String, at point: CGPoint, edit: Bool = false) {
        let spot = DiagramLayout.freeSpot(near: point, in: diagram)
        let node = DiagramNode(label: label, x: spot.x, y: spot.y, kind: kind)
        diagram.nodes.append(node)
        selectNode(node.id)
        if edit || label.isEmpty { editingNode = node.id }
        save()
    }

    func addNode(entry: Entry, at point: CGPoint) {
        if let existing = diagram.nodes.first(where: { $0.entryID == entry.id }) { locateNode(existing); return }
        let spot = DiagramLayout.freeSpot(near: point, in: diagram)
        let node = DiagramNode(label: entry.title, entryID: entry.id, x: spot.x, y: spot.y)
        diagram.nodes.append(node)
        selectNode(node.id)
        save()
    }

    func finishLink(from id: UUID, at point: CGPoint) {
        let target = linkTarget
        linking = nil
        if let target { connect(id, target) }
    }

    func connect(_ from: UUID, _ to: UUID) {
        guard from != to, !diagram.edges.contains(where: { ($0.from == from && $0.to == to) || ($0.from == to && $0.to == from) }) else { return }
        let edge = DiagramEdge(from: from, to: to)
        diagram.edges.append(edge)
        selectEdge(edge.id)
        save()
    }

    func duplicate(_ id: UUID) {
        guard var copy = diagram.nodes.first(where: { $0.id == id }) else { return }
        copy.id = UUID()
        let spot = DiagramLayout.freeSpot(near: CGPoint(x: copy.x + 40, y: copy.y + 80), in: diagram)
        copy.x = spot.x; copy.y = spot.y
        diagram.nodes.append(copy); selectNode(copy.id); save()
    }

    /// Lines the selected boxes up on their average centre.
    func align(horizontally: Bool) {
        let indices = diagram.nodes.indices.filter { selectedNodes.contains(diagram.nodes[$0].id) }
        guard indices.count > 1 else { return }
        let values = indices.map { horizontally ? diagram.nodes[$0].y : diagram.nodes[$0].x }
        let target = DiagramLayout.snap(values.reduce(0, +) / Double(values.count))
        for index in indices { if horizontally { diagram.nodes[index].y = target } else { diagram.nodes[index].x = target } }
        save()
    }

    /// Spaces the selected boxes evenly along whichever direction they're spread out in.
    func distribute() {
        let indices = diagram.nodes.indices.filter { selectedNodes.contains(diagram.nodes[$0].id) }
        guard indices.count > 2 else { return }
        let xs = indices.map { diagram.nodes[$0].x }, ys = indices.map { diagram.nodes[$0].y }
        let horizontal = (xs.max()! - xs.min()!) >= (ys.max()! - ys.min()!)
        let sorted = indices.sorted { horizontal ? diagram.nodes[$0].x < diagram.nodes[$1].x : diagram.nodes[$0].y < diagram.nodes[$1].y }
        let first = horizontal ? xs.min()! : ys.min()!, last = horizontal ? xs.max()! : ys.max()!
        let step = (last - first) / Double(sorted.count - 1)
        for (position, index) in sorted.enumerated() {
            let value = DiagramLayout.snap(first + step * Double(position))
            if horizontal { diagram.nodes[index].x = value } else { diagram.nodes[index].y = value }
        }
        save()
    }

    /// Moves the selected boxes, or the selected group with everything in it.
    func nudge(dx: Double, dy: Double) {
        if !selectedNodes.isEmpty {
            for index in diagram.nodes.indices where selectedNodes.contains(diagram.nodes[index].id) {
                let point = DiagramLayout.clamp(CGPoint(x: diagram.nodes[index].x + dx, y: diagram.nodes[index].y + dy))
                diagram.nodes[index].x = point.x; diagram.nodes[index].y = point.y
            }
            save()
        } else if let id = selectedGroup, let group = diagram.groups.first(where: { $0.id == id }) {
            groupDrag = (id, .zero, DiagramLayout.members(of: group, in: diagram))
            finishGroupDrag(id, CGSize(width: dx, height: dy))
        }
    }

    // MARK: Keyboard

    func installKeys() {
        removeKeys()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in handleKey(event) ? nil : event }
    }

    func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Delete, Escape, arrows, ⌘A, ⌘D, and zoom. Keys typed into a text field are left alone.
    func handleKey(_ event: NSEvent) -> Bool {
        guard let window = viewport.window, event.window === window, window.attachedSheet == nil else { return false }
        let typing = window.firstResponder is NSText
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 { // Escape
            if editingNode != nil { window.makeFirstResponder(nil); clearSelection(); return true }
            if typing { return false }
            if hasSelection { clearSelection(); return true }
            if showLinks { showLinks = false; return true }
            return false
        }
        guard !typing else { return false }
        if flags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "=", "+": viewport.zoomIn(); return true
            case "-": viewport.zoomOut(); return true
            case "0": fitToContent(); return true
            case "a": selectedEdge = nil; selectedGroup = nil; selectedNodes = Set(diagram.nodes.map(\.id)); return true
            case "d":
                guard !selectedNodes.isEmpty else { return false }
                for id in selectedNodes { duplicate(id) }
                return true
            default: return false
            }
        }
        let step: Double = flags.contains(.shift) ? 50 : 10
        let movable = !selectedNodes.isEmpty || selectedGroup != nil
        switch event.keyCode {
        case 51, 117: // Delete, forward delete
            guard hasSelection else { return false }
            deleteSelection(); return true
        case 123: guard movable else { return false }; nudge(dx: -step, dy: 0); return true
        case 124: guard movable else { return false }; nudge(dx: step, dy: 0); return true
        case 125: guard movable else { return false }; nudge(dx: 0, dy: step); return true
        case 126: guard movable else { return false }; nudge(dx: 0, dy: -step); return true
        case 36: // Return renames the selected plain box
            guard let id = selectedNode, diagram.nodes.first(where: { $0.id == id })?.entryID == nil else { return false }
            editingNode = id; return true
        default: return false
        }
    }

    func deleteSelection() {
        if let id = selectedGroup {
            deleteGroup(id, withBoxes: false)
        } else if !selectedNodes.isEmpty {
            let ids = selectedNodes
            diagram.edges.removeAll { ids.contains($0.from) || ids.contains($0.to) }
            diagram.nodes.removeAll { ids.contains($0.id) }
            selectedNodes = []; editingNode = nil
            save()
        } else if let id = selectedEdge {
            diagram.edges.removeAll { $0.id == id }
            selectedEdge = nil
            save()
        }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    func save() {
        saveTask?.cancel()
        // Remember linked records' current titles so a removed record still shows its last known name.
        for index in diagram.nodes.indices {
            if let id = diagram.nodes[index].entryID, let entry = store.entry(id) { diagram.nodes[index].label = entry.title }
        }
        diagram.updatedAt = Date()
        let previous = store.workspace.diagrams.first { $0.id == diagram.id }
        store.upsert(diagram, in: \.diagrams)
        if let previous, !Self.sameContent(previous, diagram), let undoManager {
            Self.registerRestore(previous, in: store, undoManager: undoManager)
            refreshUndo()
        }
    }

    /// Whether two versions of a map differ only in their save time.
    static func sameContent(_ a: Diagram, _ b: Diagram) -> Bool {
        var a = a; a.updatedAt = b.updatedAt
        return a == b
    }

    /// Registers an undo step that puts `version` back. Undoing it registers the reverse, which becomes Redo.
    /// The step works on the stored map, so it still applies after leaving the Map tab and coming back.
    static func registerRestore(_ version: Diagram, in store: Store, undoManager: UndoManager) {
        undoManager.registerUndo(withTarget: store) { store in
            MainActor.assumeIsolated {
                // A map deleted since then stays deleted.
                guard let current = store.workspace.diagrams.first(where: { $0.id == version.id }) else { return }
                var restored = version
                restored.updatedAt = Date()
                store.upsert(restored, in: \.diagrams)
                registerRestore(current, in: store, undoManager: undoManager)
            }
        }
        undoManager.setActionName("Map Change")
    }

    func refreshUndo() {
        canUndo = undoManager?.canUndo ?? false
        canRedo = undoManager?.canRedo ?? false
    }
}

extension Diagram {
    func with(id: UUID) -> Diagram { var copy = self; copy.id = id; return copy }
}

/// One box on the map. Equatable so unchanged boxes skip re-rendering while something else is dragged.
struct DiagramNodeView: View, Equatable {
    @Environment(\.pageTint) var tint
    let node: DiagramNode
    let info: DiagramEditor.NodeInfo
    let selected: Bool
    let editing: Bool
    let linkTarget: Bool
    /// A connection is being dragged out of this box.
    let linkSource: Bool
    @Binding var label: String
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onCommit: () -> Void
    let onDrag: (CGSize) -> Void
    let onDragEnd: (CGSize) -> Void
    let onLink: (CGPoint) -> Void
    let onLinkEnd: (CGPoint) -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool

    static func == (a: DiagramNodeView, b: DiagramNodeView) -> Bool {
        a.node == b.node && a.info == b.info && a.selected == b.selected && a.editing == b.editing
            && a.linkTarget == b.linkTarget && a.linkSource == b.linkSource
    }

    /// How far the handles reach past the box's edges. The box takes clicks and hover that far out at each handle,
    /// so the pointer can move from the box onto a handle, all of it, without losing it.
    static let handleReach: CGFloat = 13
    var showsHandles: Bool { hovering || selected || linkSource }

    var size: CGSize { DiagramLayout.size(of: node) }
    var isNote: Bool { node.entryID == nil && node.kind == .note }
    /// The box's own notes, or the linked link's notes.
    var notes: String { (info.entry?.body ?? node.notes).trimmingCharacters(in: .whitespacesAndNewlines) }
    var color: Color { info.missing ? Theme.overdue : Theme.color(node.color.isEmpty ? node.kind.tint : node.color) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: isNote ? 6 : 14, style: .continuous)
        content
            .frame(width: size.width, height: size.height)
            .background(isNote ? AnyShapeStyle(color.opacity(0.22)) : AnyShapeStyle(Theme.card), in: shape)
            .overlay(
                shape.strokeBorder(info.missing ? Theme.overdue : (selected || linkTarget ? tint : (isNote ? color.opacity(0.45) : Theme.border)),
                                   style: StrokeStyle(lineWidth: selected || linkTarget ? 2 : 1, dash: info.missing ? [5, 4] : []))
            )
            .shadow(color: selected || linkTarget ? tint.opacity(0.25) : .black.opacity(hovering ? 0.12 : 0.06), radius: selected ? 10 : (hovering ? 9 : 5), y: 2)
            .overlay(alignment: .topTrailing) {
                if !isNote && !notes.isEmpty {
                    Image(systemName: "text.alignleft").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.ink3)
                        .padding(7).accessibilityLabel("Has notes")
                }
            }
            // Always there, only faded: a drag that started on a handle would be cancelled if the handle went away.
            .overlay { handles.opacity(showsHandles ? 1 : 0).allowsHitTesting(showsHandles) }
            .help(isNote || notes.isEmpty ? "" : String(notes.prefix(280)))
            .padding(Self.handleReach)
            .contentShape(BoxWithHandles(inset: Self.handleReach))
            .onHover { hovering = $0 }
            // Selecting on the first click (rather than waiting to rule out a double-click) opens the details at once.
            .simultaneousGesture(TapGesture().onEnded { onSelect() })
            .onTapGesture(count: 2) { onOpen() }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("canvas"))
                .onChanged { onDrag($0.translation) }
                .onEnded { onDragEnd($0.translation) })
            .onChange(of: editing) { _, on in focused = on }
            .onAppear { if editing { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true } } }
    }

    /// A handle on each side: drag one onto another box to connect them.
    var handles: some View {
        ZStack {
            handle.offset(y: -size.height / 2)
            handle.offset(x: size.width / 2)
            handle.offset(y: size.height / 2)
            handle.offset(x: -size.width / 2)
        }
    }

    var handle: some View {
        Circle().fill(tint).frame(width: 11, height: 11)
            .overlay(Circle().strokeBorder(Theme.card, lineWidth: 2))
            .padding(Self.handleReach - 5.5).contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
                .onChanged { onLink($0.location) }
                .onEnded { onLinkEnd($0.location) })
            .help("Drag onto another box to connect")
    }

    @ViewBuilder var content: some View {
        if isNote {
            Group {
                if editing {
                    TextField("Write a note", text: $label, axis: .vertical).textFieldStyle(.plain).focused($focused).onSubmit(onCommit)
                } else {
                    Text(label.isEmpty ? "Sticky note" : label).foregroundStyle(label.isEmpty ? Theme.ink3 : Theme.ink)
                }
            }
            .font(.system(size: 12.5)).multilineTextAlignment(.leading)
            .padding(11).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            HStack(spacing: 10) {
                if let entry = info.entry {
                    EntryIcon(entry: entry, size: 36)
                } else {
                    Image(systemName: info.missing ? "exclamationmark.triangle.fill" : node.kind.icon).font(.system(size: 15, weight: .medium)).foregroundStyle(color)
                        .frame(width: 36, height: 36).background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 1) {
                    if editing {
                        TextField(node.kind.name, text: $label).textFieldStyle(.plain).font(.system(size: 13, weight: .semibold)).focused($focused).onSubmit(onCommit)
                    } else {
                        Text(info.title.isEmpty ? node.kind.name : info.title).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(info.title.isEmpty ? Theme.ink3 : Theme.ink).lineLimit(2).minimumScaleFactor(0.85)
                    }
                    if !info.title.isEmpty || editing {
                        Text(info.subtitle).font(.system(size: 10.5)).foregroundStyle(info.missing ? Theme.overdue : Theme.ink2).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
        }
    }
}

/// Where a box takes clicks and hover: the box itself, plus a circle at the middle of each side for its handles.
struct BoxWithHandles: Shape {
    /// How far the box sits inside the view's frame, which is also each handle's radius.
    let inset: CGFloat
    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: inset, dy: inset)
        var area = Path(box)
        for center in [CGPoint(x: box.midX, y: box.minY), CGPoint(x: box.maxX, y: box.midY), CGPoint(x: box.midX, y: box.maxY), CGPoint(x: box.minX, y: box.midY)] {
            area = area.union(Path(ellipseIn: CGRect(x: center.x - inset, y: center.y - inset, width: inset * 2, height: inset * 2)))
        }
        return area
    }
}

/// A labelled frame grouping boxes. Drawn in two parts: the frame goes under the connection lines,
/// the name tag and resize corner go over them (so lines never hide the name). Only those take clicks.
struct DiagramGroupView: View {
    enum Part { case frame, controls }
    @Environment(\.pageTint) var tint
    let group: DiagramGroup
    let part: Part
    let frame: CGRect
    let count: Int
    let selected: Bool
    let onSelect: () -> Void
    let onDrag: (CGSize) -> Void
    let onDragEnd: (CGSize) -> Void
    let onResize: (CGSize) -> Void
    let onResizeEnd: (CGSize) -> Void

    var color: Color { Theme.color(group.color) }

    var body: some View {
        Group {
            switch part {
            case .frame:
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(color.opacity(0.07))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(selected ? tint : color.opacity(0.45), style: StrokeStyle(lineWidth: selected ? 2 : 1.3, dash: [7, 5])))
                    .frame(width: frame.width, height: frame.height)
                    .allowsHitTesting(false)
            case .controls:
                ZStack(alignment: .topLeading) {
                    Color.clear.allowsHitTesting(false)
                    tag.padding(8).frame(maxWidth: frame.width - 16, alignment: .leading)
                }
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                .overlay(alignment: .bottomTrailing) { if selected { resizer } }
            }
        }
        .position(x: frame.midX, y: frame.midY)
    }

    var tag: some View {
        HStack(spacing: 7) {
            Image(systemName: "square.dashed.inset.filled").font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            Text(group.title.isEmpty ? "Untitled group" : group.title).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(group.title.isEmpty ? Theme.ink3 : Theme.ink).lineLimit(1)
            if count > 0 { Text("\(count)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.ink3) }
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(Theme.card, in: Capsule())
        .overlay(Capsule().strokeBorder(selected ? tint : color.opacity(0.5)))
        .contentShape(Capsule())
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("canvas"))
            .onChanged { onDrag($0.translation) }
            .onEnded { onDragEnd($0.translation) })
        .help("Click to name or colour the group · drag to move it with everything inside")
    }

    var resizer: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
            .frame(width: 20, height: 20).background(tint, in: Circle())
            .overlay(Circle().strokeBorder(Theme.card, lineWidth: 2))
            .padding(4).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                .onChanged { onResize($0.translation) }
                .onEnded { onResizeEnd($0.translation) })
            .help("Drag to resize")
    }
}

struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 20
            var path = Path()
            var x: CGFloat = spacing
            while x < size.width {
                var y: CGFloat = spacing
                while y < size.height { path.addEllipse(in: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)); y += spacing }
                x += spacing
            }
            context.fill(path, with: .color(Theme.ink3.opacity(0.28)))
        }
    }
}
