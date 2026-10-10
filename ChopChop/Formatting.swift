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
