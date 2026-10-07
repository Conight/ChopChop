import AppKit
import SwiftUI

struct AddDownloadPanel: View {
    @EnvironmentObject private var store: DownloadStore
    @State private var isShowingAdvanced: Bool
    @State private var contentHeight: CGFloat = 230
    @State private var submissionError: UserFacingAlert?
    @State private var isSubmitting = false
    @FocusState private var linksAreFocused: Bool
    var onDismiss: () -> Void

    init(initiallyShowsAdvanced: Bool = false, onDismiss: @escaping () -> Void) {
        _isShowingAdvanced = State(initialValue: initiallyShowsAdvanced)
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add Download")
                        .font(.title3.weight(.semibold))
                        .accessibilityIdentifier("add-download-title")
                    Text("Paste a link, or add several links on separate lines.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    linksInput
                    saveLocation
                    if let session = store.bitTorrentSelectionSession {
                        BitTorrentFileSelectionView(session: session)
                    }
                    DisclosureGroup("Advanced Options", isExpanded: $isShowingAdvanced) {
                        AddDownloadOptions()
                            // AppKit draws field bezels and focus rings outside their layout bounds.
                            // Keep them inside the disclosure group's clipping/animation container.
                            .padding(6)
                            .padding(.top, 14)
                            .disabled(isSubmitting || store.bitTorrentSelectionSession != nil)
                    }
                    .accessibilityIdentifier("add-download-advanced-toggle")
                    if let error = submissionError {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(error.title, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout.weight(.medium))
                                .symbolRenderingMode(.multicolor)
                            Text(error.message).font(.callout).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("add-download-error")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(2) // Keep native focus rings inside the scroll view's clipping bounds.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(minHeight: 0, idealHeight: min(contentHeight, 420), maxHeight: min(contentHeight, 420))

            footer
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 560, maxWidth: 560)
        .presentationSizing(.fitted)
        .background(Color(nsColor: .windowBackgroundColor))
        .defaultFocus($linksAreFocused, true)
        .onChange(of: store.addDraft.rawInput) { _, _ in submissionError = nil }
        .onReceive(store.userAlerts) { alert in
            guard store.claimAlert(alert) else { return }
            submissionError = alert
        }
        .interactiveDismissDisabled(isSubmitting && !store.isResolvingBitTorrentFiles)
    }

    private var linksInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Download links").font(.callout.weight(.medium))
                Spacer()
                if !store.addDraft.resourceLines.isEmpty {
                    Text(inputSummary).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("add-download-input-summary")
                }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $store.addDraft.rawInput)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($linksAreFocused)
                    .padding(6)
                    .accessibilityLabel("Download links")
                    .accessibilityIdentifier("add-download-url-field")
                if store.addDraft.rawInput.isEmpty {
                    Text("https://example.com/file.zip")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 96)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(linksAreFocused ? Color.accentColor : Color(nsColor: .separatorColor),
                                  lineWidth: linksAreFocused ? 2 : 1)
                    .allowsHitTesting(false)
            }
            .disabled(isSubmitting || store.bitTorrentSelectionSession != nil)
            if store.addDraft.isBatch {
                Toggle("Use these links as mirrors for one download", isOn: $store.addDraft.treatLinesAsMirrors)
                    .toggleStyle(.checkbox)
                    .disabled(isSubmitting)
            }
        }
    }

    private var inputSummary: String {
        let lines = store.addDraft.resourceLines
        let unsupported = lines.filter { AddDownloadDraft.detectProtocol(for: $0) == nil }.count
        if unsupported > 0 { return "\(unsupported) unsupported \(unsupported == 1 ? "link" : "links")" }
        if lines.count > 1 { return "\(lines.count) links" }
        return store.addDraft.detectedProtocol?.rawValue ?? ""
    }

    private var saveLocation: some View {
        HStack(spacing: 10) {
            Text("Save to").font(.callout.weight(.medium))
            if store.addDraft.savePath.isEmpty {
                Text("Choose a folder").foregroundStyle(.secondary)
                Spacer()
            } else {
                DownloadFolderPath(path: store.addDraft.savePath)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .help(store.addDraft.savePath)
            }
            Button("Choose…", action: chooseSaveFolder)
                .accessibilityIdentifier("add-download-choose-folder-button")
        }
        .disabled(isSubmitting || store.bitTorrentSelectionSession != nil)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if isSubmitting { ProgressView().controlSize(.small) }
            Spacer()
            Button("Cancel", role: .cancel, action: dismiss)
                .keyboardShortcut(.cancelAction)
                .disabled(isSubmitting && !store.isResolvingBitTorrentFiles)
                .accessibilityIdentifier("add-download-cancel-button")
            Button(primaryButtonTitle, action: submit)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(primaryButtonDisabled)
                .accessibilityIdentifier("add-download-submit-button")
        }
        .controlSize(.regular)
    }

    private var primaryButtonTitle: String {
        if let session = store.bitTorrentSelectionSession {
            return session.phase == .loading ? "Loading Files…" : "Download Selected Files"
        }
        if isSubmitting { return "Adding…" }
        if store.addDraft.shouldResolveBitTorrentFilesBeforeSubmit { return "Choose Files…" }
        let count = store.addDraft.resourceLines.count
        return count > 1 && !store.addDraft.treatLinesAsMirrors ? "Start \(count) Downloads" : "Start Download"
    }

    private var primaryButtonDisabled: Bool {
        if isSubmitting || store.isResolvingBitTorrentFiles { return true }
        if let session = store.bitTorrentSelectionSession { return session.phase != .ready || !session.hasSelection }
        return !store.addDraft.isSubmittable
    }

    private func submit() {
        guard !primaryButtonDisabled else { return }
        linksAreFocused = false
        submissionError = nil
        isSubmitting = true
        Task { @MainActor in
            defer { isSubmitting = false }
            let submitted: Bool
            if store.bitTorrentSelectionSession?.phase == .ready {
                submitted = await store.confirmBitTorrentFileSelection()
            } else {
                submitted = await store.submitDraft()
            }
            if submitted { onDismiss() }
        }
    }

    private func dismiss() {
        Task { @MainActor in
            await store.cancelBitTorrentFileSelection()
            onDismiss()
        }
    }

    private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Download Folder"
        panel.prompt = "Choose"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if !store.addDraft.savePath.isEmpty { panel.directoryURL = URL(fileURLWithPath: store.addDraft.savePath) }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            store.addDraft.savePath = url.path
        }
    }
}

/// The system path control abbreviates long paths and uses native folder icons and tooltips.
private struct DownloadFolderPath: NSViewRepresentable {
    var path: String
    func makeNSView(context: Context) -> NSPathControl {
        let control = NSPathControl()
        control.pathStyle = .standard
        control.isEditable = false
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setAccessibilityLabel("Download folder")
        return control
    }
    func updateNSView(_ control: NSPathControl, context: Context) {
        control.url = URL(fileURLWithPath: path, isDirectory: true)
        control.setAccessibilityValue(path)
    }
}

private struct AddDownloadOptions: View {
    @EnvironmentObject private var store: DownloadStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 12) {
                row("Filename") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Use the original filename", text: $store.addDraft.outputName)
                        if store.addDraft.isBatch && !store.addDraft.treatLinesAsMirrors {
                            Text("Leave empty when adding separate downloads.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                row("Connections") {
                    Stepper(value: $store.addDraft.splitCount, in: 1...256) {
                        Text("\(store.addDraft.splitCount)").monospacedDigit()
                    }
                    .frame(width: 100)
                }
                row("Download speed") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Limit speed", isOn: $store.addDraft.limitSpeed)
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("add-download-limit-speed-toggle")
                        if store.addDraft.limitSpeed {
                            HStack {
                                TextField("Speed", value: $store.addDraft.speedLimitKB, format: .number.grouping(.never))
                                    .frame(width: 88)
                                Text("KB/s").foregroundStyle(.secondary)
                            }
                            if store.addDraft.speedLimitKB <= 0 {
                                Text("Enter a speed greater than zero.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("add-download-speed-limit-warning")
                            }
                        }
                    }
                }
            }
            Divider()
            Text("HTTP Request").font(.callout.weight(.medium))
            VStack(spacing: 12) {
                row("User-Agent") { TextField("Default", text: $store.addDraft.userAgent) }
                row("Referer") { TextField("Optional", text: $store.addDraft.referer) }
                row("Cookie") { SecureField("Optional", text: $store.addDraft.cookie) }
                row("Authorization") { SecureField("Optional", text: $store.addDraft.authorization) }
                row("Proxy") { TextField("Use engine settings", text: $store.addDraft.proxyURL) }
                row("Custom headers") {
                    TextField("Header: Value", text: $store.addDraft.customHeaders, axis: .vertical)
                        .lineLimit(3...5)
                        .font(.system(.callout, design: .monospaced))
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.regular)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary)
                .frame(width: 106, alignment: .trailing)
            content().frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(title)
        }
    }
}

private struct BitTorrentFileSelectionView: View {
    @EnvironmentObject private var store: DownloadStore
    var session: BitTorrentFileSelectionSession

    var body: some View {
        GroupBox {
            switch session.phase {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Loading torrent metadata")
                            .font(.callout.weight(.medium))
                        Text(session.source)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("bt-file-selection-loading")
            case .ready:
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.taskName)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .accessibilityIdentifier("bt-file-selection-title")
                            Text(selectionSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("bt-file-selection-summary")
                        }
                        Spacer()
                        Button("All") {
                            store.setAllBitTorrentFilesSelected(true)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("bt-file-selection-select-all")

                        Button("None") {
                            store.setAllBitTorrentFilesSelected(false)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("bt-file-selection-select-none")
                    }

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(session.files.enumerated()), id: \.element.id) { offset, file in
                                BitTorrentFileSelectionRow(
                                    file: file,
                                    isSelected: session.selectedFileIndexes.contains(file.index)
                                )
                                .environmentObject(store)
                                if offset < session.files.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.separator.opacity(0.45), lineWidth: 0.5)
                    }
                    .accessibilityIdentifier("bt-file-selection-list")
                }
            }
        }
        .accessibilityIdentifier("bt-file-selection")
    }

    private var selectionSummary: String {
        "\(session.selectedFileIndexes.count) of \(session.files.count) files selected - \(ByteFormat.size(session.selectedTotalLength))"
    }
}

private struct BitTorrentFileSelectionRow: View {
    @EnvironmentObject private var store: DownloadStore
    var file: DownloadFile
    var isSelected: Bool

    var body: some View {
        Toggle(isOn: selectionBinding) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(file.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(ByteFormat.size(file.length))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityIdentifier("bt-file-selection-row-\(file.index)")
    }

    private var selectionBinding: Binding<Bool> {
        Binding(
            get: { isSelected },
            set: { store.setBitTorrentFile(file, isSelected: $0) }
        )
    }

    private var displayName: String {
        let name = URL(fileURLWithPath: file.path).lastPathComponent
        return name.isEmpty ? file.path : name
    }
}
