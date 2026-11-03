import SwiftUI
import UniformTypeIdentifiers

/// A project: a compact header, then its map (with its links) or its reminders.
struct ProjectView: View {
    @EnvironmentObject var store: Store
    @Environment(\.present) var present
    @ObservedObject private var reminders = RemindersService.shared
    let project: Project
    @State private var dropTargeted = false

    var tint: Color { Theme.color(project.color) }
    var tab: ProjectTab { store.lastSection[project.id] ?? .map }
    func select(_ tab: ProjectTab) { store.lastSection[project.id] = tab }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)
            Group {
                switch tab {
                case .map: DiagramSection(project: project)
                case .reminders: RemindersSection(project: project)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { store.markOpened(project.id) }
    }

    var header: some View {
        HStack(spacing: 12) {
            picture
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name).font(.system(size: 19, weight: .bold)).foregroundStyle(Theme.ink).lineLimit(1)
                if !project.summary.isEmpty {
                    Text(project.summary).font(T.caption).foregroundStyle(Theme.ink2).lineLimit(1)
                }
            }
            .frame(maxWidth: 360, alignment: .leading)
            Spacer(minLength: 16)
            tabs
            Spacer(minLength: 16)
            IconButton(icon: "slider.horizontal.3", help: "Project settings", size: 30) { present(.project(project)) }
        }
        .padding(.leading, 24).padding(.trailing, 18).padding(.top, 30).padding(.bottom, 12)
        .background(alignment: .top) {
            LinearGradient(colors: [tint.opacity(0.12), tint.opacity(0.0)], startPoint: .top, endPoint: .bottom)
        }
    }

    /// The project picture. Click or drop an image on it to change it.
    var picture: some View {
        Button { choosePicture() } label: {
            ProjectIcon(project: project, size: 40)
                .overlay {
                    if dropTargeted {
                        RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(tint, lineWidth: 2.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(project.image == nil ? "Add a picture or logo (click, or drop an image here)" : "Change the picture (click, or drop an image here)")
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, let data = ProjectImage.prepare(contentsOf: url) else { return false }
            setPicture(data)
            return true
        } isTargeted: { dropTargeted = $0 }
        .contextMenu {
            Button("Choose Picture…") { choosePicture() }
            if project.image != nil { Button("Remove Picture") { setPicture(nil) } }
        }
    }

    func choosePicture() { if let data = ProjectImage.choose() { setPicture(data) } }

    func setPicture(_ data: Data?) {
        var updated = project
        updated.image = data
        store.saveQuietly(updated)
    }

    var tabs: some View {
        HStack(spacing: 2) {
            ForEach(ProjectTab.allCases) { item in
                let selected = tab == item
                Button { select(item) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.icon).font(.system(size: 11.5, weight: .semibold))
                        Text(item.rawValue).font(.system(size: 13, weight: selected ? .semibold : .medium))
                        if let count = badge(item), count > 0 {
                            Text("\(count)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(item == .reminders && attention > 0 ? Theme.overdue : (selected ? tint : Theme.ink3))
                        }
                    }
                    .foregroundStyle(selected ? Theme.ink : Theme.ink2)
                    .padding(.horizontal, 13).padding(.vertical, 6)
                    .background(selected ? Theme.card : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 2, y: 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(item.rawValue) (⌘\(ProjectTab.allCases.firstIndex(of: item)! + 1))")
            }
        }
        .padding(3)
        .background(Theme.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    var attention: Int { reminders.attentionCount(for: project, now: store.clock) }

    func badge(_ tab: ProjectTab) -> Int? {
        switch tab {
        case .map: return nil
        case .reminders: return attention > 0 ? attention : reminders.items(for: project).filter { !$0.isCompleted }.count
        }
    }
}
