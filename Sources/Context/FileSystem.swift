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
