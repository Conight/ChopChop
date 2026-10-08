import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AddDownloadPanel: View {
    @EnvironmentObject private var store: DownloadStore
    @ObservedObject var mediaCoordinator: MediaDownloadCoordinator
    @State private var isShowingAdvanced: Bool
    @State private var contentHeight: CGFloat = 230
    @State private var submissionError: UserFacingAlert?
    @State private var isSubmitting = false
    @FocusState private var linksAreFocused: Bool
    var onDismiss: () -> Void

    init(initiallyShowsAdvanced: Bool = false, mediaCoordinator: MediaDownloadCoordinator = MediaDownloadCoordinator(), onDismiss: @escaping () -> Void) {
        _isShowingAdvanced = State(initialValue: initiallyShowsAdvanced)
        self.mediaCoordinator = mediaCoordinator
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
            VStack(alignment: .leading, spacing: 6) {
                Text(store.bitTorrentSelectionSession == nil ? String(localized: "Add Download") : String(localized: "Choose Torrent Files"))
                    .font(.title2.weight(.semibold))
                    .accessibilityIdentifier("add-download-title")
                Text(store.bitTorrentSelectionSession == nil ? String(localized: "Review your links or files before starting a download.") : String(localized: "Choose what to save before the download begins."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            .padding(.horizontal, AppLayout.focusClearance)

            if let session = store.bitTorrentSelectionSession {
                BitTorrentFileSelectionView(session: session)
                    .padding(.horizontal, AppLayout.focusClearance)
                    .frame(minHeight: 180, idealHeight: 360, maxHeight: 420)
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
                    linksInput
                    if let notice = store.addDraftNotice {
                        Text(notice).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if store.addDraft.resourceLines.contains(where: { $0.lowercased().hasPrefix("ftp://") }) {
                        Text(String(localized: "FTP is no longer supported by Aria2 Next. Use an HTTP, HTTPS, or SFTP link."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if !store.importIssues.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(String(localized: "Some items need attention"), systemImage: "exclamationmark.triangle.fill")
                                .font(.callout.weight(.medium)).symbolRenderingMode(.multicolor)
                            ForEach(store.importIssues, id: \.self) { issue in
                                Text(issue).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    saveLocation
                    if showsMediaOptions {
                        MediaDownloadOptionsView(coordinator: mediaCoordinator)
                            .disabled(isSubmitting)
                    }
                    DisclosureGroup(String(localized: "Advanced Options"), isExpanded: $isShowingAdvanced) {
                        AddDownloadOptions()
                            // AppKit draws field bezels and focus rings outside their layout bounds.
                            // Keep them inside the disclosure group's clipping/animation container.
                            .padding(AppLayout.focusClearance)
                            .padding(.top, AppLayout.controlSpacing)
                            .disabled(isSubmitting || store.bitTorrentSelectionSession != nil || mediaCoordinator.isPresented)
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
                .padding(AppLayout.focusClearance) // Align content with the header/footer and retain focus-ring clearance.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(minHeight: 0, idealHeight: min(contentHeight, 420), maxHeight: min(contentHeight, 420))

            }

            footer
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                .padding(.horizontal, AppLayout.focusClearance)
        }
        .padding(AppLayout.pageInset)
        .frame(minWidth: 480, idealWidth: 560, maxWidth: 660)
        // The form determines the height. A background rail cannot stretch the sheet
        // or reduce the existing 480-point minimum space available to its controls.
        .padding(.leading, 180)
        .background(alignment: .leading) {
            DownloadArtwork().frame(width: 180)
        }
        .presentationSizing(.fitted)
        .background(Color(nsColor: .windowBackgroundColor))
        .defaultFocus($linksAreFocused, true)
        .onChange(of: store.addDraft.rawInput) { _, _ in submissionError = nil; mediaCoordinator.clearError() }
        .onReceive(store.userAlerts) { alert in
            guard store.claimAlert(alert) else { return }
            submissionError = alert
        }
        .interactiveDismissDisabled(isSubmitting && !store.isResolvingBitTorrentFiles && mediaCoordinator.phase != .inspecting)
    }

    private var linksInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "Links or files")).font(.callout.weight(.medium))
                Spacer()
                Button(String(localized: "Open File…"), action: chooseDownloadFile)
                    .disabled(isSubmitting || mediaCoordinator.isPresented)
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
                    .accessibilityLabel(String(localized: "Download links"))
                    .accessibilityIdentifier("add-download-url-field")
                if store.addDraft.rawInput.isEmpty {
                    Text("https://example.com/file.zip")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: store.addDraft.isBatch ? 96 : 64)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(linksAreFocused ? Color.accentColor : Color(nsColor: .separatorColor),
                                  lineWidth: linksAreFocused ? 2 : 1)
                    .allowsHitTesting(false)
            }
            .disabled(isSubmitting || store.bitTorrentSelectionSession != nil || mediaCoordinator.isPresented)
            if store.addDraft.isBatch {
                Toggle(String(localized: "Use these links as mirrors for one download"), isOn: $store.addDraft.treatLinesAsMirrors)
                    .toggleStyle(.checkbox)
                    .disabled(isSubmitting)
            }
        }
    }

    private var inputSummary: String {
        let lines = store.addDraft.resourceLines
        let unsupported = lines.filter { AddDownloadDraft.detectProtocol(for: $0) == nil }.count
        if unsupported > 0 { return String(localized: "\(unsupported) unsupported links") }
        if lines.count > 1 { return String(localized: "\(lines.count) links") }
        return store.addDraft.detectedProtocol?.rawValue ?? ""
    }

    private var showsMediaOptions: Bool {
        mediaCoordinator.phase == .inspecting || mediaCoordinator.phase == .ready ||
        mediaCoordinator.error != nil ||
        (store.engineCapabilities?.supportsMedia == true && store.addDraft.isHTTPSource)
    }

    private var saveLocation: some View {
        HStack(spacing: 10) {
            Text(String(localized: "Save to")).font(.callout.weight(.medium))
            if store.addDraft.savePath.isEmpty {
                Text(String(localized: "Choose a folder")).foregroundStyle(.secondary)
                Spacer()
            } else {
                DownloadFolderPath(path: store.addDraft.savePath)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .help(DownloadLocationDisplay.resolvedURL(store.addDraft.savePath)?.path ?? store.addDraft.savePath)
            }
            Button(String(localized: "Choose…"), action: chooseSaveFolder)
                .accessibilityIdentifier("add-download-choose-folder-button")
        }
        .disabled(isSubmitting || store.bitTorrentSelectionSession != nil || mediaCoordinator.isPresented)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if store.bitTorrentSelectionSession != nil {
                Button(String(localized: "Change Source")) {
                    Task { await store.cancelBitTorrentFileSelection() }
                }
                .disabled(isSubmitting && !store.isResolvingBitTorrentFiles)
            } else if isSubmitting { ProgressView().controlSize(.small) }
            Spacer()
            Button(String(localized: "Cancel"), role: .cancel, action: dismiss)
                .keyboardShortcut(.cancelAction)
                .disabled(isSubmitting && !store.isResolvingBitTorrentFiles && mediaCoordinator.phase != .inspecting)
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
        if mediaCoordinator.phase == .inspecting { return String(localized: "Inspecting…") }
        if mediaCoordinator.phase == .ready { return mediaCoordinator.snapshot?.live == "true" ? String(localized: "Start Recording") : String(localized: "Download Selected Tracks") }
        if let session = store.bitTorrentSelectionSession {
            switch session.phase {
            case .loading: return String(localized: "Finding Files…")
            case .failed: return String(localized: "Try Again")
            case .ready: return String(localized: "Download Selected Files")
            }
        }
        if isSubmitting { return String(localized: "Adding…") }
        if store.addDraft.shouldInspectMedia { return String(localized: "Inspect Media…") }
        if store.addDraft.shouldResolveBitTorrentFilesBeforeSubmit { return String(localized: "Choose Files…") }
        let count = store.addDraft.resourceLines.count
        return count > 1 && !store.addDraft.treatLinesAsMirrors ? String(localized: "Start \(count) Downloads") : String(localized: "Start Download")
    }

    private var primaryButtonDisabled: Bool {
        if isSubmitting || store.isResolvingBitTorrentFiles { return true }
        if let session = store.bitTorrentSelectionSession { return session.phase == .loading || (session.phase == .ready && !session.hasSelection) }
        if mediaCoordinator.phase == .ready { return false }
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
            if mediaCoordinator.phase == .ready {
                submitted = await store.confirmMediaSelection()
            } else if store.bitTorrentSelectionSession?.phase == .failed {
                await store.prepareBitTorrentFileSelection()
                submitted = false
            } else if store.bitTorrentSelectionSession?.phase == .ready {
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
            await store.cancelMediaSelection()
            onDismiss()
        }
    }

    private func chooseDownloadFile() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Open Download File")
        panel.allowedContentTypes = ["torrent", "metalink", "meta4"].compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let preferences = store.preferences
            Task { @MainActor in
                do {
                    let document = try await Task.detached(priority: .userInitiated) {
                        try DownloadImportReader.readDocument(url, preferences: preferences)
                    }.value
                    store.addDraft.rawInput = url.absoluteString
                    store.addDraft.importedDocuments = [url.absoluteString: document]
                    store.addDraft.treatLinesAsMirrors = false
                    submissionError = nil
                } catch {
                    submissionError = UserFacingAlert(title: String(localized: "Open Download File"), message: error.localizedDescription)
                }
            }
        }
    }

    private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Download Folder")
        panel.prompt = String(localized: "Choose")
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
        control.setAccessibilityLabel(String(localized: "Download folder"))
        return control
    }
    func updateNSView(_ control: NSPathControl, context: Context) {
        control.url = DownloadLocationDisplay.resolvedURL(path)
        control.setAccessibilityValue(DownloadLocationDisplay.path(path))
    }
}

private struct AddDownloadOptions: View {
    @EnvironmentObject private var store: DownloadStore

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
            VStack(spacing: 12) {
                row(String(localized: "Filename")) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField(String(localized: "Use the original filename"), text: $store.addDraft.outputName)
                        if store.addDraft.isBatch && !store.addDraft.treatLinesAsMirrors {
                            Text(String(localized: "Leave empty when adding separate downloads."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                row(String(localized: "Connections")) {
                    Stepper(value: $store.addDraft.splitCount, in: 1...256) {
                        Text("\(store.addDraft.splitCount)").monospacedDigit()
                    }
                    .frame(width: 100)
                }
                row(String(localized: "Download speed")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(String(localized: "Limit speed"), isOn: $store.addDraft.limitSpeed)
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("add-download-limit-speed-toggle")
                        if store.addDraft.limitSpeed {
                            HStack {
                                TextField(String(localized: "Speed"), value: $store.addDraft.speedLimitKB, format: .number.grouping(.never))
                                    .frame(width: 88)
                                Text("KB/s").foregroundStyle(.secondary)
                            }
                            if store.addDraft.speedLimitKB <= 0 {
                                Text(String(localized: "Enter a speed greater than zero."))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("add-download-speed-limit-warning")
                            }
                        }
                    }
                }
            }
            Divider()
            Text(String(localized: "HTTP Request")).font(.callout.weight(.medium))
            VStack(spacing: 12) {
                row("User-Agent") { TextField(String(localized: "Default"), text: $store.addDraft.userAgent) }
                row("Referer") { TextField(String(localized: "Optional"), text: $store.addDraft.referer) }
                row("Cookie") { SecureField(String(localized: "Optional"), text: $store.addDraft.cookie) }
                row("Authorization") { SecureField(String(localized: "Optional"), text: $store.addDraft.authorization) }
                row(String(localized: "Proxy")) { TextField(String(localized: "Use engine settings"), text: $store.addDraft.proxyURL) }
                row(String(localized: "Custom headers")) {
                    TextField(String(localized: "Header: Value"), text: $store.addDraft.customHeaders, axis: .vertical)
                        .lineLimit(3...5)
                        .font(.system(.callout, design: .monospaced))
                }
            }
        }
        .nativeTextFieldStyle()
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
