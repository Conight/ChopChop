import AppKit
import SwiftUI

struct AppUpdateIndicator: View {
    @ObservedObject var updates: AppUpdateCoordinator
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if updates.updateAvailable || updates.installationNeedsAttention {
            Button { openWindow(id: AppWindowID.updates) } label: {
                Label(updates.installationNeedsAttention ? String(localized: "Update Failed") : String(localized: "Update Available"), systemImage: updates.installationNeedsAttention ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.down.circle")
            }.help(String(localized: "View ChopChop Update"))
        }
    }
}

extension AppUpdateChannel {
    var title: String { switch self { case .stable: String(localized: "Stable Releases"); case .prerelease: String(localized: "Pre-releases") } }
}

extension AppUpdateError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .offline: String(localized: "Could not connect to GitHub. Check your connection and try again.")
        case .rateLimited: String(localized: "GitHub is limiting update checks. Please try again later.")
        case .invalidResponse: String(localized: "GitHub returned an unreadable release list. Please try again later.")
        case .noCompatibleRelease: String(localized: "A newer release is listed, but its macOS installer is not available yet.")
        case .serviceUnavailable: String(localized: "The update service is unavailable. Please try again later.")
        case .signingNotConfigured: String(localized: "This build does not have an update verification key. Download and install the release manually.")
        case .invalidSignature: String(localized: "The update could not be verified. Your current app has not been changed.")
        case .unsupportedSystem: String(localized: "This update requires a newer version of macOS.")
        case .installLocation: String(localized: "ChopChop cannot update in this location. Move it to a writable Applications folder and reopen it, or install manually.")
        case .invalidApplication: String(localized: "The downloaded app is incompatible or damaged. Your current app has not been changed.")
        case .installerUnavailable: String(localized: "The update installer could not be reached. Reopen ChopChop and try again.")
        case .installationFailed: String(localized: "The update could not be installed. Your previous app has been kept.")
        case .openingInstallerFailed: String(localized: "The installer could not be opened. Download it again and retry.")
        case .downloadFailed: String(localized: "The update download failed. Check your connection and try again.")
        case .terminationTimedOut: String(localized: "ChopChop did not quit in time. Your current app is unchanged. Try installing again when it is ready to quit.")
        }
    }
}

struct AppUpdateWindow: View {
    @ObservedObject var updates: AppUpdateCoordinator
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                    .resizable().frame(width: 64, height: 64).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("ChopChop Updates").font(.title2).fontWeight(.semibold)
                    Text(updates.build.displayVersion + (updates.release.map { " → \($0.version)" } ?? ""))
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.padding(24)

            if showsOperation {
                // A download must remain visible even after scrolling to the end of the release notes.
                VStack(alignment: .leading, spacing: 16) {
                    status
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32)
                .frame(maxHeight: .infinity, alignment: .center)
                .padding(.bottom, 24)
            } else {
                HStack {
                    Picker("Update Channel", selection: $updates.channel) {
                        ForEach(AppUpdateChannel.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.fixedSize().disabled(!updates.canChangeChannel)
                    Spacer()
                }.padding(.horizontal, 24).padding(.bottom, 16)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        status
                        if let release = updates.release {
                            if !release.notes.isEmpty {
                                Text("What’s New").font(.headline)
                                ReleaseNotesView(markdown: release.notes, baseURL: release.pageURL)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if case .available = updates.state, !updates.signingConfigured || !release.supportsInstallation {
                                Text("Download the installer here, then open it to install this update.").foregroundStyle(.secondary)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }
            }
            Divider()
            HStack(spacing: 12) {
                Button(isWorking ? String(localized: "Hide") : String(localized: "Close")) {
                    dismissWindow(id: AppWindowID.updates)
                }.keyboardShortcut(.cancelAction)
                Spacer()
                actions
            }.padding(20)
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 400, idealHeight: 500)
        .background(.background)
        .task { if updates.state == .idle { await updates.check() } }
    }

    private var showsOperation: Bool {
        switch updates.state {
        case .checking, .preparing, .ready, .downloaded, .installing, .waitingToQuit: true
        default: false
        }
    }

    private var isWorking: Bool {
        switch updates.state {
        case .checking, .preparing, .installing, .waitingToQuit: true
        default: false
        }
    }

    @ViewBuilder private var status: some View {
        switch updates.state {
        case .idle: Text("Check for new versions of ChopChop.").foregroundStyle(.secondary)
        case .checking: phaseProgress(String(localized: "Checking ChopChop updates…"))
        case .current:
            Label("No newer release is available.", systemImage: "checkmark.circle")
            if updates.channel == .stable, updates.build.version?.prerelease.isEmpty == false {
                Text("You’ll stay on this pre-release until a newer stable version is available.").foregroundStyle(.secondary)
            }
        case .available: Label("An update is available.", systemImage: "arrow.down.circle")
        case .preparing(_, let progress):
            VStack(alignment: .leading, spacing: 12) {
                if progress.stage == .downloading {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Downloading update…").font(.headline)
                        Spacer()
                        if let fraction = progress.fraction {
                            Text(fraction, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .accessibilityLabel(Text("Update download progress"))
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Text(progress.byteSummary)
                            Spacer(minLength: 12)
                            if let speed = progress.speedSummary { Text(speed) }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(progress.byteSummary)
                            if let speed = progress.speedSummary { Text(speed) }
                        }
                    }.font(.callout).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    phaseProgress(progressTitle(progress.stage))
                }
                Text("You can hide this window. The update will continue.")
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
            }
        case .ready:
            Label("Ready to install", systemImage: "checkmark.circle")
            Text("ChopChop will save your downloads, quit, and reopen. Downloads and seeding will stay paused.")
                .foregroundStyle(.secondary)
        case .downloaded:
            Label("Installer downloaded", systemImage: "checkmark.circle")
            Text("ChopChop will open the installer, save your downloads, and quit. Then drag ChopChop to Applications to finish updating.").foregroundStyle(.secondary)
        case .installing: phaseProgress(String(localized: "Saving downloads and restarting…"))
        case .waitingToQuit:
            phaseProgress(String(localized: "Waiting for ChopChop to quit…"))
            Text("Downloads are being saved. If quitting was interrupted, try again.").foregroundStyle(.secondary)
        case .failed(let error):
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
            if updates.release != nil, updates.canDownloadInstaller {
                Button("Download Installer") { updates.downloadInstaller() }.buttonStyle(.link)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        switch updates.state {
        case .checking: Button("Cancel") { updates.cancel() }
        case .preparing(_, let progress):
            Button(progress.stage == .connecting || progress.stage == .downloading
                   ? String(localized: "Cancel Download") : String(localized: "Cancel Update")) { updates.cancel() }
        case .ready:
            Button("Discard Update") { updates.cancel() }
            Button("Install and Restart") { updates.installAndRestart() }.buttonStyle(.borderedProminent)
        case .downloaded(_, let archive):
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([archive.url]) }
            Button("Quit and Open Installer") { updates.openInstaller() }.buttonStyle(.borderedProminent)
        case .installing: EmptyView()
        case .waitingToQuit: Button("Retry Quit") { updates.retryQuit() }.buttonStyle(.borderedProminent)
        case .failed where updates.release != nil:
            Button("Try Again") { updates.retry() }.buttonStyle(.borderedProminent)
        case .available:
            Button("Download Update") { updates.download() }.buttonStyle(.borderedProminent)
        default:
            Button("Check ChopChop Updates") { Task { await updates.check() } }.buttonStyle(.borderedProminent)
        }
    }
    private func phaseProgress(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ProgressView(value: nil as Double?).progressViewStyle(.linear)
                .accessibilityLabel(Text(title))
        }
    }
    private func progressTitle(_ stage: AppUpdateProgress.Stage) -> String {
        switch stage {
        case .connecting: String(localized: "Connecting to GitHub…")
        case .downloading: String(localized: "Downloading update…")
        case .verifying: String(localized: "Verifying update…")
        case .preparing: String(localized: "Preparing update…")
        }
    }
}

extension AppUpdateProgress {
    var byteSummary: String {
        let received = ByteCountFormatter.string(fromByteCount: max(0, completedBytes), countStyle: .file)
        if let totalBytes, totalBytes > 0 {
            let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            return String(localized: "\(received) of \(total)")
        }
        return String(localized: "\(received) downloaded")
    }

    var speedSummary: String? {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0, bytesPerSecond < Double(Int64.max) else { return nil }
        let speed = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file)
        return String(localized: "\(speed)/s")
    }
}
