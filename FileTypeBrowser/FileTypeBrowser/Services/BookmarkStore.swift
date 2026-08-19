import Foundation

/// Persists security-scoped bookmarks for folders the user has granted access
/// to via the system document picker, so the app can re-open them on future
/// launches without prompting again.
final class BookmarkStore {
    static let shared = BookmarkStore()

    private let defaultsKey = "com.filetypebrowser.folderBookmarks"
    private var defaults: UserDefaults { .standard }

    struct AccessibleFolder: Identifiable {
        let id: String
        let url: URL
        let displayName: String
    }

    /// Currently-resolved folders. Call `resolveAll()` first to populate.
    private(set) var accessibleFolders: [AccessibleFolder] = []

    func addBookmark(for url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            var stored = rawBookmarks()
            stored[url.lastPathComponent + "-" + UUID().uuidString] = data
            defaults.set(stored, forKey: defaultsKey)
        } catch {
            print("Failed to create bookmark for \(url): \(error)")
        }
    }

    func removeBookmark(id: String) {
        var stored = rawBookmarks()
        stored.removeValue(forKey: id)
        defaults.set(stored, forKey: defaultsKey)
        accessibleFolders.removeAll { $0.id == id }
    }

    /// Resolves all stored bookmarks into accessible URLs, starting
    /// security-scoped access for each. Call `stopAccessingAll()` when done
    /// scanning if you want to release access immediately (otherwise it is
    /// released on the next resolve or app termination).
    @discardableResult
    func resolveAll() -> [AccessibleFolder] {
        var stored = rawBookmarks()
        var resolved: [AccessibleFolder] = []
        var changed = false

        for (id, data) in stored {
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                guard url.startAccessingSecurityScopedResource() else { continue }
                resolved.append(AccessibleFolder(id: id, url: url, displayName: url.lastPathComponent))

                if isStale, let refreshed = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    stored[id] = refreshed
                    changed = true
                }
            } catch {
                stored.removeValue(forKey: id)
                changed = true
            }
        }

        if changed {
            defaults.set(stored, forKey: defaultsKey)
        }

        accessibleFolders = resolved
        return resolved
    }

    func stopAccessingAll() {
        for folder in accessibleFolders {
            folder.url.stopAccessingSecurityScopedResource()
        }
    }

    private func rawBookmarks() -> [String: Data] {
        defaults.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    }
}
