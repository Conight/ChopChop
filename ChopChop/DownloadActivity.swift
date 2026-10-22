import Foundation

/// Bounded, credential-free observations. A recovered transition is observed now,
/// never presented as the time an unobserved engine transition actually happened.
nonisolated struct DownloadActivity: Codable, Hashable, Sendable {
    struct Event: Codable, Hashable, Identifiable, Sendable {
        var id = UUID()
        var date: Date
        var status: DownloadStatus
        var recovered: Bool
        var isSharing: Bool
        var error: String?
    }
    struct Sample: Codable, Hashable, Identifiable, Sendable {
        var date: Date
        var down: Int64
        var up: Int64
        var boundary: Bool
        var segment: Int
        var id: Date { date }
    }
    var events: [Event] = []
    var samples: [Sample] = []
    var observedDownloadBytes: Int64 = 0
    var activeSeconds: Double = 0
    var peakDownload: Int64 = 0
    var peakUpload: Int64 = 0
    var lastCompletedLength: Int64?
    var lastObservedAt: Date?
    var hasGap = false

    var averageDownload: Int64 { activeSeconds > 0 ? Int64(min(Double(Int64.max / 2), Double(observedDownloadBytes) / activeSeconds)) : 0 }

    static func observing(_ task: DownloadTask, previous: DownloadTask?, now: Date = Date()) -> Self {
        var result = previous?.activity ?? task.activity ?? Self()
        let changed = previous?.status != task.status || previous?.isSharing != task.isSharing || previous?.errorCode != task.errorCode || result.events.last?.status != task.status || result.events.last?.isSharing != task.isSharing
        let recovered = previous?.isAvailableInEngine == false
        if task.status != .active, !changed, !recovered, !result.events.isEmpty { return result }
        let elapsed = result.lastObservedAt.map { now.timeIntervalSince($0) } ?? 0
        let continuous = !recovered && previous?.isAvailableInEngine == true && elapsed > 0 && elapsed <= 15
        if recovered || elapsed > 15 || elapsed < 0 { result.hasGap = true }
        if changed || result.events.isEmpty || recovered {
            result.events.append(Event(date: now, status: task.status, recovered: recovered, isSharing: task.isSharing,
                                       error: task.errorMessage.map { String(DownloadPrivacy.redact($0).prefix(512)) }))
            result.events = Array(result.events.suffix(256))
        }
        if continuous, let previous, previous.status == .active {
            result.activeSeconds += elapsed
            let delta = max(0, max(0, task.completedLength) - max(0, result.lastCompletedLength ?? task.completedLength))
            let sum = result.observedDownloadBytes.addingReportingOverflow(delta)
            result.observedDownloadBytes = sum.overflow ? Int64.max : sum.partialValue
        }
        result.peakDownload = max(result.peakDownload, task.downloadSpeed)
        result.peakUpload = max(result.peakUpload, task.uploadSpeed)
        if task.status == .active || changed || recovered {
            result.samples.append(Sample(date: now, down: max(0, task.downloadSpeed), up: max(0, task.uploadSpeed), boundary: changed || recovered, segment: (result.samples.last?.segment ?? 0) + ((recovered || elapsed > 15 || elapsed < 0) ? 1 : 0)))
            result.compact()
        }
        result.lastCompletedLength = task.completedLength
        result.lastObservedAt = now
        return result
    }

    private mutating func compact() {
        guard samples.count > 96 else { return }
        // Preserve endpoints and both directional peaks. Prefer state boundaries,
        // then the points making the largest change to either plotted curve.
        var keep: Set<Int> = [0, samples.count - 1]
        if let peak = samples.indices.max(by: { samples[$0].down < samples[$1].down }) { keep.insert(peak) }
        if let peak = samples.indices.max(by: { samples[$0].up < samples[$1].up }) { keep.insert(peak) }
        for index in samples.indices.reversed() where samples[index].boundary && keep.count < 72 { keep.insert(index) }
        let ranked = (1..<(samples.count - 1)).sorted { a, b in
            func importance(_ i: Int) -> Double {
                let left = samples[i - 1], point = samples[i], right = samples[i + 1]
                let span = right.date.timeIntervalSince(left.date)
                guard span > 0 else { return 0 }
                let fraction = point.date.timeIntervalSince(left.date) / span
                return max(abs(Double(point.down) - (Double(left.down) + Double(right.down - left.down) * fraction)),
                           abs(Double(point.up) - (Double(left.up) + Double(right.up - left.up) * fraction)))
            }
            let x = importance(a), y = importance(b)
            return x == y ? a > b : x > y
        }
        for index in ranked where keep.count < 72 { keep.insert(index) }
        samples = keep.sorted().map { samples[$0] }
    }
}
