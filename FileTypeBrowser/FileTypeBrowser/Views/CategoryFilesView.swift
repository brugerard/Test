import SwiftUI

struct CategoryFilesView: View {
    let category: FileCategory
    let items: [FileItem]

    @State private var searchText = ""
    @State private var sortOption: SortOption = .name
    @State private var previewURL: URL?
    @State private var shareURL: URL?

    private enum SortOption: String, CaseIterable, Identifiable {
        case name = "Name"
        case date = "Date"
        case size = "Size"
        var id: String { rawValue }
    }

    private var filteredAndSorted: [FileItem] {
        let filtered = searchText.isEmpty
            ? items
            : items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }

        switch sortOption {
        case .name:
            return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .date:
            return filtered.sorted { ($0.modifiedDate ?? .distantPast) > ($1.modifiedDate ?? .distantPast) }
        case .size:
            return filtered.sorted { $0.size > $1.size }
        }
    }

    var body: some View {
        List(filteredAndSorted) { item in
            Button {
                previewURL = item.url
            } label: {
                FileRow(item: item)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing) {
                Button {
                    shareURL = item.url
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .tint(.blue)
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "Search \(category.displayName.lowercased())")
        .navigationTitle(category.displayName)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Picker("Sort", selection: $sortOption) {
                    ForEach(SortOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .overlay {
            if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: category.systemImage)
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No \(category.displayName)")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: previewPresented) {
            if let previewURL {
                QuickLookPreview(url: previewURL)
            }
        }
        .sheet(isPresented: sharePresented) {
            if let shareURL {
                ShareSheet(url: shareURL)
            }
        }
    }

    private var previewPresented: Binding<Bool> {
        Binding(get: { previewURL != nil }, set: { if !$0 { previewURL = nil } })
    }

    private var sharePresented: Binding<Bool> {
        Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })
    }
}

private struct FileRow: View {
    let item: FileItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.category.systemImage)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.sourceName)
                    if let date = item.modifiedDate {
                        Text("\u{00B7}")
                        Text(date, style: .date)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(formattedSize)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
    }
}

#Preview {
    NavigationStack {
        CategoryFilesView(category: .images, items: [])
    }
}
