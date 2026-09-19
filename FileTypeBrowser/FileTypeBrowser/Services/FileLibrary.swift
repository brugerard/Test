import Foundation

/// Top-level observable store: owns the list of granted folders and the
/// most recent scan results, grouped by category.
@MainActor
final class FileLibrary: ObservableObject {
    @Published private(set) var groupedItems: [FileCategory: [FileItem]] = [:]
    @Published private(set) var sources: [BookmarkStore.AccessibleFolder] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScanDate: Date?

    var totalFileCount: Int { groupedItems.values.reduce(0) { $0 + $1.count } }

    func items(for category: FileCategory) -> [FileItem] {
        groupedItems[category] ?? []
    }

    func count(for category: FileCategory) -> Int {
        groupedItems[category]?.count ?? 0
    }

    func addFolder(url: URL) {
        BookmarkStore.shared.addBookmark(for: url)
        Task { await refresh() }
    }

    func removeSource(id: String) {
        BookmarkStore.shared.removeBookmark(id: id)
        Task { await refresh() }
    }

    func refresh() async {
        isScanning = true
        defer { isScanning = false }

        let folders = BookmarkStore.shared.resolveAll()
        sources = folders

        var roots = folders.map { FileScanner.ScanRoot(url: $0.url, sourceName: $0.displayName) }
        if let appRoot = FileScanner.appDocumentsRoot {
            roots.append(appRoot)
        }

        groupedItems = await FileScanner.scan(roots: roots)
        lastScanDate = Date()
    }
}
