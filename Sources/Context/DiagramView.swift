import SwiftUI

/// The Map view of a project's links: boxes for people, apps, services, and saved links, joined by arrows.
struct DiagramSection: View {
    @EnvironmentObject var store: Store
    let project: Project
    @State private var selectedID: UUID?

    var diagrams: [Diagram] {
        store.workspace.diagrams.filter { $0.projectID == project.id }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
    var linkCount: Int { store.workspace.entries.filter { $0.projectID == project.id && EntryKind.linkKinds.contains($0.kind) }.count }

    var body: some View {
        let current = diagrams.first { $0.id == selectedID } ?? diagrams.max { $0.updatedAt < $1.updatedAt }
        if let current {
            DiagramEditor(diagram: current, others: diagrams, select: { selectedID = $0 }, create: create)
                .id(current.id)
        } else {
            VStack(spacing: 14) {
                EmptyState(icon: "point.3.connected.trianglepath.dotted", title: "See how it all fits together",
                           message: linkCount > 0 ? "Start from the \(linkCount) links you've already saved — Context lays them out for you — or begin with a blank canvas."
                                                   : "Draw the people, apps, and services behind this project and how they connect.")
                HStack(spacing: 10) {
                    if linkCount > 0 { Button { create(fromLinks: true) } label: { Label("Build from my links", systemImage: "wand.and.stars") }.buttonStyle(.primary) }
                    Button("Start blank") { create(fromLinks: false) }.buttonStyle(linkCount > 0 ? AnyButtonStyle(.soft) : AnyButtonStyle(.primary))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
    }

    func create(fromLinks: Bool) {
        let title = diagrams.isEmpty ? "Overview" : "Map \(diagrams.count + 1)"
        let diagram = fromLinks ? DiagramLayout.fromLinks(project: project, entries: store.workspace.entries, title: title)
                                : Diagram(projectID: project.id, title: title)
        if store.upsert(diagram, in: \.diagrams) { selectedID = diagram.id }
    }
}

private struct ScrollOriginKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { value = nextValue() }
}

struct DiagramEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.present) var present
    @Environment(\.pageTint) var tint
    @State var diagram: Diagram
    let others: [Diagram]
    let select: (UUID) -> Void
    let create: (_ fromLinks: Bool) -> Void

    @State private var selectedNode: UUID?
    @State private var selectedEdge: UUID?
    @State private var editingNode: UUID?
    @State private var dragOffset: [UUID: CGSize] = [:]
    /// A connection being dragged out from a node's handle.
    @State private var linking: (from: UUID, to: CGPoint)?
    @State private var zoom: CGFloat = 1
    @State private var scrollOrigin: CGPoint = .zero
    @State private var viewport: CGSize = .zero
    @State private var confirmDelete = false
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ScrollView([.horizontal, .vertical]) {
                    canvas
                        .frame(width: DiagramLayout.canvas.width, height: DiagramLayout.canvas.height, alignment: .topLeading)
                        .scaleEffect(zoom, anchor: .topLeading)
                        .frame(width: DiagramLayout.canvas.width * zoom, height: DiagramLayout.canvas.height * zoom, alignment: .topLeading)
                        .background(GeometryReader { inner in
                            Color.clear.preference(key: ScrollOriginKey.self, value: inner.frame(in: .named("viewport")).origin)
                        })
                }
                .coordinateSpace(name: "viewport")
                .onPreferenceChange(ScrollOriginKey.self) { scrollOrigin = $0 }
                .background(Theme.background)

                toolbar.padding(14)
                if selectedNode != nil || selectedEdge != nil {
                    inspector.frame(width: 256).padding(14).frame(maxWidth: .infinity, alignment: .topTrailing)
                }
                Text(diagram.nodes.isEmpty ? "Double-click anywhere to add a box" : "Drag a box's ● handle onto another box to connect them · double-click to rename · double-click empty space to add")
                    .font(T.caption).foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.card.opacity(0.92), in: Capsule()).overlay(Capsule().strokeBorder(Theme.border))
                    .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(false)
            }
            .onAppear { viewport = geo.size }
            .onChange(of: geo.size) { _, size in viewport = size }
        }
        .onChange(of: store.workspace.diagrams.first { $0.id == diagram.id }) { _, stored in
            if let stored, dragOffset.isEmpty, linking == nil, stored != diagram { diagram = stored }
        }
        .onDeleteCommand(perform: deleteSelection)
        .confirmationDialog("Delete the map “\(diagram.title)”?", isPresented: $confirmDelete) {
            Button("Delete Map", role: .destructive) { store.remove(diagram.id, in: \.diagrams) }
        } message: { Text("Your saved links are not affected.") }
        .alert("Rename map", isPresented: $renaming) {
            TextField("Name", text: $newTitle)
            Button("Rename") { let name = newTitle.trimmingCharacters(in: .whitespaces); if !name.isEmpty { diagram.title = name; save() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Canvas

    var canvas: some View {
        ZStack(alignment: .topLeading) {
            DotGrid()
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { location in addNode(kind: .step, at: location, edit: true) }
                .onTapGesture { selectedNode = nil; selectedEdge = nil; editingNode = nil }
            edgeLayer
            ForEach(diagram.edges) { edge in edgeHandle(edge) }
            ForEach(diagram.nodes) { node in
                DiagramNodeView(node: node, info: info(node), selected: selectedNode == node.id, editing: editingNode == node.id,
                                label: Binding(get: { node.label }, set: { setLabel($0, for: node.id) }),
                                onSelect: { selectedNode = node.id; selectedEdge = nil },
                                onOpen: { open(node) },
                                onCommit: { editingNode = nil; save() },
                                onDrag: { dragOffset[node.id] = $0 },
                                onDragEnd: { finishDrag(node, $0) },
                                onLink: { linking = (node.id, $0) },
                                onLinkEnd: { finishLink(from: node.id, at: $0) })
                    .position(x: node.x + (dragOffset[node.id]?.width ?? 0), y: node.y + (dragOffset[node.id]?.height ?? 0))
                    .contextMenu { nodeMenu(node) }
            }
        }
        .coordinateSpace(name: "canvas")
    }

    func rect(_ node: DiagramNode) -> CGRect { DiagramLayout.rect(of: node, offset: dragOffset[node.id] ?? .zero) }

    struct NodeInfo { let title: String; let subtitle: String; let missing: Bool; let entry: Entry? }

    func info(_ node: DiagramNode) -> NodeInfo {
        guard let id = node.entryID else { return NodeInfo(title: node.label, subtitle: node.kind.name, missing: false, entry: nil) }
        if let entry = store.entry(id) {
            return NodeInfo(title: entry.title, subtitle: BrandCatalog.host(of: entry.url) ?? entry.kind.shortName, missing: false, entry: entry)
        }
        return NodeInfo(title: node.label.isEmpty ? "Removed link" : node.label, subtitle: "This link was deleted", missing: true, entry: nil)
    }

    var edgeLayer: some View {
        Canvas { context, _ in
            for edge in diagram.edges {
                guard let a = diagram.nodes.first(where: { $0.id == edge.from }), let b = diagram.nodes.first(where: { $0.id == edge.to }) else { continue }
                draw(DiagramLayout.connector(from: rect(a), to: rect(b)), selected: selectedEdge == edge.id, dashed: edge.dashed, in: &context)
            }
            if let linking, let a = diagram.nodes.first(where: { $0.id == linking.from }) {
                let target = CGRect(x: linking.to.x - 1, y: linking.to.y - 1, width: 2, height: 2)
                draw(DiagramLayout.connector(from: rect(a), to: target), selected: true, dashed: true, in: &context)
            }
        }
        .frame(width: DiagramLayout.canvas.width, height: DiagramLayout.canvas.height)
        .allowsHitTesting(false)
    }

    func draw(_ c: (start: CGPoint, c1: CGPoint, c2: CGPoint, end: CGPoint), selected: Bool, dashed: Bool, in context: inout GraphicsContext) {
        var path = Path()
        path.move(to: c.start)
        path.addCurve(to: c.end, control1: c.c1, control2: c.c2)
        let color = selected ? tint : Theme.ink3
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: selected ? 2.4 : 1.7, lineCap: .round, dash: dashed ? [6, 5] : []))
        var direction = CGPoint(x: c.end.x - c.c2.x, y: c.end.y - c.c2.y)
        if abs(direction.x) < 0.01 && abs(direction.y) < 0.01 { direction = CGPoint(x: c.end.x - c.start.x, y: c.end.y - c.start.y) }
        let angle = atan2(direction.y, direction.x)
        var arrow = Path()
        arrow.move(to: CGPoint(x: c.end.x + 4 * cos(angle), y: c.end.y + 4 * sin(angle)))
        arrow.addLine(to: CGPoint(x: c.end.x - 9 * cos(angle - 0.45), y: c.end.y - 9 * sin(angle - 0.45)))
        arrow.addLine(to: CGPoint(x: c.end.x - 9 * cos(angle + 0.45), y: c.end.y - 9 * sin(angle + 0.45)))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(color))
    }

    /// The clickable midpoint of a connection: its label, or a small dot when it has none.
    @ViewBuilder func edgeHandle(_ edge: DiagramEdge) -> some View {
        if let a = diagram.nodes.first(where: { $0.id == edge.from }), let b = diagram.nodes.first(where: { $0.id == edge.to }) {
            let mid = DiagramLayout.midpoint(DiagramLayout.connector(from: rect(a), to: rect(b)))
            let selected = selectedEdge == edge.id
            Button { selectedEdge = edge.id; selectedNode = nil; editingNode = nil } label: {
                Group {
                    if edge.label.isEmpty {
                        Circle().fill(selected ? tint : Theme.card).frame(width: 11, height: 11)
                            .overlay(Circle().strokeBorder(selected ? tint : Theme.ink3, lineWidth: 1.5))
                            .padding(6)
                    } else {
                        Text(edge.label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(selected ? tint : Theme.ink2)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Theme.background, in: Capsule())
                            .overlay(Capsule().strokeBorder(selected ? tint : Theme.border))
                    }
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .position(mid)
            .help("Click to label, restyle, or delete this connection")
            .contextMenu {
                Button("Reverse Direction") { mutateEdge(edge.id) { let from = $0.from; $0.from = $0.to; $0.to = from } }
                Button(edge.dashed ? "Solid Line" : "Dashed Line") { mutateEdge(edge.id) { $0.dashed.toggle() } }
                Divider()
                Button("Delete Connection", role: .destructive) { diagram.edges.removeAll { $0.id == edge.id }; selectedEdge = nil; save() }
            }
        }
    }

    // MARK: Toolbar

    var toolbar: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(others) { other in
                    Button { select(other.id) } label: { Label(other.title, systemImage: other.id == diagram.id ? "checkmark" : "map") }
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
                Section("Add a box") {
                    ForEach(NodeKind.allCases) { kind in
                        Button { addNode(kind: kind, at: visibleCenter, edit: true) } label: { Label(kind.name, systemImage: kind.icon) }
                    }
                }
                let entries = store.workspace.entries.filter { $0.projectID == diagram.projectID && EntryKind.linkKinds.contains($0.kind) }
                    .sorted { $0.title.lowercased() < $1.title.lowercased() }
                if !entries.isEmpty {
                    Section("Add one of your links") {
                        ForEach(entries) { entry in
                            Button { addNode(entry: entry, at: visibleCenter) } label: {
                                Label(entry.title, systemImage: diagram.nodes.contains { $0.entryID == entry.id } ? "checkmark" : entry.kind.icon)
                            }
                        }
                    }
                }
            } label: { MenuLabel(title: "Add", icon: "plus", primary: true, compact: true) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()

            Button { withAnimation(.easeInOut(duration: 0.3)) { diagram = DiagramLayout.tidy(diagram) }; save() } label: { Label("Tidy up", systemImage: "wand.and.stars") }
                .buttonStyle(.softCompact).help("Arrange the boxes in neat columns that follow the arrows").disabled(diagram.nodes.count < 2)
            divider
            IconButton(icon: "minus", help: "Zoom out", size: 26) { zoom = max(0.5, zoom - 0.1) }
            Text("\(Int((zoom * 100).rounded()))%").font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Theme.ink2).frame(width: 40)
                .onTapGesture { zoom = 1 }.help("Click to reset to 100%")
            IconButton(icon: "plus", help: "Zoom in", size: 26) { zoom = min(1.6, zoom + 0.1) }
        }
        .padding(6)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
    }

    var divider: some View { Rectangle().fill(Theme.border).frame(width: 1, height: 20).padding(.horizontal, 3) }

    /// The middle of what's currently visible, in canvas coordinates.
    var visibleCenter: CGPoint {
        CGPoint(x: (-scrollOrigin.x + viewport.width / 2) / zoom, y: (-scrollOrigin.y + viewport.height / 2) / zoom)
    }

    // MARK: Inspector

    var inspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let id = selectedNode, let index = diagram.nodes.firstIndex(where: { $0.id == id }) {
                nodeInspector(index)
            } else if let id = selectedEdge, let index = diagram.edges.firstIndex(where: { $0.id == id }) {
                edgeInspector(index)
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
    }

    @ViewBuilder func nodeInspector(_ index: Int) -> some View {
        let node = diagram.nodes[index]
        let details = info(node)
        HStack {
            Eyebrow(text: node.entryID == nil ? "Box" : "Linked box")
            Spacer()
            IconButton(icon: "xmark", help: "Close", size: 22) { selectedNode = nil }
        }
        if let entry = details.entry {
            HStack(spacing: 10) {
                EntryIcon(entry: entry, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).font(T.bodyMedium).foregroundStyle(Theme.ink).lineLimit(2)
                    Text(details.subtitle).font(T.caption).foregroundStyle(Theme.ink2).lineLimit(1)
                }
            }
            Text("Shows the link's current name and logo. Renaming the link updates this box.").font(T.caption).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            HStack {
                if webURL(entry.url) != nil { Button("Open") { store.open(entry) }.buttonStyle(.primaryCompact) }
                Button("Edit link…") { present(.entry(entry)) }.buttonStyle(.softCompact)
            }
        } else if details.missing {
            Label("The link this box pointed to was deleted.", systemImage: "exclamationmark.triangle.fill").font(T.small).foregroundStyle(Theme.overdue)
                .fixedSize(horizontal: false, vertical: true)
            Button("Keep as a plain box") { diagram.nodes[index].entryID = nil; save() }.buttonStyle(.softCompact)
        } else {
            TextField("Label", text: Binding(get: { diagram.nodes[index].label }, set: { setLabel($0, for: node.id) }), axis: .vertical)
                .textFieldStyle(.plain).font(T.body).lineLimit(1...4)
                .padding(8).background(Theme.background, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
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
            Eyebrow(text: "Colour")
            HStack(spacing: 7) {
                ForEach(Theme.projectColors, id: \.id) { option in
                    let current = node.color.isEmpty ? node.kind.tint : node.color
                    Button { diagram.nodes[index].color = option.id; save() } label: {
                        Circle().fill(Theme.color(option.id)).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(Theme.ink.opacity(current == option.id ? 0.85 : 0), lineWidth: 2).padding(-3))
                    }.buttonStyle(.plain).help(option.name)
                }
            }
        }
        Rectangle().fill(Theme.border).frame(height: 1)
        Button(role: .destructive) { deleteSelection() } label: { Label("Delete box", systemImage: "trash").font(T.small) }
            .buttonStyle(.plain).foregroundStyle(Theme.overdue)
    }

    @ViewBuilder func edgeInspector(_ index: Int) -> some View {
        let edge = diagram.edges[index]
        HStack {
            Eyebrow(text: "Connection")
            Spacer()
            IconButton(icon: "xmark", help: "Close", size: 22) { selectedEdge = nil }
        }
        if let a = diagram.nodes.first(where: { $0.id == edge.from }), let b = diagram.nodes.first(where: { $0.id == edge.to }) {
            Text("\(info(a).title.ifEmpty("Untitled")) → \(info(b).title.ifEmpty("Untitled"))").font(T.bodyMedium).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
        }
        TextField("Label, e.g. “deploys to”", text: Binding(get: { diagram.edges[index].label }, set: { diagram.edges[index].label = $0; scheduleSave() }))
            .textFieldStyle(.plain).font(T.body)
            .padding(8).background(Theme.background, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        Toggle("Dashed line", isOn: Binding(get: { diagram.edges[index].dashed }, set: { diagram.edges[index].dashed = $0; save() })).font(T.small)
        Button("Reverse direction") { mutateEdge(edge.id) { let from = $0.from; $0.from = $0.to; $0.to = from } }.buttonStyle(.softCompact)
        Rectangle().fill(Theme.border).frame(height: 1)
        Button(role: .destructive) { deleteSelection() } label: { Label("Delete connection", systemImage: "trash").font(T.small) }
            .buttonStyle(.plain).foregroundStyle(Theme.overdue)
    }

    @ViewBuilder func nodeMenu(_ node: DiagramNode) -> some View {
        if let entry = info(node).entry {
            if webURL(entry.url) != nil { Button("Open Link") { store.open(entry) } }
            Button("Edit Link…") { present(.entry(entry)) }
        } else {
            Button("Rename") { selectedNode = node.id; editingNode = node.id }
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
        Button("Duplicate") {
            var copy = node; copy.id = UUID()
            let spot = DiagramLayout.freeSpot(near: CGPoint(x: node.x + 40, y: node.y + 80), in: diagram)
            copy.x = spot.x; copy.y = spot.y
            diagram.nodes.append(copy); selectedNode = copy.id; save()
        }
        Divider()
        Button("Delete", role: .destructive) { selectedNode = node.id; selectedEdge = nil; deleteSelection() }
    }

    // MARK: Actions

    func open(_ node: DiagramNode) {
        if let entry = info(node).entry { present(.entry(entry)) }
        else if node.entryID == nil { selectedNode = node.id; editingNode = node.id }
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

    func addNode(kind: NodeKind, at point: CGPoint, edit: Bool) {
        let spot = DiagramLayout.freeSpot(near: point, in: diagram)
        let node = DiagramNode(label: kind == .note ? "" : "", x: spot.x, y: spot.y, kind: kind)
        diagram.nodes.append(node)
        selectedNode = node.id; selectedEdge = nil
        if edit { editingNode = node.id }
        save()
    }

    func addNode(entry: Entry, at point: CGPoint) {
        let spot = DiagramLayout.freeSpot(near: point, in: diagram)
        let node = DiagramNode(label: entry.title, entryID: entry.id, x: spot.x, y: spot.y)
        diagram.nodes.append(node)
        selectedNode = node.id; selectedEdge = nil
        save()
    }

    func finishDrag(_ node: DiagramNode, _ translation: CGSize) {
        dragOffset[node.id] = nil
        guard let index = diagram.nodes.firstIndex(where: { $0.id == node.id }) else { return }
        let point = DiagramLayout.clamp(CGPoint(x: node.x + translation.width, y: node.y + translation.height))
        diagram.nodes[index].x = DiagramLayout.snap(point.x)
        diagram.nodes[index].y = DiagramLayout.snap(point.y)
        save()
    }

    func finishLink(from id: UUID, at point: CGPoint) {
        linking = nil
        guard let target = diagram.nodes.last(where: { $0.id != id && DiagramLayout.rect(of: $0).insetBy(dx: -8, dy: -8).contains(point) }) else { return }
        connect(id, target.id)
    }

    func connect(_ from: UUID, _ to: UUID) {
        guard from != to, !diagram.edges.contains(where: { ($0.from == from && $0.to == to) || ($0.from == to && $0.to == from) }) else { return }
        let edge = DiagramEdge(from: from, to: to)
        diagram.edges.append(edge)
        selectedEdge = edge.id; selectedNode = nil
        save()
    }

    func deleteSelection() {
        if let id = selectedNode {
            diagram.edges.removeAll { $0.from == id || $0.to == id }
            diagram.nodes.removeAll { $0.id == id }
            selectedNode = nil; editingNode = nil
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
        store.upsert(diagram, in: \.diagrams)
    }
}

/// One box on the map.
struct DiagramNodeView: View {
    @Environment(\.pageTint) var tint
    let node: DiagramNode
    let info: DiagramEditor.NodeInfo
    let selected: Bool
    let editing: Bool
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

    var size: CGSize { DiagramLayout.size(of: node) }
    var isNote: Bool { node.entryID == nil && node.kind == .note }
    var color: Color { info.missing ? Theme.overdue : Theme.color(node.color.isEmpty ? node.kind.tint : node.color) }

    var body: some View {
        content
            .frame(width: size.width, height: size.height)
            .background(isNote ? AnyShapeStyle(color.opacity(0.22)) : AnyShapeStyle(Theme.card), in: RoundedRectangle(cornerRadius: isNote ? 6 : 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: isNote ? 6 : 14, style: .continuous)
                    .strokeBorder(info.missing ? Theme.overdue : (selected ? tint : (isNote ? color.opacity(0.45) : Theme.border)),
                                  style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: info.missing ? [5, 4] : []))
            )
            .shadow(color: selected ? tint.opacity(0.25) : .black.opacity(hovering ? 0.12 : 0.06), radius: selected ? 10 : (hovering ? 9 : 5), y: 2)
            .overlay(alignment: .trailing) {
                // Drag this handle onto another box to connect them.
                Circle().fill(tint).frame(width: 14, height: 14)
                    .overlay(Image(systemName: "arrow.right").font(.system(size: 7.5, weight: .black)).foregroundStyle(.white))
                    .overlay(Circle().strokeBorder(Theme.card, lineWidth: 2))
                    .padding(8).contentShape(Rectangle())
                    .offset(x: 15)
                    .opacity(hovering || selected ? 1 : 0)
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
                        .onChanged { onLink($0.location) }
                        .onEnded { onLinkEnd($0.location) })
                    .help("Drag onto another box to connect")
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(count: 2) { onOpen() }
            .onTapGesture { onSelect() }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("canvas"))
                .onChanged { onSelect(); onDrag($0.translation) }
                .onEnded { onDragEnd($0.translation) })
            .onChange(of: editing) { _, on in focused = on }
            .onAppear { if editing { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true } } }
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
            .font(.system(size: 12.5)).lineLimit(5).multilineTextAlignment(.leading)
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
                            .foregroundStyle(info.title.isEmpty ? Theme.ink3 : Theme.ink).lineLimit(2)
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
