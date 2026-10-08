import AppKit
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
        capabilities = known.filter { name in store.engineCapabilities?.enabledFeatures?.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) == true }
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
    @ObservedObject var updates: AppUpdateCoordinator
    var body: some View {
        Section(String(localized: "ChopChop Updates")) {
            LabeledContent(String(localized: "Installed version"), value: updates.build.displayVersion)
            Toggle(String(localized: "Automatically check for ChopChop updates"), isOn: Binding(
                get: { updates.build.version != nil && updates.automaticallyChecks },
                set: { updates.automaticallyChecks = $0 }))
                .disabled(updates.build.version == nil)
            Text(String(localized: "Checks at most once a day. You choose when to download and install updates."))
                .font(.callout).foregroundStyle(.secondary)
            if updates.build.version == nil {
                Text(String(localized: "This is a development build. Automatic update checks are disabled; you can check published releases manually."))
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.callout).foregroundStyle(.secondary)
            }
            switch updates.state {
            case .idle: EmptyView()
            case .checking: ProgressView(String(localized: "Checking ChopChop updates…")).controlSize(.small)
            case .current: Label(String(localized: "No newer release is available."), systemImage: "checkmark.circle")
            case .available(let release):
                Label(String(localized: "ChopChop \(release.version.description) is available"), systemImage: "arrow.down.circle")
                if !release.notes.isEmpty {
                    DisclosureGroup(String(localized: "What’s New")) {
                        Text(verbatim: release.notes).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Link(String(localized: "Download from GitHub…"), destination: release.pageURL)
                Text(String(localized: "Download the DMG, quit ChopChop, and replace the app in Applications. Your downloads and settings are kept."))
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.callout).foregroundStyle(.secondary)
            case .failed(let reason):
                Label(errorMessage(reason), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            Button(String(localized: "Check ChopChop Updates")) { Task { await updates.check() } }
                .disabled(updates.state == .checking)
        }
    }
    private func errorMessage(_ error: AppUpdateError) -> String {
        switch error {
        case .offline: String(localized: "Could not connect to GitHub. Check your connection and try again.")
        case .rateLimited: String(localized: "GitHub is limiting update checks. Please try again later.")
        case .invalidResponse: String(localized: "GitHub returned an unreadable release list. Please try again later.")
        case .noCompatibleRelease: String(localized: "A newer release has no ready Apple Silicon DMG. Please check again later.")
        case .serviceUnavailable: String(localized: "The update service is unavailable. Please try again later.")
        }
    }
}

struct AppSupportView: View {
    @EnvironmentObject private var store: DownloadStore
    @State private var report: String?
    @State private var exportStatus: String?

    init(initialReport: String? = nil) { _report = State(initialValue: initialReport) }

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
                    Link(String(localized: "Read the User Guide"), destination: URL(string: "https://github.com/Conight/ChopChop#install")!)
                }
                Section(String(localized: "Report a Problem")) {
                    Text(String(localized: "Describe what you expected and what happened. You can preview and export a small diagnostic report to attach yourself."))
                        .fixedSize(horizontal: false, vertical: true)
                    Link(String(localized: "Open GitHub Issues…"), destination: URL(string: "https://github.com/Conight/ChopChop/issues/new/choose")!)
                    Button(String(localized: "Preview Diagnostic Report")) {
                        do { report = try DiagnosticReport(store: store).json(); exportStatus = nil }
                        catch { exportStatus = String(localized: "Could not prepare diagnostics. Please try again.") }
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
    @ObservedObject var updates: AppUpdateCoordinator
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(String(localized: "Check ChopChop Updates…")) {
                updates.settingsRequested = true
                openSettings()
                Task { await updates.check() }
            }
        }
        CommandGroup(replacing: .help) {
            Button(String(localized: "ChopChop Help")) { openWindow(id: AppWindowID.help) }
        }
    }
}

enum AppWindowID {
    static let downloads = "downloads"
    static let help = "help"
}

/// Bind SwiftUI's scene action once; window reopening never depends on translated menu labels.
struct DownloadWindowRegistration: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let delegate: ChopChopAppDelegate
    func body(content: Content) -> some View {
        content.onAppear { delegate.openDownloadWindow = { openWindow(id: AppWindowID.downloads) } }
    }
}
