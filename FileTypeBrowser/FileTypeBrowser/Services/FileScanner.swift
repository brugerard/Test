import Foundation

/// Recursively scans a set of root folders and classifies every file found
/// by type. Runs off the main thread; results are handed back already
/// grouped by category.
enum FileScanner {
    struct ScanRoot {
        let url: URL
        let sourceName: String
    }

    static func scan(roots: [ScanRoot]) async -> [FileCategory: [FileItem]] {
        await Task.detached(priority: .userInitiated) {
            var items: [FileItem] = []
            let fileManager = FileManager.default
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]

            for root in roots {
                guard let enumerator = fileManager.enumerator(
                    at: root.url,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }

                for case let fileURL as URL in enumerator {
                    guard let values = try? fileURL.resourceValues(forKeys: Set(keys)) else { continue }
                    if values.isDirectory == true { continue }

                    let category = FileCategory.classify(extension: fileURL.pathExtension)
                    let item = FileItem(
                        url: fileURL,
                        name: fileURL.lastPathComponent,
                        category: category,
                        size: Int64(values.fileSize ?? 0),
                        modifiedDate: values.contentModificationDate,
                        sourceName: root.sourceName
                    )
                    items.append(item)
                }
            }

            return Dictionary(grouping: items, by: { $0.category })
        }.value
    }

    /// The app's own sandboxed Documents folder. Because `UIFileSharingEnabled`
    /// and `LSSupportsOpeningDocumentsInPlace` are set in Info.plist, this
    /// folder shows up as "On My iPhone > FileTypeBrowser" in the Files app,
    /// so the user can drop real files into it from anywhere on the device.
    static var appDocumentsRoot: ScanRoot? {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return ScanRoot(url: url, sourceName: "This App")
    }
}
