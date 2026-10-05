import SwiftUI

/// Planned posts with per-platform completion. Social accounts themselves live in Links.
struct PostsPanel: View {
    @EnvironmentObject var store: Store
    @Environment(\.present) var present
    let project: Project
    @State private var showPublished = false

    var accounts: [Entry] { store.workspace.entries.filter { $0.projectID == project.id && $0.kind == .social } }
    var items: [ContentItem] { store.workspace.contentItems.filter { $0.projectID == project.id } }

    var body: some View {
        let pending = items.filter { !$0.isComplete }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        let published = items.filter(\.isComplete).sorted { $0.updatedAt > $1.updatedAt }
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Text("Posting is manual: open each platform, publish, then tick it off here. Each platform is tracked separately.")
                    .font(T.small).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                Button { present(.content(newPost())) } label: { Label("Plan a Post", systemImage: "plus") }.buttonStyle(.primary)
            }
            if pending.isEmpty {
                Card { EmptyState(icon: "paperplane", title: "Nothing queued", message: "Plan a post with its caption, source images, and the platforms it goes to.", compact: true) }
            } else {
                ForEach(pending) { PostCard(item: $0, accounts: accounts) }
            }
            if !published.isEmpty {
                DisclosureGroup(isExpanded: $showPublished) {
                    VStack(spacing: 10) { ForEach(published) { PostCard(item: $0, accounts: accounts) } }.padding(.top, 8)
                } label: { SectionHeader(title: "Published", count: published.count) }
            }
        }
    }

    func newPost() -> ContentItem {
        let platforms = accounts.map { $0.category.isEmpty ? (BrandCatalog.brand(for: $0)?.name ?? $0.title) : $0.category }.filter { !$0.isEmpty }
        var item = ContentItem(projectID: project.id)
        item.targets = Array(Set(platforms)).sorted().map { PostTarget(platform: $0) }
        return item
    }
}

struct PostCard: View {
    @EnvironmentObject var store: Store
    @Environment(\.present) var present
    let item: ContentItem
    let accounts: [Entry]

    func account(for platform: String) -> Entry? {
        let brand = BrandCatalog.named(platform)
        return accounts.first { account in
            account.category.caseInsensitiveCompare(platform) == .orderedSame
                || (brand != nil && BrandCatalog.brand(for: account) == brand)
                || account.title.localizedCaseInsensitiveContains(platform)
        }
    }

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title.isEmpty ? "Untitled post" : item.title).font(.system(size: 14, weight: .semibold))
                        if !item.caption.isEmpty { Text(item.caption).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer()
                    if let due = item.due {
                        let label = DueText.describe(due, now: store.clock)
                        Text(item.isComplete ? "Published" : label.text).font(.caption.weight(.medium)).foregroundStyle(item.isComplete ? Theme.accent : label.color)
                    }
                    Button { present(.content(item)) } label: { Image(systemName: "pencil") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Edit post")
                }
                if !item.assets.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(item.assets.prefix(4), id: \.self) { path in
                            let url = URL(fileURLWithPath: path)
                            Button { present(.quickLook(url)) } label: {
                                Label(url.lastPathComponent, systemImage: FileManager.default.fileExists(atPath: path) ? "photo" : "photo.badge.exclamationmark")
                                    .font(.caption).lineLimit(1)
                            }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        if item.assets.count > 4 { Text("+\(item.assets.count - 4)").font(.caption).foregroundStyle(.tertiary) }
                    }
                }
                if item.targets.isEmpty {
                    Text("No platforms selected. Edit the post to add where it goes.").font(.caption).foregroundStyle(Theme.today)
                } else {
                    FlowLayout(spacing: 8) {
                        ForEach(item.targets) { target in
                            HStack(spacing: 7) {
                                Button { store.togglePlatform(item, target: target.id) } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: target.isDone ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(target.isDone ? Theme.accent : .secondary)
                                        PlatformIcon(platform: target.platform, size: 18)
                                        Text(target.platform).strikethrough(target.isDone).foregroundStyle(target.isDone ? .secondary : .primary)
                                    }
                                }.buttonStyle(.plain).help(target.isDone ? "Posted \(target.completedAt!.formatted(date: .abbreviated, time: .shortened)) — click to undo" : "Mark \(target.platform) as posted")
                                if let account = account(for: target.platform), let url = webURL(account.managementURL) ?? webURL(account.url) {
                                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right").font(.caption2) }
                                        .buttonStyle(.plain).foregroundStyle(Theme.accent).help("Open \(account.title)")
                                }
                            }
                            .font(.callout)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(target.isDone ? Theme.accent.opacity(0.1) : Color.primary.opacity(0.04), in: Capsule())
                        }
                    }
                }
            }
        }
    }
}
