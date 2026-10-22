import Charts
import SwiftUI

struct DownloadActivityView: View {
    var task: DownloadTask
    var body: some View {
        if let activity = task.activity {
            DisclosureGroup(String(localized: "Task Activity")) {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent(String(localized: "Observed average speed"), value: ByteFormat.speed(activity.averageDownload))
                    LabeledContent(String(localized: "Peak download speed"), value: ByteFormat.speed(activity.peakDownload))
                    LabeledContent(String(localized: "Peak upload speed"), value: ByteFormat.speed(activity.peakUpload))
                    if activity.samples.count > 1 {
                        Chart {
                            ForEach(activity.samples) { sample in
                                LineMark(x: .value(String(localized: "Time"), sample.date), y: .value(String(localized: "Bytes/s"), sample.down), series: .value(String(localized: "Segment"), sample.segment))
                                    .foregroundStyle(by: .value(String(localized: "Direction"), String(localized: "Download speed")))
                                LineMark(x: .value(String(localized: "Time"), sample.date), y: .value(String(localized: "Bytes/s"), sample.up), series: .value(String(localized: "Segment"), sample.segment))
                                    .foregroundStyle(by: .value(String(localized: "Direction"), String(localized: "Upload speed")))
                            }
                        }.frame(height: 130).accessibilityLabel(String(localized: "Transfer history"))
                    }
                    Text(String(localized: "Statistics cover observed intervals only. Historical curves are compacted; peaks and summary values are kept separately."))
                        .font(.caption).foregroundStyle(.secondary)
                    if activity.hasGap {
                        Label(String(localized: "History includes an observation gap."), systemImage: "clock.badge.exclamationmark")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(activity.events.reversed()) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Label(event.isSharing ? String(localized: "Seeding") : event.status.localizedTitle, systemImage: event.status.symbolName)
                                Spacer()
                                Text(event.date.formatted(date: .abbreviated, time: .standard)).foregroundStyle(.secondary)
                            }
                            if event.recovered { Text(String(localized: "Observed after reconnect; original transition time is unknown.")).foregroundStyle(.secondary) }
                            if let error = event.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                        }.font(.caption)
                    }
                }.padding(.top, 8)
            }.contentPanel()
        }
    }
}
