import SwiftUI
import UniformTypeIdentifiers

nonisolated struct BandwidthSchedule: Codable, Equatable, Sendable {
    var enabled = false
    var startMinute = 22 * 60
    var endMinute = 8 * 60
    var downloadKB = 1024
    var uploadKB = 128

    var validationIssue: String? {
        guard (0..<1440).contains(startMinute), (0..<1440).contains(endMinute),
              (0...Int(Int32.max)).contains(downloadKB), (0...Int(Int32.max)).contains(uploadKB) else {
            return String(localized: "Enter valid times and bandwidth limits of zero or more KiB/s.")
        }
        return nil
    }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        if startMinute == endMinute { return true }
        return startMinute < endMinute
            ? (startMinute..<endMinute).contains(minute)
            : minute >= startMinute || minute < endMinute
    }

    func options(at date: Date, base: EngineSettings, calendar: Calendar = .current) -> [String: String] {
        let active = contains(date, calendar: calendar)
        return [
            "max-overall-download-limit": Self.limit(active ? downloadKB : base.maxOverallDownloadLimitKB),
            "max-overall-upload-limit": Self.limit(active ? uploadKB : base.maxOverallUploadLimitKB)
        ]
    }

    private static func limit(_ kb: Int) -> String { kb > 0 ? "\(kb)K" : "0" }
}

nonisolated enum DownloadQueueOrder {
    static func position(moving id: String, before target: String?, in queue: [String]) -> Int? {
        guard queue.contains(id), id != target else { return nil }
        guard let target else { return 0 }
        return queue.filter { $0 != id }.firstIndex(of: target)
    }
}

extension UTType {
    nonisolated static let queuedDownload = UTType(exportedAs: "com.conight.ChopChop.queue-task", conformingTo: .data)
}

nonisolated struct QueuedDownloadReference: Codable, Transferable {
    var gid: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .queuedDownload)
    }
}

struct QueueReordering: ViewModifier {
    let store: DownloadStore
    let task: DownloadTask
    func body(content: Content) -> some View {
        if task.isAvailableInEngine && (task.status == .waiting || task.status == .paused) {
            content.draggable(QueuedDownloadReference(gid: task.id))
                .dropDestination(for: QueuedDownloadReference.self) { items, _ in
                    guard let first = items.first, items.count == 1, first.gid != task.id else { return false }
                    Task { await store.moveQueuedTask(first.gid, before: task.id) }
                    return true
                }
        } else { content }
    }
}

struct TaskScheduleView: View {
    @EnvironmentObject private var store: DownloadStore
    let task: DownloadTask
    @State private var date = Date().addingTimeInterval(3600)
    @State private var saving = false
    @State private var isExpanded: Bool
    init(task: DownloadTask, initiallyExpanded: Bool = false) {
        self.task = task
        _isExpanded = State(initialValue: initiallyExpanded)
    }
    var body: some View {
        if task.isAvailableInEngine && task.primaryControlAction != nil && !task.requiresFileSelection {
            DisclosureGroup(String(localized: "Scheduled Start"), isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    if let scheduled = task.scheduledStart {
                        Label(scheduled.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                        Text(store.armedScheduledTaskIDs.contains(task.id) ? String(localized: "Enabled while ChopChop is running.") : String(localized: "Paused after restart. Enable this schedule to allow an automatic start."))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if !store.armedScheduledTaskIDs.contains(task.id) {
                                Button(String(localized: "Enable Schedule")) { schedule(scheduled > Date() ? scheduled : Date().addingTimeInterval(60)) }
                            }
                            Button(String(localized: "Cancel Schedule")) { store.cancelSchedule(task.id) }
                        }
                    } else {
                        DatePicker(String(localized: "Start"), selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.field)
                        Button(String(localized: "Schedule Start")) { schedule(date) }
                        Text(String(localized: "Pauses this task until the selected time. Keep ChopChop open. After a restart, enable the schedule again."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let issue = store.downloadPlanIssue { Text(issue).font(.caption).foregroundStyle(.red) }
                }.padding(.top, 8).disabled(saving)
            }
        }
    }
    private func schedule(_ value: Date) {
        saving = true
        Task { await store.scheduleTask(task.id, at: value); saving = false }
    }
}

struct BandwidthScheduleView: View {
    @EnvironmentObject private var store: DownloadStore
    var body: some View {
        Section(String(localized: "Scheduled Bandwidth")) {
            Toggle(String(localized: "Use a daily bandwidth schedule"), isOn: $store.preferences.bandwidthSchedule.enabled)
            if store.preferences.bandwidthSchedule.enabled {
                DatePicker(String(localized: "From"), selection: timeBinding(\.startMinute), displayedComponents: .hourAndMinute)
                DatePicker(String(localized: "Until"), selection: timeBinding(\.endMinute), displayedComponents: .hourAndMinute)
                TextField(String(localized: "Download limit (KiB/s)"), value: $store.preferences.bandwidthSchedule.downloadKB, format: .number.grouping(.never))
                TextField(String(localized: "Upload limit (KiB/s)"), value: $store.preferences.bandwidthSchedule.uploadKB, format: .number.grouping(.never))
                Text(String(localized: "0 means unlimited. Uses local time; matching start and end means all day. Outside this window, the global limits apply. This does not start paused downloads."))
                    .font(.caption).foregroundStyle(.secondary)
                if let issue = store.preferences.bandwidthSchedule.validationIssue ?? store.bandwidthPlanIssue { Text(issue).foregroundStyle(.red) }
            }
        }
    }
    private func timeBinding(_ key: WritableKeyPath<BandwidthSchedule, Int>) -> Binding<Date> {
        Binding(get: {
            Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(store.preferences.bandwidthSchedule[keyPath: key]) * 60)
        }, set: { date in
            store.preferences.bandwidthSchedule[keyPath: key] = Calendar.current.component(.hour, from: date) * 60 + Calendar.current.component(.minute, from: date)
        })
    }
}
