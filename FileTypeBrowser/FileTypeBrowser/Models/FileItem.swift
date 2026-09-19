import Foundation

struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let category: FileCategory
    let size: Int64
    let modifiedDate: Date?
    /// Display name of the top-level source this file was scanned from
    /// (e.g. "On My iPhone", "iCloud Drive", or the app's own folder).
    let sourceName: String

    var id: URL { url }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}
