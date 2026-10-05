import SwiftUI
import Quartz
import QuickLookThumbnailing
import UniformTypeIdentifiers

struct QuickLookSurface: NSViewRepresentable {
    let url: URL
    func makeNSView(context: NSViewRepresentableContext<QuickLookSurface>) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ nsView: QLPreviewView, context: NSViewRepresentableContext<QuickLookSurface>) {
        if (nsView.previewItem as? NSURL) as URL? != url { nsView.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: ()) { nsView.close() }
}

struct QuickLookSheet: View {
    @Environment(\.dismiss) var dismiss
    let url: URL
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                Text(url.lastPathComponent).font(T.h3).lineLimit(1)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.softCompact)
                Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(.softCompact)
                Button("Done") { dismiss() }.buttonStyle(.primaryCompact).keyboardShortcut(.cancelAction)
            }.padding(14)
            Rectangle().fill(Theme.border).frame(height: 1)
            QuickLookSurface(url: url)
        }.frame(width: 780, height: 600)
    }
}

/// A Markdown file rendered as a document. Read only: the original file is never changed.
struct MarkdownFileView: View {
    let url: URL
    var baseSize: CGFloat = 15
    var padding: CGFloat = 24
    @State private var text: String?
    @State private var error: String?

    var body: some View {
        Group {
            if let text {
                ScrollView {
                    Group {
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("This file is empty.").font(T.body).foregroundStyle(Theme.ink3)
                        } else {
                            MarkdownDocumentView(source: text, baseSize: baseSize).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(padding)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            } else if let error {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text").font(.system(size: 26)).foregroundStyle(Theme.ink3)
                    Text(error).font(T.small).foregroundStyle(Theme.ink2).multilineTextAlignment(.center)
                    Button("Open in Its App") { NSWorkspace.shared.open(url) }.buttonStyle(.softCompact)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            text = nil; error = nil
            let url = url
            let result = await Task.detached(priority: .userInitiated) { Result { try MarkdownFile.load(url) } }.value
            switch result {
            case .success(let loaded): text = loaded
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}

/// A full-size reader for a Markdown file from a connected folder.
struct MarkdownReaderSheet: View {
    @Environment(\.dismiss) var dismiss
    let url: URL
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.richtext").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.ink2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent).font(T.h3).lineLimit(1)
                    Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(T.caption).foregroundStyle(Theme.ink3).lineLimit(1).truncationMode(.head)
                }
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.softCompact)
                Button("Open in Its App") { NSWorkspace.shared.open(url) }.buttonStyle(.softCompact)
                Button("Done") { dismiss() }.buttonStyle(.primaryCompact).keyboardShortcut(.cancelAction)
            }.padding(14)
            Rectangle().fill(Theme.border).frame(height: 1)
            MarkdownFileView(url: url, baseSize: 15, padding: 36).background(Theme.background)
        }.frame(minWidth: 760, idealWidth: 920, minHeight: 560, idealHeight: 760)
    }
}

/// A file's Quick Look thumbnail (works for images, PDFs, and most design files), falling back to its icon.
struct FileThumbnail: View {
    let url: URL
    var size: CGFloat = 96
    @State private var image: NSImage?
    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit().padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) { await load() }
    }

    func load() async {
        let key = "\(url.path)#\(Int(size))" as NSString
        if let cached = Self.cache.object(forKey: key) { image = cached; return }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return }
        Self.cache.setObject(representation.nsImage, forKey: key)
        image = representation.nsImage
    }
}

// MARK: - Files section

/// Connected folders, browsed right here. Files stay where they are; Context only reads them.
struct FilesSection: View {
    @EnvironmentObject var store: Store
    @Environment(\.pageTint) var tint
    let project: Project
    @State private var disconnecting: FolderConnection?

    var folders: [FolderConnection] { store.workspace.folders.filter { $0.projectID == project.id } }
    var selected: FolderConnection? { folders.first { $0.id == store.selectedFolder[project.id] } ?? folders.first }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(folders) { folder in folderChip(folder) }
                    }.padding(.vertical, 2)
                }
                Spacer(minLength: 8)
                Menu {
                    ForEach(FolderConnection.purposes, id: \.self) { purpose in
                        Button(purpose) { store.connectFolder(projectID: project.id, purpose: purpose) }
                    }
                } label: { MenuLabel(title: "Connect folder", icon: "plus", primary: true) } primaryAction: { store.connectFolder(projectID: project.id) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            .padding(.horizontal, 40).padding(.vertical, 12)
            Rectangle().fill(Theme.border).frame(height: 1)

            if let selected {
                FolderPane(folder: selected).id(selected.id)
            } else {
                EmptyState(icon: "folder.badge.plus", title: "Keep your working files one click away",
                           message: "Connect the folder where this project's design files, exports, or code live. They stay exactly where they are — Context only reads them and never copies, moves, or deletes anything.",
                           actionTitle: "Connect a Folder…") { store.connectFolder(projectID: project.id) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .confirmationDialog("Disconnect \(disconnecting?.name ?? "folder")?", isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } })) {
            Button("Disconnect", role: .destructive) { if let id = disconnecting?.id { store.disconnectFolder(id) }; disconnecting = nil }
        } message: { Text("Context forgets this folder. The folder and its files are not changed or deleted.") }
    }

    func folderChip(_ folder: FolderConnection) -> some View {
        let isSelected = folder.id == selected?.id
        return Button { store.selectedFolder[project.id] = folder.id } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").font(.system(size: 13)).foregroundStyle(isSelected ? tint : Theme.ink3)
                VStack(alignment: .leading, spacing: 0) {
                    Text(folder.name).font(.system(size: 13, weight: isSelected ? .semibold : .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    if !folder.purpose.isEmpty { Text(folder.purpose).font(.system(size: 11)).foregroundStyle(Theme.ink2) }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(isSelected ? tint.opacity(0.12) : Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isSelected ? tint.opacity(0.4) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Menu("Purpose") {
                ForEach(FolderConnection.purposes, id: \.self) { purpose in
                    Button(purpose) { var f = folder; f.purpose = purpose; store.upsert(f, in: \.folders) }
                }
            }
            Button("Reconnect…") { store.connectFolder(projectID: folder.projectID, replacing: folder.id) }
            Button("Copy Path") { copyToClipboard(folder.path) }
            Divider()
            Button("Disconnect…", role: .destructive) { disconnecting = folder }
        }
    }
}

struct FolderPane: View {
    @EnvironmentObject var store: Store
    @Environment(\.pageTint) var tint
    @Environment(\.present) var present
    let folder: FolderConnection
    @State private var path: [URL] = []
    @State private var items: [FileItem] = []
    @State private var limit = FolderListing.pageSize
    @State private var loading = false
    @State private var truncated = false
    @State private var error: String?
    @State private var preview: URL?
    @State private var filter = ""
    @AppStorage("filesAsGrid") private var grid = true

    var shown: [FileItem] { filter.isEmpty ? items : items.filter { $0.url.lastPathComponent.localizedCaseInsensitiveContains(filter) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                IconButton(icon: "chevron.left", help: "Back") { if path.count > 1 { path.removeLast() } }.disabled(path.count < 2).opacity(path.count < 2 ? 0.35 : 1)
                breadcrumbs
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                    TextField("Filter", text: $filter).textFieldStyle(.plain).font(T.small).frame(width: 120)
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
                Segmented(options: [(true, "", "square.grid.2x2"), (false, "", "list.bullet")], selection: $grid)
                IconButton(icon: "arrow.clockwise", help: "Reload") { Task { await load() } }
                Button { if let url = path.last { NSWorkspace.shared.open(url) } } label: { Label("Finder", systemImage: "arrow.up.forward.square") }.buttonStyle(.softCompact)
            }
            .padding(.horizontal, 40).padding(.vertical, 10)

            HStack(spacing: 0) {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let preview {
                    Rectangle().fill(Theme.border).frame(width: 1)
                    VStack(spacing: 0) {
                        HStack {
                            Text(preview.lastPathComponent).font(T.bodyMedium).lineLimit(1)
                            Spacer()
                            IconButton(icon: "xmark", help: "Close preview") { self.preview = nil }
                        }.padding(.horizontal, 14).padding(.vertical, 8)
                        if MarkdownFile.matches(preview) {
                            MarkdownFileView(url: preview, baseSize: 13, padding: 16).background(Theme.background)
                        } else {
                            QuickLookSurface(url: preview)
                        }
                        HStack {
                            if MarkdownFile.matches(preview) {
                                Button("Read") { present(.markdown(preview)) }.buttonStyle(.primaryCompact)
                                Button("Open in Its App") { NSWorkspace.shared.open(preview) }.buttonStyle(.softCompact)
                            } else {
                                Button("Open") { NSWorkspace.shared.open(preview) }.buttonStyle(.primaryCompact)
                            }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([preview]) }.buttonStyle(.softCompact)
                            Spacer()
                        }.padding(12)
                    }
                    .frame(width: 380).background(Theme.card)
                }
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack {
                Text(truncated ? "Showing the first \(items.count) items" : "\(items.count) items")
                if truncated { Button("Load more") { limit += FolderListing.pageSize; Task { await load() } }.buttonStyle(.softCompact) }
                Spacer()
                Text("Original files · read only · double-click opens in its app; Markdown opens here").foregroundStyle(Theme.ink3)
            }.font(T.caption).foregroundStyle(Theme.ink2).padding(.horizontal, 40).padding(.vertical, 8)
        }
        .task {
            switch store.status(of: folder) {
            case .available(let url): path = [url]
            case .unavailable(let message): error = message
            }
        }
        .task(id: path.last) { limit = FolderListing.pageSize; preview = nil; await load() }
    }

    var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(Array(path.enumerated()), id: \.offset) { index, url in
                    if index > 0 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.ink3) }
                    Button { path = Array(path.prefix(index + 1)) } label: {
                        Text(index == 0 ? folder.name : url.lastPathComponent)
                            .font(.system(size: 13.5, weight: index == path.count - 1 ? .semibold : .regular))
                            .foregroundStyle(index == path.count - 1 ? Theme.ink : Theme.ink2)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder var content: some View {
        if let error {
            VStack {
                EmptyState(icon: "folder.badge.questionmark", title: "Folder unavailable", message: error,
                           actionTitle: "Reconnect…") { store.connectFolder(projectID: folder.projectID, replacing: folder.id) }
            }
        } else if loading && items.isEmpty {
            ProgressView()
        } else if shown.isEmpty {
            EmptyState(icon: "folder", title: filter.isEmpty ? "This folder is empty" : "No matching items", message: "Hidden files are not shown.")
        } else if grid {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 124), spacing: 12, alignment: .top)], spacing: 14) {
                    ForEach(shown) { item in
                        VStack(spacing: 6) {
                            if item.isDirectory {
                                Image(nsImage: NSWorkspace.shared.icon(for: .folder)).resizable().scaledToFit().frame(width: 96, height: 96).padding(.horizontal, 4)
                            } else {
                                FileThumbnail(url: item.url, size: 96)
                            }
                            Text(item.url.lastPathComponent).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink)
                                .lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                            if !item.isDirectory {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)).font(.system(size: 11)).foregroundStyle(Theme.ink3)
                            }
                        }
                        .padding(8).frame(maxWidth: .infinity, alignment: .top)
                        .background(preview == item.url ? tint.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .modifier(FileInteraction(item: item, path: $path, preview: $preview))
                    }
                }.padding(.horizontal, 36).padding(.vertical, 16)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { item in
                        HStack(spacing: 11) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 24, height: 24)
                            Text(item.url.lastPathComponent).font(T.body).foregroundStyle(Theme.ink).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            if let modified = item.modified { Text(modified.formatted(date: .abbreviated, time: .omitted)).font(T.caption).foregroundStyle(Theme.ink3) }
                            Text(item.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                                .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.ink2).frame(width: 78, alignment: .trailing)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(preview == item.url ? tint.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .modifier(FileInteraction(item: item, path: $path, preview: $preview))
                    }
                }.padding(.horizontal, 30).padding(.vertical, 10)
            }
        }
    }

    func load() async {
        guard let url = path.last else { return }
        loading = true; error = nil
        let limit = self.limit
        do {
            let result = try await Task.detached(priority: .userInitiated) { try FolderListing.read(url, limit: limit) }.value
            guard !Task.isCancelled, path.last == url else { return }
            items = result.items; truncated = result.truncated; loading = false
        } catch {
            guard !Task.isCancelled, path.last == url else { return }
            self.error = error.localizedDescription; loading = false
        }
    }
}

/// Click a folder to enter it or a file to preview it; double-click a file to open it in its app,
/// except Markdown, which opens in Context's reader.
struct FileInteraction: ViewModifier {
    @Environment(\.present) var present
    let item: FileItem
    @Binding var path: [URL]
    @Binding var preview: URL?
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(count: 2) {
                if item.isDirectory { path.append(item.url) }
                else if MarkdownFile.matches(item.url) { present(.markdown(item.url)) }
                else { NSWorkspace.shared.open(item.url) }
            }
            .onTapGesture { if item.isDirectory { path.append(item.url) } else { preview = item.url } }
            .contextMenu {
                if !item.isDirectory && MarkdownFile.matches(item.url) {
                    Button("Read in Context") { present(.markdown(item.url)) }
                    Button("Open in Its App") { NSWorkspace.shared.open(item.url) }
                } else {
                    Button("Open") { NSWorkspace.shared.open(item.url) }
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                Button("Copy Path") { copyToClipboard(item.url.path) }
            }
    }
}
