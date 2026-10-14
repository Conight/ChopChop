import Foundation

nonisolated extension String {
    var trimmedForEngine: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nonEmptyValue: String? {
        isEmpty ? nil : self
    }
}

nonisolated enum ByteFormat {
    struct DisplayParts {
        let count: String
        let unit: String
    }

    /// Separate visual columns without parsing localized formatter output.
    /// Use the standard byte symbol in compact metrics; spoken values retain
    /// the full ByteCountFormatter wording through size/speed.
    static func displayParts(_ bytes: Int64) -> DisplayParts {
        guard bytes > 0 else { return DisplayParts(count: "0", unit: "KB") }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesUnit = false
        let count = formatter.string(fromByteCount: bytes)
        formatter.includesCount = false
        formatter.includesUnit = true
        return DisplayParts(count: count, unit: bytes < 1_000 ? UnitInformationStorage.bytes.symbol : formatter.string(fromByteCount: bytes))
    }

    static let displayUnits = [Int64(1), 1_000, 1_000_000, 1_000_000_000, 1_000_000_000_000,
                               1_000_000_000_000_000, 1_000_000_000_000_000_000].map { displayParts($0).unit }

    static func size(_ bytes: Int64) -> String {
        let clampedBytes = max(0, bytes)
        guard clampedBytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: clampedBytes, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Int64) -> String {
        "\(size(bytesPerSecond))/s"
    }

    static func duration(_ seconds: Int) -> String {
        let clampedSeconds = max(0, seconds)
        if clampedSeconds < 60 {
            return String(localized: "\(clampedSeconds)s")
        }

        let minutes = clampedSeconds / 60
        let remainingSeconds = clampedSeconds % 60
        if minutes < 60 {
            return String(localized: "\(minutes)m \(remainingSeconds)s")
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return String(localized: "\(hours)h \(remainingMinutes)m")
    }
}
