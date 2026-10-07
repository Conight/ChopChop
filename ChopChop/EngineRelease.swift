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
        case .checkingRelease: "Checking the latest version…"
        case .connecting: "Connecting to the download server…"
        case .downloading: "Downloading Aria2 Next…"
        case .verifying: "Verifying the download…"
        case .preparing: "Preparing the engine…"
        case .testing: "Checking the new engine…"
        case .savingDownloads: "Saving your downloads…"
        case .restarting: "Restarting the engine…"
        case .activating: "Finishing installation…"
        case .restoring: "Restoring the previous engine…"
        }
    }

    var transferDescription: String {
        let received = ByteCountFormatter.string(fromByteCount: max(0, completedBytes), countStyle: .file)
        if let totalBytes, totalBytes > 0 {
            return "\(received) of \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
        }
        return "\(received) downloaded"
    }

    var sidebarDescription: String {
        switch stage {
        case .checkingRelease: "Checking version"
        case .connecting: "Connecting"
        case .downloading: percentDescription.map { "Downloading \($0)" } ?? "Downloading"
        case .verifying: "Verifying"
        case .preparing, .testing: "Preparing"
        case .savingDownloads: "Saving downloads"
        case .restarting: "Restarting"
        case .activating: "Finishing"
        case .restoring: "Restoring"
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
        case .invalidRelease: "The latest stable release does not contain a supported Apple Silicon engine."
        case .invalidChecksum: "The downloaded engine did not match its official SHA-256 checksum. Please retry."
        case .invalidExecutable: "The downloaded file is not a supported Apple Silicon Aria2 Next executable."
        case .unexpectedResponse(let code): "The download server returned HTTP \(code). Please try again later."
        case .installationFailed(let message): "Could not install Aria2 Next. \(message)"
        }
    }
}
