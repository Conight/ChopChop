import AppKit
import SwiftUI

struct EngineSetupView: View {
    @Environment(DownloadStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
            Text(String(localized: "Aria2 Next Required"))
                .font(AppTypography.windowTitle)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(String(localized: "ChopChop requires Aria2 Next 3.0.8 or later to download files. Install a supported engine to continue. It will start automatically."))
                        .fixedSize(horizontal: false, vertical: true)
                    if !store.engineSetupState.isInstalling {
                        EngineVersionPicker()
                    }
                    if case .failed(let message) = store.engineSetupState {
                        Text(message).foregroundStyle(.red)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("engine-install-error")
                    }
                    if case .installing(let progress) = store.engineSetupState {
                        EngineInstallationProgressView(progress: progress, onCancel: store.cancelEngineInstallation)
                        .accessibilityIdentifier("engine-install-progress")
                    }
                    Text(String(localized: "The engine is stored and managed by ChopChop. You do not need to choose a location. Restored downloads remain paused until you resume them."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(String(localized: "Quit ChopChop")) { AppTermination.request() }
                Spacer()
                Button(installButtonTitle) { store.installRequiredEngine() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!store.canInstallRequiredEngine)
                    .accessibilityIdentifier("engine-install-button")
            }
        }
        .padding(AppLayout.pageInset + AppLayout.focusClearance)
        .frame(minWidth: 400, idealWidth: 500, maxWidth: 540, minHeight: 340, idealHeight: 400, maxHeight: 500)
        .desktopControls()
        .interactiveDismissDisabled()
    }

    private var installButtonTitle: String {
        if case .failed = store.engineSetupState { return String(localized: "Retry Download") }
        return String(localized: "Download and Start")
    }
}

/// First installation and subsequent version changes share the same release selection.
struct EngineVersionPicker: View {
    @Environment(DownloadStore.self) private var store
    var showsRefreshButton = true
    var loadsAutomatically = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker(String(localized: "Version to install"), selection: Bindable(store).selectedEngineVersion) {
                    Text(latestTitle).tag(EngineVersion?.none)
                    ForEach(store.recentEngineReleases) { release in
                        Text(release.version == store.installedEngine?.version
                             ? String(localized: "\(release.version.description) (installed)")
                             : release.version.description)
                            .tag(Optional(release.version))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("engine-version-picker")
                if showsRefreshButton {
                    Button { store.startEngineUpdateCheck() } label: {
                        Image(systemName: "arrow.clockwise")
                            .opacity(store.isCheckingEngineUpdate ? 0 : 1)
                    }
                    .overlay {
                        if store.isCheckingEngineUpdate {
                            ProgressView().controlSize(.small)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .stateChangeMotion(store.isCheckingEngineUpdate)
                    .help(String(localized: "Refresh Versions"))
                    .accessibilityLabel(store.isCheckingEngineUpdate
                                        ? String(localized: "Loading versions…")
                                        : String(localized: "Refresh Versions"))
                    .accessibilityIdentifier("engine-refresh-versions-button")
                }
            }
            .disabled(store.isCheckingEngineUpdate || store.isUpdatingEngine || store.engineSetupState.isInstalling)
            if let message = store.engineReleaseListError ?? store.engineVersionSelectionNotice {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { if loadsAutomatically { store.loadEngineReleasesIfNeeded() } }
    }

    private var latestTitle: String {
        if let release = store.latestEngineRelease {
            return String(localized: "Latest (\(release.version.description))")
        }
        return String(localized: "Latest (latest version)")
    }
}

/// The same linear indicator stays in place for connecting, downloading and installation.
struct EngineInstallationProgressView: View {
    var progress: EngineInstallationProgress
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(progress.title).fontWeight(.medium).lineLimit(2, reservesSpace: true)
                    .contentTransition(.opacity).stateChangeMotion(progress.stage)
                Spacer(minLength: 12)
                Text(progress.percentDescription ?? "100%")
                    .monospacedDigit().foregroundStyle(.secondary)
                    .opacity(progress.percentDescription == nil ? 0 : 1)
                    .accessibilityHidden(progress.percentDescription == nil)
            }
            ProgressView(value: progress.fractionCompleted)
                .progressViewStyle(.linear)
                .accessibilityLabel(progress.title)
                .accessibilityValue(progress.stage == .downloading ? progress.transferDescription : progress.title)
            HStack(alignment: .firstTextBaseline) {
                ViewThatFits(in: .horizontal) {
                    Text([progress.transferDescription, progress.speedDescription].compactMap { $0 }.joined(separator: " · "))
                    Text(progress.transferDescription)
                }
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    .opacity(progress.stage == .downloading ? 1 : 0)
                    .accessibilityHidden(progress.stage != .downloading)
                Spacer(minLength: 12)
                Button(String(localized: "Cancel"), role: .cancel, action: onCancel)
                    .controlSize(.small)
                    .opacity(progress.canCancel ? 1 : 0)
                    .disabled(!progress.canCancel).accessibilityHidden(!progress.canCancel)
                    .help(String(localized: "Cancel this download. A retry starts from the beginning."))
            }
        }
        .stateChangeMotion(progress.stage)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
