import SwiftUI

struct TrackerDiagnosticsView: View {
    @Environment(DownloadStore.self) private var store
    var body: some View {
        DisclosureGroup(String(localized: "Tracker Diagnostics")) {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    Task { await store.checkTrackerConnections() }
                } label: {
                    ActionFeedbackLabel(title: String(localized: "Check Connections"), systemImage: "network",
                                        feedback: store.trackerDiagnostics.isProbing ? .working : .idle)
                }.disabled(store.trackerDiagnostics.isProbing)
                Button(String(localized: "Reset Tracker Exclusions")) { store.trackerDiagnostics.resetExclusions() }
                Text(String(localized: "Connection tests do not verify announce success or available peers. UDP tests are skipped when a proxy is configured. Private and unknown torrents never receive automatic public trackers."))
                    .font(.caption).foregroundStyle(.secondary)
                if let issue = store.trackerDiagnostics.issue { Text(issue).font(.caption).foregroundStyle(.red) }
                ForEach(store.engineSettings.trackerSourceURLs, id: \.self) { source in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(DownloadPrivacy.redact(source)).lineLimit(1).truncationMode(.middle)
                        if let snapshot = store.trackerDiagnostics.sources[source] {
                            Text(snapshot.lastSuccess.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                        } else { Text(String(localized: "No successful source snapshot")).foregroundStyle(.secondary) }
                    }.font(.caption)
                }
                ForEach(Array(store.trackerDiagnostics.candidates.prefix(96)), id: \.self) { url in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(DownloadPrivacy.redact(url), systemImage: store.trackerDiagnostics.selected.contains(url) ? "checkmark.circle" : "minus.circle").lineLimit(1).truncationMode(.middle)
                        Text(store.trackerDiagnostics.selectionReason(url, proxy: store.engineSettings.proxyURL)).foregroundStyle(.secondary)
                        if let observation = store.trackerDiagnostics.observation(url, proxy: store.engineSettings.proxyURL) {
                            HStack {
                                if let latency = observation.latency {
                                    Text(String(localized: "\(Int(min(60, max(0, latency)) * 1000)) ms"))
                                }
                                if let samples = observation.samples, !samples.isEmpty {
                                    Text((Double(samples.filter { $0 }.count) / Double(samples.count)).formatted(.percent.precision(.fractionLength(0))))
                                        .help(String(localized: "Connection success rate over the last 16 observations"))
                                }
                                Text(observation.checkedAt.formatted(date: .omitted, time: .shortened))
                            }.foregroundStyle(.secondary)
                        }
                    }.font(.caption)
                }
            }.padding(.top, 8)
        }
    }
}

extension DownloadStore {
    func checkTrackerConnections() async {
        let settings = engineSettings
        await trackerDiagnostics.probe(urls: TrackerText.trackers(from: settings.btTracker), proxy: settings.proxyURL)
        guard !Task.isCancelled, engineSettings.btTracker == settings.btTracker,
              engineSettings.proxyURL == settings.proxyURL, engineSettings.trackerSourceURLs == settings.trackerSourceURLs else { return }
        engineSettings.btTracker = trackerDiagnostics.curate(TrackerSourceFetchResult(data: [], failures: []),
            sourceURLs: settings.trackerSourceURLs, current: settings.btTracker, proxy: settings.proxyURL)
    }
}
