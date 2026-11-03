import SwiftUI
import UniformTypeIdentifiers

/// A project: a compact header with its reminders, then its map (links and reminders live on the map's boxes).
struct ProjectView: View {
    @EnvironmentObject var store: Store
    @Environment(\.present) var present
    @ObservedObject private var reminders = RemindersService.shared
    let project: Project
    @State private var dropTargeted = false
    @State private var showingReminders = false

    var tint: Color { Theme.color(project.color) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)
            DiagramSection(project: project)
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
            remindersButton
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

    /// All of the project's reminders at a glance: a count (red when something is due), and the list by box.
    var remindersButton: some View {
        let open = reminders.items(for: project).filter { !$0.isCompleted }.count
        return Button { showingReminders = true } label: {
            HStack(spacing: 6) {
                Image(systemName: attention > 0 ? "bell.badge.fill" : "bell").font(.system(size: 12, weight: .semibold))
                Text("Reminders").font(.system(size: 13, weight: .medium))
                if attention > 0 || open > 0 {
                    Text("\(attention > 0 ? attention : open)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(attention > 0 ? Theme.overdue : Theme.ink3)
                }
            }
            .foregroundStyle(attention > 0 ? Theme.overdue : Theme.ink2)
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(Theme.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(attention > 0 ? "\(attention) due · all of this project's reminders" : "All of this project's reminders, by box")
        .popover(isPresented: $showingReminders, arrowEdge: .bottom) {
            ProjectRemindersPanel(project: project, showBox: { id in
                showingReminders = false
                NotificationCenter.default.post(name: .contextShowBox, object: id)
            })
            .environmentObject(store).environment(\.pageTint, tint)
        }
    }

    var attention: Int { reminders.attentionCount(for: project, now: store.clock) }
}
