import Foundation
import UniformTypeIdentifiers

enum FileCategory: String, CaseIterable, Identifiable, Comparable, Hashable {
    case images
    case videos
    case audio
    case documents
    case archives
    case code
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .images: return "Images"
        case .videos: return "Videos"
        case .audio: return "Audio"
        case .documents: return "Documents"
        case .archives: return "Archives"
        case .code: return "Code"
        case .other: return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .images: return "photo.on.rectangle"
        case .videos: return "video"
        case .audio: return "waveform"
        case .documents: return "doc.text"
        case .archives: return "archivebox"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .other: return "questionmark.folder"
        }
    }

    /// Sort order used when displaying the category grid.
    private var sortRank: Int {
        switch self {
        case .images: return 0
        case .videos: return 1
        case .audio: return 2
        case .documents: return 3
        case .archives: return 4
        case .code: return 5
        case .other: return 6
        }
    }

    static func < (lhs: FileCategory, rhs: FileCategory) -> Bool {
        lhs.sortRank < rhs.sortRank
    }

    /// Classifies a file by extension, using UTType conformance where possible
    /// and falling back to a curated extension list for types UTType doesn't
    /// resolve on-device (e.g. some Office/archive formats).
    static func classify(extension ext: String) -> FileCategory {
        let lowerExt = ext.lowercased()

        if let type = UTType(filenameExtension: lowerExt) {
            if type.conforms(to: .image) { return .images }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .videos }
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .archive) || type.conforms(to: .zip) { return .archives }
            if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return .code }
            if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .rtf)
                || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet) {
                return .documents
            }
        }

        if Self.documentExtensions.contains(lowerExt) { return .documents }
        if Self.archiveExtensions.contains(lowerExt) { return .archives }
        if Self.codeExtensions.contains(lowerExt) { return .code }

        return .other
    }

    private static let documentExtensions: Set<String> = [
        "doc", "docx", "ppt", "pptx", "xls", "xlsx", "pages", "numbers", "key", "epub", "csv"
    ]
    private static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "bz2"]
    private static let codeExtensions: Set<String> = [
        "swift", "m", "h", "c", "cpp", "py", "js", "ts", "json", "yml", "yaml", "html", "css", "sh"
    ]
}
