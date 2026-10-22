import Foundation

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


}


nonisolated struct TemporaryBandwidthLimit: Codable, Equatable, Sendable {
    var enabled = false
    var downloadKiB = 2048
    var uploadKiB = 128
    var expiresAt: Date?
    var validationIssue: String? {
        guard (0...Int(Int32.max)).contains(downloadKiB), (0...Int(Int32.max)).contains(uploadKiB) else {
            return String(localized: "Enter bandwidth limits between zero and 2147483647 KiB/s.")
        }
        return nil
    }
    func isActive(at date: Date) -> Bool { enabled && (expiresAt.map { $0 > date } ?? true) }
}

nonisolated struct EffectiveBandwidth: Equatable, Sendable {
    enum Reason: Sendable { case global, schedule, temporary }
    var downloadKiB: Int
    var uploadKiB: Int
    var reason: Reason
    var options: [String: String] {
        ["max-overall-download-limit": downloadKiB > 0 ? "\(downloadKiB)K" : "0",
         "max-overall-upload-limit": uploadKiB > 0 ? "\(uploadKiB)K" : "0"]
    }
    static func compute(baseDownload: Int, baseUpload: Int, schedule: BandwidthSchedule,
                        temporary: TemporaryBandwidthLimit, now: Date) -> Self {
        let scheduled = schedule.contains(now)
        func bounded(_ value: Int) -> Int { min(Int(Int32.max), max(0, value)) }
        var result = Self(downloadKiB: bounded(scheduled ? schedule.downloadKB : baseDownload),
                          uploadKiB: bounded(scheduled ? schedule.uploadKB : baseUpload), reason: scheduled ? .schedule : .global)
        if temporary.isActive(at: now) {
            func minimumCap(_ a: Int, _ b: Int) -> Int { [a, min(Int(Int32.max), max(0, b))].filter { $0 > 0 }.min() ?? 0 }
            result.downloadKiB = minimumCap(result.downloadKiB, temporary.downloadKiB)
            result.uploadKiB = minimumCap(result.uploadKiB, temporary.uploadKiB)
            result.reason = .temporary
        }
        return result
    }
}
