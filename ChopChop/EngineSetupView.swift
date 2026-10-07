import AppKit
import SwiftUI

struct EngineSetupView: View {
    @EnvironmentObject private var store: DownloadStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Aria2 Next Required", systemImage: "arrow.down.circle.fill")
                .font(.title2.bold())
            Text("ChopChop needs Aria2 Next to download files. Download and install the engine to continue. It will start automatically.")
                .fixedSize(horizontal: false, vertical: true)
            if case .failed(let message) = store.engineSetupState {
                Text(message).foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("engine-install-error")
            }
            if case .installing(let progress) = store.engineSetupState {
                EngineInstallationProgressView(progress: progress, onCancel: store.cancelEngineInstallation)
                .accessibilityIdentifier("engine-install-progress")
            }
            HStack {
                Button("Quit ChopChop") { NSApp.terminate(nil) }
                Spacer()
                Button(installButtonTitle) { store.installRequiredEngine() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.engineSetupState.isInstalling)
                    .accessibilityIdentifier("engine-install-button")
            }
        }
        .padding(28)
        .frame(width: 500)
        .interactiveDismissDisabled()
    }

    private var installButtonTitle: String {
        if case .failed = store.engineSetupState { return "Retry Download" }
        return "Download and Start"
    }
}

/// The same linear indicator stays in place for connecting, downloading and installation.
struct EngineInstallationProgressView: View {
    var progress: EngineInstallationProgress
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(progress.title).fontWeight(.medium)
                Spacer(minLength: 12)
                if let percent = progress.percentDescription {
                    Text(percent).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            ProgressView(value: progress.fractionCompleted)
                .progressViewStyle(.linear)
                .accessibilityLabel(progress.title)
                .accessibilityValue(progress.stage == .downloading ? progress.transferDescription : progress.title)
            HStack(alignment: .firstTextBaseline) {
                if progress.stage == .downloading {
                    ViewThatFits(in: .horizontal) {
                        Text([progress.transferDescription, progress.speedDescription].compactMap { $0 }.joined(separator: " · "))
                        Text(progress.transferDescription)
                    }
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if progress.canCancel {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .controlSize(.small)
                        .help("Cancel this download. A retry starts from the beginning.")
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
