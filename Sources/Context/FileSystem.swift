import Foundation

struct FileItem: Identifiable {
    var id: String { url.path }
    let url: URL
    let isDirectory: Bool
    let size: Int
    let modified: Date?
}

struct FolderListing {
    static let pageSize = 500
    let items: [FileItem]
    let truncated: Bool

    /// Lists immediate, non-hidden children only. Never recurses and never modifies the folder.
    static func read(_ url: URL, limit: Int = pageSize) throws -> FolderListing {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isPackageKey, .contentModificationDateKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw WorkspaceError.invalid("This folder could not be read.")
        }
        var items: [FileItem] = []
        var truncated = false
        while let child = enumerator.nextObject() as? URL {
            if items.count == limit { truncated = true; break }
            let info = try child.resourceValues(forKeys: Set(keys))
            items.append(FileItem(url: child, isDirectory: info.isDirectory == true && info.isPackage != true,
                                  size: info.fileSize ?? 0, modified: info.contentModificationDate))
        }
        if let enumerationError { throw enumerationError }
        return FolderListing(items: items.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }, truncated: truncated)
    }
}

enum FolderStatus: Equatable {
    case available(URL)
    case unavailable(String)
}

/// Resolves a saved bookmark without prompting. Returns the refreshed bookmark when the folder moved.
func resolveFolder(_ folder: FolderConnection) -> (status: FolderStatus, refreshed: FolderConnection?) {
    var stale = false
    guard let url = try? URL(resolvingBookmarkData: folder.bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) else {
        return (.unavailable("The saved location can no longer be found. It may have been deleted, renamed on another volume, or its disk is disconnected."), nil)
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        return (.unavailable("This folder is unavailable. Reconnect it if it moved or its volume is disconnected."), nil)
    }
    guard FileManager.default.isReadableFile(atPath: url.path) else {
        return (.unavailable("Context does not have permission to read this folder. Reconnect it to grant access."), nil)
    }
    var refreshed: FolderConnection?
    if stale || folder.path != url.path, let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
        var updated = folder
        updated.path = url.path
        updated.bookmark = data
        refreshed = updated
    }
    return (.available(url), refreshed)
}

/// Markdown files open in Context's own reader instead of another app.
enum MarkdownFile {
    static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn"]
    /// Larger files are left to their own app; the reader renders the whole document at once.
    static let sizeLimit = 2_000_000

    static func matches(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    static func load(_ url: URL) throws -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= sizeLimit else { throw ReadError.tooLarge }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw ReadError.unreadable }
        return withoutFrontMatter(text)
    }

    /// Drops a leading YAML front-matter block (`---` … `---`), which static-site tools put at the top of Markdown files.
    static func withoutFrontMatter(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return text }
        return lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    enum ReadError: LocalizedError {
        case tooLarge, unreadable
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "This file is too large to read here. Open it in its app instead."
            case .unreadable: return "This file isn't readable text."
            }
        }
    }
}
