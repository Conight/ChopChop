import Foundation

nonisolated enum DownloadRefreshPolicy {
    static func interval(foreground: Bool, hasTransfers: Bool, failures: Int) -> Duration {
        if failures > 0 { return .seconds(min(60, 5 * (1 << min(failures, 4)))) }
        if foreground { return .seconds(hasTransfers ? 2 : 8) }
        return .seconds(hasTransfers ? 5 : 30)
    }
    /// Scheduling uses its own clock, regardless of foreground state or RPC refresh backoff.
    static func planDelay(now: Date, deadlines: [Date], bandwidthEnabled: Bool) -> Duration {
        let nextTask = deadlines.min().map { max(0.1, $0.timeIntervalSince(now)) } ?? 60
        let nextMinute = 60 - now.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
        return .seconds(min(60, min(nextTask, bandwidthEnabled ? max(0.1, nextMinute) : 60)))
    }
}
