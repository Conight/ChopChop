import AppKit
import SwiftUI

struct AppAboutView: View {
    let updates: AppUpdateCoordinator
    @Environment(DownloadStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var versionLabel: String {
        String(localized: "Version \(updates.build.displayVersion) (Build \(updates.build.buildNumber))")
    }

    private var engineVersion: String {
        if let version = store.engineCapabilities.flatMap({ EngineVersion($0.version) }) ?? store.installedEngine?.version {
            return version.description
        }
        switch store.engineSetupState {
        case .unchecked, .checking: return String(localized: "Checking engine")
        case .installing: return String(localized: "Installing…")
        case .required: return String(localized: "Not Installed")
        case .ready, .failed: return String(localized: "Unavailable")
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                AppBrandIcon(size: 88)
                Text(verbatim: AppIdentity.displayName).font(.system(size: 26, weight: .semibold))
                Text(String(localized: "A native download manager for macOS."))
                    .foregroundStyle(.secondary)
                Text(versionLabel).font(.callout).textSelection(.enabled)
                    .accessibilityIdentifier("about-app-version")
            }
            .accessibilityElement(children: .contain)

            VStack(spacing: 12) {
                LabeledContent("Aria2 Next", value: engineVersion)
                    .textSelection(.enabled)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Aria2 Next")
                    .accessibilityValue(engineVersion)
                    .accessibilityIdentifier("about-engine-version")
                HStack(spacing: 12) {
                    Link(String(localized: "ChopChop on GitHub"), destination: ReleaseConfiguration.current.repositoryURL)
                    Link(String(localized: "Engine on GitHub"), destination: EngineDistribution.repositoryURL)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 12) {
                Button(String(localized: "Check All Updates…")) {
                    store.requestUpdateSettings()
                    openSettings()
                    Task { await updates.checkAll(using: store) }
                }
                Link(String(localized: "Release Notes"), destination: ReleaseConfiguration.current.notesURL(for: updates.build.version))
            }
            .buttonStyle(.bordered)

            FeedbackButton(title: String(localized: "Copy Version Information"), systemImage: "doc.on.doc", successTitle: String(localized: "Copied")) {
                let os = ProcessInfo.processInfo.operatingSystemVersion
                let information = "\(AppIdentity.displayName) \(updates.build.displayVersion) (\(updates.build.buildNumber))\nAria2 Next: \(engineVersion)\nmacOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (arm64)"
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.setString(information, forType: .string)
            }
            .accessibilityIdentifier("about-copy-version")

            Divider()
            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    Button(String(localized: "ChopChop Help")) { openWindow(id: AppWindowID.help) }
                    Link(String(localized: "Report a Problem…"), destination: ReleaseConfiguration.current.issuesURL)
                    Button(String(localized: "Acknowledgments")) { openWindow(id: AppWindowID.acknowledgments) }
                }
                .buttonStyle(.link)
                Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(width: 500)
        .desktopControls()
    }
}

struct AppAcknowledgmentsView: View {
    var body: some View {
        Form {
            Section("ChopChop") {
                Text(String(localized: "Created by Conight. Thank you to everyone who reports issues, suggests improvements, and helps test ChopChop."))
                Text(String(localized: "No project-wide open-source license has been granted for ChopChop. Third-party components retain their own licenses."))
                    .foregroundStyle(.secondary)
                Link(String(localized: "ChopChop on GitHub"), destination: ReleaseConfiguration.current.repositoryURL)
            }
            Section("Aria2 Next") {
                Text(String(localized: "ChopChop is powered by Aria2 Next, built by the aria2 and Aria2 Next contributors. The engine is installed separately from its official releases."))
                LabeledContent(String(localized: "License"), value: "GPL-2.0-or-later")
                Link(String(localized: "Engine Source Code on GitHub"), destination: EngineDistribution.repositoryURL)
                BundledNoticeView(title: String(localized: "Engine Notices"), resource: "Aria2Next-NOTICE")
                BundledNoticeView(title: String(localized: "GNU General Public License"), resource: "Aria2Next-COPYING")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, idealWidth: 620, minHeight: 420, idealHeight: 560)
        .desktopControls()
    }
}

private struct BundledNoticeView: View {
    let title: String
    let resource: String
    @State private var isExpanded = false

    // These are the original notices shipped in the signed bundle, not a network request.
    private var contents: String? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { isExpanded.toggle() } label: {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(title)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
            if isExpanded {
                if let contents {
                    Text(verbatim: contents)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    Text(String(localized: "This notice could not be loaded. You can read it in the Engine source repository."))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct AppKeyboardShortcutsView: View {
    private let actions: [DownloadAction] = [.newDownload, .pasteLink, .openFile, .searchDownloads, .details, .reveal, .remove, .refresh]

    var body: some View {
        Form {
            Section(String(localized: "Downloads")) {
                ForEach(actions) { action in
                    if let shortcut = action.shortcutLabel {
                        shortcutRow(action.title, keys: shortcut)
                    }
                }
                shortcutRow(String(localized: "Search Commands…"), keys: "⇧⌘P")
            }
            Section(String(localized: "In the Task List")) {
                shortcutRow(String(localized: "Select All Visible Downloads"), keys: "⌘A")
                shortcutRow(String(localized: "Paste Download Link…"), keys: "⌘V")
                shortcutRow(String(localized: "Toggle Download Details"), keys: String(localized: "Space"))
                shortcutRow(String(localized: "Close Download Details"), keys: "Esc")
                Text(String(localized: "Select a task before using task actions. Removal asks for confirmation. When editing text, standard selection, paste, and deletion shortcuts apply to the text field."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 480, idealHeight: 620)
        .desktopControls()
    }

    private func shortcutRow(_ title: String, keys: String) -> some View {
        LabeledContent(title) { Text(verbatim: keys).font(.system(.body, design: .monospaced)) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(keys)
    }
}
