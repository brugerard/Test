import SwiftUI

struct RootView: View {
    @StateObject private var library = FileLibrary()
    @State private var showingPicker = false
    @State private var showingSources = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if library.totalFileCount == 0 && !library.isScanning {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(FileCategory.allCases.sorted()) { category in
                            NavigationLink(value: category) {
                                CategoryTile(
                                    category: category,
                                    count: library.count(for: category)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("My Files")
            .navigationDestination(for: FileCategory.self) { category in
                CategoryFilesView(category: category, items: library.items(for: category))
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showingSources = true
                    } label: {
                        Image(systemName: "folder.badge.gearshape")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingPicker = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                }
            }
            .refreshable {
                await library.refresh()
            }
            .sheet(isPresented: $showingPicker) {
                DocumentPicker { url in
                    library.addFolder(url: url)
                }
            }
            .sheet(isPresented: $showingSources) {
                SourcesView(library: library)
            }
            .overlay {
                if library.isScanning {
                    ProgressView("Scanning…")
                        .padding()
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .task {
            await library.refresh()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No files found yet")
                .font(.headline)
            Text("Tap the folder icon to grant access to a folder on your iPhone (On My iPhone, iCloud Drive, etc.), or add files to \"On My iPhone \u{203A} FileTypeBrowser\" in the Files app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                showingPicker = true
            } label: {
                Label("Add a Folder", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .padding(.top, 80)
    }
}

private struct CategoryTile: View {
    let category: FileCategory
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: category.systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
            Text(category.displayName)
                .font(.headline)
                .foregroundStyle(.primary)
            Text("\(count) file\(count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct SourcesView: View {
    @ObservedObject var library: FileLibrary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("This App's Folder") {
                    Label("On My iPhone \u{203A} FileTypeBrowser", systemImage: "app.badge")
                        .foregroundStyle(.secondary)
                }
                Section("Granted Folders") {
                    if library.sources.isEmpty {
                        Text("No folders added yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(library.sources, id: \.id) { source in
                            Label(source.displayName, systemImage: "folder")
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                library.removeSource(id: library.sources[index].id)
                            }
                        }
                    }
                }
                Section {
                    Text("Made by Bruno Gerard")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Sources")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    RootView()
}
