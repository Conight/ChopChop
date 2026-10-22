import SwiftUI

struct TemporaryBandwidthControls: View {
    @Environment(DownloadStore.self) private var store
    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let effective = store.effectiveBandwidth(at: context.date)
            VStack(alignment: .leading, spacing: 4) {
                Menu {
                    Button(String(localized: "Limit for 30 Minutes")) { store.setTemporaryBandwidth(minutes: 30) }
                    Button(String(localized: "Limit for 1 Hour")) { store.setTemporaryBandwidth(minutes: 60) }
                    Button(String(localized: "Limit Until Turned Off")) { store.setTemporaryBandwidth(minutes: nil) }
                    Button(String(localized: "Turn Off Temporary Limit")) { store.clearTemporaryBandwidth() }
                } label: {
                    Label(String(localized: "Temporary Speed Limit"), systemImage: "tortoise")
                }
                if let issue = store.preferences.temporaryBandwidth.validationIssue {
                    Text(issue).font(.caption).foregroundStyle(.red)
                }
                Text(summary(effective)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if store.preferences.temporaryBandwidth.isActive(at: context.date) {
                    if let expiration = store.preferences.temporaryBandwidth.expiresAt {
                        Text(String(localized: "Until \(expiration.formatted(date: .omitted, time: .shortened))"))
                            .font(.caption).foregroundStyle(.secondary)
                    } else { Text(String(localized: "Until turned off")).font(.caption).foregroundStyle(.secondary) }
                }
                if !store.engineController.isRunning {
                    Text(String(localized: "Limits apply when the engine is connected.")).font(.caption).foregroundStyle(.secondary)
                } else if store.lastBandwidthOptions != effective.options {
                    Text(String(localized: "Applying speed limits…")).font(.caption).foregroundStyle(.secondary)
                }
                if let issue = store.bandwidthPlanIssue { Text(issue).font(.caption).foregroundStyle(.red) }
            }
        }
    }
    private func summary(_ limit: EffectiveBandwidth) -> String {
        func rate(_ kib: Int) -> String { kib == 0 ? String(localized: "Unlimited") : ByteFormat.speed(Int64(kib) * 1024) }
        let reason: String
        switch limit.reason {
        case .global: reason = String(localized: "Global limits")
        case .schedule: reason = String(localized: "Scheduled Bandwidth")
        case .temporary: reason = String(localized: "Temporary Speed Limit")
        }
        return "↓ \(rate(limit.downloadKiB))  ↑ \(rate(limit.uploadKiB)) · \(reason)"
    }
}

struct TemporaryBandwidthSettings: View {
    @Environment(DownloadStore.self) private var store
    var body: some View {
        Section(String(localized: "Temporary Speed Limit")) {
            TemporaryBandwidthControls()
            TextField(String(localized: "Download limit (KiB/s)"), value: Bindable(store).preferences.temporaryBandwidth.downloadKiB, format: .number.grouping(.never))
            TextField(String(localized: "Upload limit (KiB/s)"), value: Bindable(store).preferences.temporaryBandwidth.uploadKiB, format: .number.grouping(.never))
            Text(String(localized: "Temporary limits can only reduce the effective global or scheduled limit. Zero means unlimited. Expiration is preserved across restarts."))
                .font(.caption).foregroundStyle(.secondary)
        }.settingsAnchor("downloads.temporary-speed-limit")
    }
}
