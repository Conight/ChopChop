import AppKit
import SwiftUI

struct TrackerSourcesEditor: View {
    @Binding var selectedSourceURLs: [String]
    @Binding var customSourceURLs: [String]
    @State private var filter = ""
    @State private var newSourceURL = ""
    @State private var focusedSourceID: String?
    @State private var validationMessage: String?

    private var sourceRows: [TrackerSourceRowModel] {
        var rows = TrackerSourceCatalog.all.map { option in
            TrackerSourceRowModel(
                id: "preset:\(option.url)",
                title: option.displayName,
                subtitle: option.provider,
                url: option.url,
                isCustom: false
            )
        }
        var knownURLs = Set(rows.map(\.url))

        var emittedCustomURLs = Set<String>()
        for url in customSourceURLs where emittedCustomURLs.insert(url).inserted {
            rows.append(
                TrackerSourceRowModel(
                    id: "custom:\(url)",
                    title: url,
                    subtitle: String(localized: "Custom"),
                    url: url,
                    isCustom: true
                )
            )
            knownURLs.insert(url)
        }

        for url in selectedSourceURLs where !knownURLs.contains(url) {
            rows.append(
                TrackerSourceRowModel(
                    id: "selected:\(url)",
                    title: url,
                    subtitle: String(localized: "Selected source"),
                    url: url,
                    isCustom: true
                )
            )
        }

        return rows
    }

    private var filteredRows: [TrackerSourceRowModel] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sourceRows }
        return sourceRows.filter { row in
            row.title.localizedCaseInsensitiveContains(query) ||
                row.subtitle.localizedCaseInsensitiveContains(query) ||
                row.url.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedCount: Int {
        Set(selectedSourceURLs).count
    }

    private var summary: String {
        selectedCount == 1 ? String(localized: "1 source") : String(localized: "\(selectedCount) sources")
    }

    private var focusedCustomSource: TrackerSourceRowModel? {
        guard let focusedSourceID else { return nil }
        return sourceRows.first { $0.id == focusedSourceID && $0.isCustom }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                filterField
                Text(summary).font(.callout).foregroundStyle(.secondary).monospacedDigit().fixedSize()
            }
            .padding(.bottom, 12)

            Divider()

            sourceList
                .frame(height: 260)

            Divider()

            addCustomSourceControls
                .padding(12)

            Divider()

            TrackerCommandRow(
                title: String(localized: "Remove Custom Source"),
                systemImage: "minus.circle",
                isEnabled: focusedCustomSource != nil,
                accessibilityIdentifier: "settings-bt-remove-custom-tracker-source-button",
                action: removeFocusedCustomSource
            )
            .padding(.vertical, 6)
        }
        .accessibilityIdentifier("settings-bt-tracker-sources-editor")
        .onChange(of: customSourceURLs) { _, _ in
            reconcileFocusedSource()
        }
        .onChange(of: selectedSourceURLs) { _, _ in
            reconcileFocusedSource()
        }
    }

    private var filterField: some View {
        TextField(String(localized: "Filter"), text: $filter)
            .nativeTextFieldStyle()
            .accessibilityIdentifier("settings-bt-tracker-source-filter-field")
    }

    private var sourceList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if filteredRows.isEmpty {
                    Text(String(localized: "No tracker sources match this filter."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .accessibilityIdentifier("settings-bt-tracker-source-list-empty")
                } else {
                    ForEach(filteredRows) { row in
                        Button {
                            toggleSource(row)
                        } label: {
                            TrackerSourceSelectionRow(
                                title: row.title,
                                subtitle: row.subtitle,
                                url: row.url,
                                isSelected: selectedSourceURLs.contains(row.url),
                                isFocused: focusedSourceID == row.id,
                                isCustom: row.isCustom
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-bt-tracker-source-row")
                    }
                }
            }
            .padding(8)
        }
    }

    private var addCustomSourceControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(String(localized: "Custom tracker source URL"), text: $newSourceURL)
                    .nativeTextFieldStyle()
                    .accessibilityIdentifier("settings-bt-custom-tracker-source-field")
                    .onSubmit(addCustomSource)

                Button(action: addCustomSource) {
                    Label(String(localized: "Add"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("settings-bt-add-custom-tracker-source-button")
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-bt-custom-tracker-source-validation-message")
            }
        }
    }

    private func toggleSource(_ row: TrackerSourceRowModel) {
        focusedSourceID = row.id
        validationMessage = nil
        if selectedSourceURLs.contains(row.url) {
            selectedSourceURLs.removeAll { $0 == row.url }
        } else {
            selectedSourceURLs.append(row.url)
        }
    }

    private func addCustomSource() {
        let url = newSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            validationMessage = String(localized: "Enter a tracker source URL.")
            return
        }
        guard TrackerSourceURLValidator.isValid(url) else {
            validationMessage = String(localized: "Use an HTTP or HTTPS tracker source URL.")
            return
        }
        guard !sourceRows.contains(where: { $0.url == url }) else {
            focusedSourceID = sourceRows.first { $0.url == url }?.id
            validationMessage = String(localized: "Tracker source already exists.")
            return
        }

        customSourceURLs.append(url)
        selectedSourceURLs.append(url)
        focusedSourceID = "custom:\(url)"
        newSourceURL = ""
        validationMessage = nil
    }

    private func removeFocusedCustomSource() {
        guard let focusedCustomSource else { return }
        customSourceURLs.removeAll { $0 == focusedCustomSource.url }
        selectedSourceURLs.removeAll { $0 == focusedCustomSource.url }
        focusedSourceID = nil
        validationMessage = nil
    }

    private func reconcileFocusedSource() {
        guard let focusedSourceID else { return }
        if !sourceRows.contains(where: { $0.id == focusedSourceID }) {
            self.focusedSourceID = nil
        }
    }
}

struct TrackerSourceRowModel: Identifiable, Hashable {
    var id: String
    var title: String
    var subtitle: String
    var url: String
    var isCustom: Bool
}

struct TrackerSourceSelectionRow: View {
    var title: String
    var subtitle: String
    var url: String
    var isSelected: Bool
    var isFocused: Bool
    var isCustom: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .opacity(isSelected ? 1 : 0)
                .frame(width: 18)
            Image(systemName: isCustom ? "link" : "doc.text")
                .font(.body)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(subtitle) · \(url)")
                    .font(.caption)
                    .foregroundStyle(isFocused ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(isFocused ? Color.white : Color.primary)
        .background(
            isFocused ? Color.accentColor : selectedBackground,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .contentShape(Rectangle())
    }

    private var selectedBackground: Color {
        isSelected ? Color.accentColor.opacity(0.12) : Color.clear
    }
}

struct TrackerListEditor: View {
    @Binding var trackerText: String
    @State private var filter = ""
    @State private var newTracker = ""
    @State private var selectedTracker: String?
    @State private var showsRawEditor = false
    @State private var validationMessage: String?

    private var trackers: [String] {
        TrackerText.trackers(from: trackerText)
    }

    private var filteredTrackers: [String] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return trackers }
        return trackers.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var summary: String {
        let count = trackers.count
        return count == 1 ? String(localized: "1 tracker") : String(localized: "\(count) trackers")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                filterField
                Text(summary).font(.callout).foregroundStyle(.secondary).monospacedDigit().fixedSize()
            }
            .padding(.bottom, 12)

            Divider()

            Group {
                if showsRawEditor {
                    rawEditor
                        .padding(12)
                } else {
                    trackerRows
                }
            }
            .frame(height: 190)

            Divider()

            addTrackerControls
                .padding(12)

            Divider()

            commandRows
        }
        .accessibilityIdentifier("settings-bt-tracker-list-editor")
        .onAppear(perform: selectInitialTrackerIfNeeded)
        .onChange(of: trackerText) { _, _ in
            reconcileSelection()
        }
    }

    private var filterField: some View {
        TextField(String(localized: "Filter"), text: $filter)
            .nativeTextFieldStyle()
            .accessibilityIdentifier("settings-bt-tracker-filter-field")
    }

    private var trackerRows: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if trackers.isEmpty {
                    Text(String(localized: "No trackers. Sync sources or add a tracker."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .accessibilityIdentifier("settings-bt-tracker-list-empty")
                } else if filteredTrackers.isEmpty {
                    Text(String(localized: "No trackers match this filter."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .accessibilityIdentifier("settings-bt-tracker-list-empty-filtered")
                } else {
                    ForEach(filteredTrackers, id: \.self) { tracker in
                        Button {
                            selectedTracker = tracker
                            validationMessage = nil
                        } label: {
                            TrackerListRow(
                                tracker: tracker,
                                isSelected: selectedTracker == tracker
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-bt-tracker-row")
                    }
                }
            }
            .padding(8)
        }
    }

    private var addTrackerControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(String(localized: "Add tracker URL"), text: $newTracker)
                    .nativeTextFieldStyle()
                    .accessibilityIdentifier("settings-bt-tracker-add-field")
                    .onSubmit(addTracker)

                Button(action: addTracker) {
                    Label(String(localized: "Add"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("settings-bt-tracker-add-button")
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-bt-tracker-validation-message")
            }
        }
    }

    private var commandRows: some View {
        HStack(spacing: 12) {
            TrackerCommandRow(
                title: String(localized: "Remove Selected Tracker"),
                systemImage: "minus.circle",
                isEnabled: selectedTracker != nil,
                accessibilityIdentifier: "settings-bt-tracker-remove-button",
                action: removeSelectedTracker
            )

            TrackerCommandRow(
                title: showsRawEditor ? String(localized: "Hide Raw List") : String(localized: "Edit Raw List..."),
                systemImage: "text.alignleft",
                isEnabled: true,
                accessibilityIdentifier: "settings-bt-tracker-raw-toggle"
            ) {
                showsRawEditor.toggle()
                validationMessage = nil
            }
        }
        .padding(.vertical, 6)
    }

    private var rawEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Raw tracker list"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings-bt-tracker-raw-editor-label")
            TextEditor(text: $trackerText)
                .font(.system(.body, design: .monospaced))
                .frame(maxHeight: .infinity)
                .accessibilityIdentifier("settings-bt-tracker-text-editor")
        }
    }

    private func selectInitialTrackerIfNeeded() {
        guard selectedTracker == nil else { return }
        selectedTracker = trackers.first
    }

    private func reconcileSelection() {
        let currentTrackers = trackers
        guard let selectedTracker else {
            self.selectedTracker = currentTrackers.first
            return
        }
        if !currentTrackers.contains(selectedTracker) {
            self.selectedTracker = currentTrackers.first
        }
    }

    private func addTracker() {
        let trimmed = newTracker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            validationMessage = String(localized: "Enter a tracker URL.")
            return
        }
        guard TrackerURLValidator.isValid(trimmed) else {
            validationMessage = String(localized: "Use an HTTP, HTTPS, or UDP tracker URL.")
            return
        }
        guard !trackers.contains(trimmed) else {
            selectedTracker = trimmed
            validationMessage = String(localized: "Tracker already exists.")
            return
        }

        trackerText = (trackers + [trimmed]).joined(separator: "\n")
        selectedTracker = trimmed
        newTracker = ""
        validationMessage = nil
    }

    private func removeSelectedTracker() {
        guard let selectedTracker else { return }
        let remainingTrackers = trackers.filter { $0 != selectedTracker }
        trackerText = remainingTrackers.joined(separator: "\n")
        self.selectedTracker = remainingTrackers.first
        validationMessage = nil
    }
}

struct TrackerListRow: View {
    var tracker: String
    var isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .opacity(isSelected ? 1 : 0)
                .frame(width: 18)
            Image(systemName: "link")
                .font(.body)
            Text(tracker)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(
            isSelected ? Color.accentColor : Color.clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .contentShape(Rectangle())
    }
}

struct TrackerCommandRow: View {
    var title: String
    var systemImage: String
    var isEnabled: Bool
    var accessibilityIdentifier: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .disabled(!isEnabled)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
