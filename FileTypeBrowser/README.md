# FileTypeBrowser

A SwiftUI iOS app that lists files on your iPhone grouped by type (Images,
Videos, Audio, Documents, Archives, Code, Other), with search, sorting,
QuickLook preview, and sharing.

## Why this app can't "just" list every file on the phone

iOS sandboxes every app — there is no API, even with the user's permission,
that hands an app the whole device filesystem. Apple only allows two
sanctioned ways to see files outside an app's own sandbox:

1. **The system document picker** (`UIDocumentPickerViewController`), which
   lets the user explicitly pick a folder — "On My iPhone", an iCloud Drive
   folder, or a folder from any other Files-app provider (Dropbox, Google
   Drive, etc.) — and grants the app a security-scoped bookmark to that
   folder specifically.
2. **The app's own Documents folder**, which — because this app sets
   `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` — shows up
   in the Files app under **On My iPhone › FileTypeBrowser**, so you can
   drag files into it from anywhere and the app will see them.

This app uses both. Tap the folder-plus icon to grant access to additional
folders; anything you copy into "On My iPhone › FileTypeBrowser" via the
Files app also gets scanned automatically. Photos-library assets aren't
included — those live in Apple's Photos database, not as loose files, and
would need a separate PhotoKit-based feature.

## Project layout

```
FileTypeBrowser.xcodeproj/       Xcode project (iOS 16+, SwiftUI, Swift 5)
FileTypeBrowser/
  FileTypeBrowserApp.swift       App entry point
  Models/
    FileCategory.swift           Type classification (by UTType + extension)
    FileItem.swift                Scanned-file model
  Services/
    BookmarkStore.swift           Persists security-scoped folder bookmarks
    FileScanner.swift             Recursive folder scan → [FileCategory: [FileItem]]
    FileLibrary.swift             ObservableObject tying scanning + bookmarks together
  Views/
    RootView.swift                Category grid, add-folder / manage-sources UI
    CategoryFilesView.swift       Per-category file list: search, sort, swipe-to-share
    DocumentPicker.swift          Wraps UIDocumentPickerViewController
    QuickLookPreview.swift        Tap a file to preview it (QuickLook)
    ShareSheet.swift              Share/export a file
  Assets.xcassets/                App icon + accent color placeholders
```

## Building and running

You need a Mac with Xcode 15+ (iOS 16 SDK or later).

1. Open `FileTypeBrowser.xcodeproj` in Xcode.
2. Select the `FileTypeBrowser` target, go to **Signing & Capabilities**,
   and set your own Team (Apple ID) so Xcode can code-sign the app. Change
   the bundle identifier (`com.brugerard.filetypebrowser`) if it collides
   with one you already have.
3. Plug in your iPhone (or pick a simulator), select it as the run
   destination, and press **Run** (⌘R).
4. On first run to a physical device: on the iPhone go to
   **Settings › General › VPN & Device Management** and trust your
   developer certificate.

## Using it

- The category grid on launch shows file counts per type.
- Tap **+** (folder-plus, top right) to grant access to a folder via the
  Files picker — e.g. "On My iPhone", or an iCloud Drive folder.
- Tap the gear/folder icon (top left) to see and remove granted folders.
- Pull to refresh to rescan.
- Tap a file to preview it; swipe left on a row to share/export it.
- Files placed in **On My iPhone › FileTypeBrowser** (via the Files app)
  show up automatically, no picker needed.
