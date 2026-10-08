import Foundation

/// Download progress is measured in bytes. Later stages have no estimated percentage.
nonisolated struct EngineInstallationProgress: Codable, Equatable, Sendable {
    enum Stage: String, Codable, Sendable {
        case checkingRelease, connecting, downloading, verifying, preparing, testing
        case savingDownloads, restarting, activating, restoring
    }

    var stage: Stage
    var completedBytes: Int64 = 0
    var totalBytes: Int64? = nil
    var bytesPerSecond: Double = 0

    var fractionCompleted: Double? {
        guard stage == .downloading, let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }

    var canCancel: Bool {
        switch stage {
        case .checkingRelease, .connecting, .downloading, .verifying, .preparing, .testing: true
        default: false
        }
    }

    var title: String {
        switch stage {
        case .checkingRelease: String(localized: "Checking the latest version…")
        case .connecting: String(localized: "Connecting to the download server…")
        case .downloading: String(localized: "Downloading Aria2 Next…")
        case .verifying: String(localized: "Verifying the download…")
        case .preparing: String(localized: "Preparing the engine…")
        case .testing: String(localized: "Checking the new engine…")
        case .savingDownloads: String(localized: "Saving your downloads…")
        case .restarting: String(localized: "Restarting the engine…")
        case .activating: String(localized: "Finishing installation…")
        case .restoring: String(localized: "Restoring the previous engine…")
        }
    }

    var transferDescription: String {
        let received = ByteCountFormatter.string(fromByteCount: max(0, completedBytes), countStyle: .file)
        if let totalBytes, totalBytes > 0 {
            return String(localized: "\(received) of \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))")
        }
        return String(localized: "\(received) downloaded")
    }

    var sidebarDescription: String {
        switch stage {
        case .checkingRelease: String(localized: "Checking version")
        case .connecting: String(localized: "Connecting")
        case .downloading: percentDescription.map { String(localized: "Downloading \($0)") } ?? String(localized: "Downloading")
        case .verifying: String(localized: "Verifying")
        case .preparing, .testing: String(localized: "Preparing")
        case .savingDownloads: String(localized: "Saving downloads")
        case .restarting: String(localized: "Restarting")
        case .activating: String(localized: "Finishing")
        case .restoring: String(localized: "Restoring")
        }
    }

    var percentDescription: String? {
        fractionCompleted.map { $0.formatted(.percent.precision(.fractionLength(0))) }
    }

    var speedDescription: String? {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0, bytesPerSecond < Double(Int64.max) else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }
}

nonisolated struct EngineVersion: Comparable, Codable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    var description: String { "\(major).\(minor).\(patch)" }
    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

nonisolated struct EngineRelease: Equatable, Sendable, Identifiable {
    var version: EngineVersion
    var downloadURL: URL
    var checksumURL: URL
    var id: String { version.description }
    var pageURL: URL { URL(string: "https://github.com/AnInsomniacy/aria2-next/releases/tag/v\(version)")! }
}

nonisolated enum EngineInstallationError: LocalizedError {
    case invalidRelease, invalidChecksum, invalidExecutable, unexpectedResponse(Int), installationFailed(String)
    var errorDescription: String? {
        switch self {
        case .invalidRelease: String(localized: "The latest stable release does not contain a supported Apple Silicon engine.")
        case .invalidChecksum: String(localized: "The downloaded engine did not match its official SHA-256 checksum. Please retry.")
        case .invalidExecutable: String(localized: "The downloaded file is not a supported Apple Silicon Aria2 Next executable.")
        case .unexpectedResponse(let code): String(localized: "The download server returned HTTP \(code). Please try again later.")
        case .installationFailed(let message): String(localized: "Could not install Aria2 Next. \(message)")
        }
    }
}
