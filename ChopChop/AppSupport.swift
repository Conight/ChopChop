import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Only typed, allowlisted values enter this report. Never serialize a task, error, log or settings object.
nonisolated struct DiagnosticReport: Encodable, Sendable {
    enum Issue: String, Encodable { case engineFailed, engineDisconnected, historyUnavailable, schedulingFailed, bandwidthFailed }
    let schemaVersion = 1
    let appVersion: String
    let macOSVersion: String
    let architecture = "arm64"
    let engineVersion: String?
    let capabilitiesKnown: Bool
    let capabilities: [String]
    let taskCounts: [String: Int]
    let issues: [Issue]

    @MainActor
    init(store: DownloadStore, build: AppBuild = AppBuild()) {
        appVersion = build.version?.description ?? "development"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        macOSVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        engineVersion = store.engineCapabilities.flatMap { EngineVersion($0.version)?.description } ?? store.installedEngine?.version.description
        capabilitiesKnown = store.engineCapabilities?.enabledFeatures != nil
        let known = ["BitTorrent", "SFTP", "Metalink", "ED2K"]
        capabilities = known.filter { name in store.engineCapabilities?.enabledFeatures.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) == true }
            + (store.engineCapabilities?.supportsMedia == true ? ["Media"] : [])
        taskCounts = Dictionary(uniqueKeysWithValues: DownloadStatus.allCases.map { status in
            (status.rawValue.lowercased(), store.tasks.filter { $0.status == status }.count)
        })
        var problems: [Issue] = []
        if case .failed = store.runtime.phase { problems.append(.engineFailed) }
        if store.connectionIssue != nil { problems.append(.engineDisconnected) }
        if store.historyIssue != nil { problems.append(.historyUnavailable) }
        if store.downloadPlanIssue != nil { problems.append(.schedulingFailed) }
        if store.bandwidthPlanIssue != nil { problems.append(.bandwidthFailed) }
        issues = problems
    }

    func json() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

struct AppUpdateSettingsView: View {
    let updates: AppUpdateCoordinator
    var openUpdates: () -> Void
    @State private var hadUpdateAction = false
    var body: some View {
        Section(AppIdentity.displayName) {
            LabeledContent(String(localized: "Installed version"), value: updates.build.displayVersion)
            Picker("Update Channel", selection: Bindable(updates).channel) {
                ForEach(AppUpdateChannel.allCases, id: \.self) { Text($0.title).tag($0) }
            }.disabled(updates.busy || !updates.canChangeChannel)
            UpdateCheckRow(status: status, isChecking: updates.state == .checking,
                           canCheck: updates.canCheckForUpdates,
                           accessibilityTitle: String(localized: "Check ChopChop Updates"),
                           identifier: "settings-check-chopchop-updates-button") {
                Task { await updates.check() }
            }
            .settingsAnchor("updates.check-chopchop")
            if updates.updateAvailable || updates.installationNeedsAttention || (updates.state == .checking && hadUpdateAction) {
                Button(String(localized: "View Update…"), action: openUpdates)
                    .disabled(updates.state == .checking)
            }
        }
        .onChange(of: updates.state, initial: true) { _, state in
            if state != .checking {
                hadUpdateAction = updates.updateAvailable || updates.installationNeedsAttention
            }
        }
    }

    private var status: String {
        if updates.build.isDevelopment {
            return String(localized: "Dev checks Engine updates only. Rebuild locally to update ChopChop Dev.")
        }
        if let release = updates.release, case .available = updates.state {
            return String(localized: "Version \(release.version.description) available")
        }
        switch updates.state {
        case .idle: return String(localized: "Not checked yet")
        case .checking: return String(localized: "Checking for updates…")
        case .current: return String(localized: "Up to date")
        case .failed(let error): return error.localizedDescription
        case .preparing(_, let progress):
            return progress.stage.title
        case .ready: return String(localized: "Ready to install")
        case .downloaded: return String(localized: "Installer downloaded")
        case .installing: return String(localized: "Saving downloads and restarting…")
        case .waitingToQuit: return String(localized: "Waiting for ChopChop to quit…")
        case .available: return String(localized: "Update Available")
        }
    }
}

@MainActor
final class AppSupportNavigation: ObservableObject {
    @Published var diagnosticPreviewRequested = false
}

struct AppSupportView: View {
    @ObservedObject var navigation: AppSupportNavigation
    @Environment(DownloadStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var report: String?
    @State private var exportStatus: String?

    init(initialReport: String? = nil, navigation: AppSupportNavigation = AppSupportNavigation()) {
        _report = State(initialValue: initialReport)
        self.navigation = navigation
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(String(localized: "Getting Started")) {
                    Label(String(localized: "Paste a download link or open a Torrent or Metalink file, then review it before adding."), systemImage: "plus.circle")
                        .fixedSize(horizontal: false, vertical: true)
                    Label(String(localized: "Aria2 Next starts automatically. Restored downloads and seeding stay paused until you resume them."), systemImage: "pause.circle")
                        .fixedSize(horizontal: false, vertical: true)
                    Label(String(localized: "Browser capture and completion notifications are optional. Enable them in Settings when you need them."), systemImage: "gearshape")
                        .fixedSize(horizontal: false, vertical: true)
                    Link(String(localized: "Read the User Guide"), destination: ReleaseConfiguration.current.userGuideURL)
                    Button(String(localized: "Keyboard Shortcuts")) { openWindow(id: AppWindowID.shortcuts) }
                }
                Section(String(localized: "Project and Updates")) {
                    Link(String(localized: "ChopChop on GitHub"), destination: ReleaseConfiguration.current.repositoryURL)
                    Link(String(localized: "Engine on GitHub"), destination: EngineDistribution.repositoryURL)
                    Link(String(localized: "Release Notes"), destination: ReleaseConfiguration.current.notesURL(for: AppBuild().version))
                    Button(String(localized: "About \(AppIdentity.displayName)")) { openWindow(id: AppWindowID.about) }
                    Button(String(localized: "Acknowledgments")) { openWindow(id: AppWindowID.acknowledgments) }
                }
                Section(String(localized: "Report a Problem")) {
                    Text(String(localized: "Describe what you expected and what happened. You can preview and export a small diagnostic report to attach yourself."))
                        .fixedSize(horizontal: false, vertical: true)
                    Link(String(localized: "Open GitHub Issues…"), destination: ReleaseConfiguration.current.issuesURL)
                    Button(String(localized: "Preview Diagnostic Report")) {
                        previewDiagnostics()
                    }
                    Text(String(localized: "Includes versions, supported engine features, task counts and issue codes. Excludes download names, links, file paths, authentication and raw logs. Nothing is uploaded automatically."))
                        .fixedSize(horizontal: false, vertical: true)
                        .font(.callout).foregroundStyle(.secondary)
                    if let report {
                        Text(verbatim: report).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(String(localized: "Export Diagnostic Report…")) { export(report) }
                    }
                    if let exportStatus { Text(exportStatus).foregroundStyle(.secondary) }
                }
            }.formStyle(.grouped)
        }
        .frame(minWidth: 480, idealWidth: 600, minHeight: 400, idealHeight: 600)
        .desktopControls()
        .onChange(of: navigation.diagnosticPreviewRequested, initial: true) { _, requested in
            if requested { previewDiagnostics(); navigation.diagnosticPreviewRequested = false }
        }
    }

    private func previewDiagnostics() {
        do { report = try DiagnosticReport(store: store).json(); exportStatus = nil }
        catch { exportStatus = String(localized: "Could not prepare diagnostics. Please try again.") }
    }

    private func export(_ report: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ChopChop-Diagnostics.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try Data(report.utf8).write(to: url, options: .atomic); exportStatus = String(localized: "Diagnostic report saved. Review it before sharing.") }
            catch { exportStatus = String(localized: "Could not save diagnostics. Choose another location and try again.") }
        }
    }
}

struct AppSupportCommands: Commands {
    let updates: AppUpdateCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    let store: DownloadStore
    let navigation: AppSupportNavigation
    private var context: DownloadActionContext {
        DownloadActionContext(store: store, window: DownloadWindowActions(
            checkUpdates: {
                store.requestUpdateSettings()
                openSettings()
                Task { await updates.checkAll(using: store) }
            }, openDiagnostics: {
                navigation.diagnosticPreviewRequested = true
                openWindow(id: AppWindowID.help)
            }, openHelp: { openWindow(id: AppWindowID.help) }))
    }
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(String(localized: "About \(AppIdentity.displayName)")) { openWindow(id: AppWindowID.about) }
        }
        CommandGroup(after: .appInfo) {
            DownloadActionButton(action: .checkUpdates, context: context)
        }
        CommandGroup(replacing: .help) {
            DownloadActionButton(action: .help, context: context)
                .keyboardShortcut("?", modifiers: .command)
            Link(String(localized: "Read the User Guide"), destination: ReleaseConfiguration.current.userGuideURL)
            Button(String(localized: "Keyboard Shortcuts")) { openWindow(id: AppWindowID.shortcuts) }
            Divider()
            Link(String(localized: "ChopChop on GitHub"), destination: ReleaseConfiguration.current.repositoryURL)
            Link(String(localized: "Engine on GitHub"), destination: EngineDistribution.repositoryURL)
            Link(String(localized: "Release Notes"), destination: ReleaseConfiguration.current.notesURL(for: updates.build.version))
            Divider()
            Link(String(localized: "Report a Problem…"), destination: ReleaseConfiguration.current.issuesURL)
            DownloadActionButton(action: .diagnostics, context: context)
            Button(String(localized: "Acknowledgments")) { openWindow(id: AppWindowID.acknowledgments) }
        }
    }
}

enum AppWindowID {
    static let downloadsWindow = "ChopChop.Downloads"
    static let downloads = "downloads"
    static let help = "help"
    static let about = "about"
    static let acknowledgments = "acknowledgments"
    static let shortcuts = "keyboard-shortcuts"
    static let updates = "updates"
}

/// Bind SwiftUI's scene action once; window reopening never depends on translated menu labels.
struct DownloadWindowRegistration: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let delegate: ChopChopAppDelegate
    func body(content: Content) -> some View {
        content.onAppear { delegate.openDownloadWindow = { openWindow(id: AppWindowID.downloads, value: AppWindowID.downloads) } }
    }
}
