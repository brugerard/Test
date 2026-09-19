import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Wraps UIDocumentPickerViewController so the user can grant access to a
/// folder living outside the app's sandbox — "On My iPhone", iCloud Drive,
/// or any other Files-app location (Dropbox, Google Drive, etc.). This is
/// the only Apple-sanctioned way for a sandboxed app to browse folders it
/// doesn't own.
struct DocumentPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            urls.forEach(onPick)
        }
    }
}
