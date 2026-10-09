import AppKit
import SwiftUI

/// Engine file indexes, unlike decoded UUIDs, remain stable across refreshes.
nonisolated struct DownloadFileTableRow: Identifiable {
    let file: DownloadFile
    let name: String
    var id: Int { file.index }
    var size: Int64 { file.length }
    var progress: Double { file.progress }
    static func rows(_ files: [DownloadFile], directory: String) -> [Self] {
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        return files.map { file in
            Self(file: file, name: file.path.hasPrefix(prefix) ? String(file.path.dropFirst(prefix.count)) : URL(fileURLWithPath: file.path).lastPathComponent)
        }
    }
}

struct DownloadFilesTable: View {
    let files: [DownloadFile]
    let directory: String
    var priorities: Binding<[Int: TorrentFilePriority]>?
    @State private var width: CGFloat = 440
    @State private var selection: Set<Int> = []
    @State private var search = ""
    @State private var sort = [KeyPathComparator(\DownloadFileTableRow.name, comparator: .localizedStandard)]
    private var rows: [DownloadFileTableRow] {
        DownloadFileTableRow.rows(files, directory: directory)
            .filter { search.isEmpty || $0.name.localizedStandardContains(search) }.sorted(using: sort)
    }
    private var selectedFiles: [DownloadFile] { files.filter { selection.contains($0.index) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NativeSearchField(text: $search, move: { _ in }, submit: {}, dismiss: { search = "" },
                              prompt: String(localized: "Filter files"), focusOnAppear: false, size: .regular)
                .frame(height: 26)
            Table(rows, selection: $selection, sortOrder: $sort) {
                TableColumn(String(localized: "Name"), value: \.name) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(row.name, systemImage: row.file.isSelected ? "doc" : "minus.circle")
                            .lineLimit(1).truncationMode(.middle).help(row.name)
                        if let priorities {
                            Text((priorities.wrappedValue[row.id] ?? .normal).title).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.width(max(80, width - 200))
                TableColumn(String(localized: "Size"), value: \.size) { row in
                    Text(ByteFormat.size(row.size)).monospacedDigit()
                }.width(68)
                TableColumn(String(localized: "Progress"), value: \.progress) { row in
                    Text(row.file.isSelected ? row.progress.formatted(.percent.precision(.fractionLength(0))) : String(localized: "Skip"))
                        .foregroundStyle(row.file.isSelected ? .primary : .secondary).monospacedDigit()
                }.width(68)
            }
            .frame(height: min(300, max(100, CGFloat(rows.count) * (priorities == nil ? 28 : 42) + 30)))
            .contextMenu(forSelectionType: Int.self) { ids in
                Button(String(localized: "Show in Finder"), systemImage: "folder") { reveal(ids) }
                    .disabled(!files.contains { ids.contains($0.index) && DownloadFileLocation.existingFile($0.path) != nil })
                if priorities != nil { priorityMenu(ids) }
            }
            .accessibilityLabel(String(localized: "Download files"))
            HStack {
                Text(String(localized: "\(selection.count) selected")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if priorities != nil { priorityMenu(selection) }
                Button(String(localized: "Show in Finder"), systemImage: "folder") { reveal(selection) }
                    .disabled(!selectedFiles.contains { DownloadFileLocation.existingFile($0.path) != nil })
            }.controlSize(.small)
            if selectedFiles.count == 1, let file = selectedFiles.first {
                VStack(alignment: .leading, spacing: 8) {
                    Text(DownloadFileTableRow.rows([file], directory: directory)[0].name)
                        .font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if let priorities {
                        Picker(String(localized: "Priority"), selection: Binding(
                            get: { priorities.wrappedValue[file.index] ?? .normal },
                            set: { priorities.wrappedValue[file.index] = $0 })) {
                            ForEach(TorrentFilePriority.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.menu)
                        if (priorities.wrappedValue[file.index] != .off) != file.isSelected {
                            Label(String(localized: "Selection change not applied"), systemImage: "clock").font(.caption)
                        }
                    }
                    DownloadFileProgressView(file: file)
                    if file.isCompleteOnDisk {
                        DownloadedFileActions(file: file)
                        FileVerificationView(file: file).id(file.index)
                    }
                }.padding(.top, 4)
            }
            if rows.isEmpty { Text("No matching files").foregroundStyle(.secondary) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: rows.map(\.id), initial: true) { _, ids in
            selection.formIntersection(ids)
            if files.count == 1, let id = ids.first { selection = [id] }
        }
    }
    private func reveal(_ ids: Set<Int>) {
        NSWorkspace.shared.activateFileViewerSelecting(files.filter { ids.contains($0.index) }.compactMap { DownloadFileLocation.existingFile($0.path) })
    }
    private func priorityMenu(_ ids: Set<Int>) -> some View {
        Menu(String(localized: "Set Priority")) {
            ForEach(TorrentFilePriority.allCases) { priority in
                Button(priority.title) {
                    guard let priorities else { return }
                    for id in ids where files.contains(where: { $0.index == id }) { priorities.wrappedValue[id] = priority }
                }
            }
        }.disabled(ids.isEmpty)
    }
}
