import Foundation

/// App releases include prerelease identifiers; engine versions deliberately remain separate.
nonisolated struct AppVersion: Equatable, Comparable, Codable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    init?(_ input: String) {
        let text = input.hasPrefix("v") ? String(input.dropFirst()) : input
        let build = text.split(separator: "+", omittingEmptySubsequences: false)
        guard build.count <= 2 else { return nil }
        func validIdentifiers(_ value: Substring) -> Bool {
            value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
            }
        }
        if build.count == 2 && !validIdentifiers(build[1]) { return nil }
        let parts = build[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3, numbers.allSatisfy({
            !$0.isEmpty && ($0.count == 1 || $0.first != "0") && $0.utf8.allSatisfy { (48...57).contains($0) }
        }), let major = Int(numbers[0]), let minor = Int(numbers[1]), let patch = Int(numbers[2]) else { return nil }
        let identifiers = parts.count == 2 ? parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
        if parts.count == 2 {
            guard validIdentifiers(parts[1]), identifiers.allSatisfy({
                !$0.allSatisfy(\.isNumber) || $0.count == 1 || $0.first != "0"
            }) else { return nil }
        }
        self.major = major; self.minor = minor; self.patch = patch; prerelease = identifiers
    }

    var description: String { "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: ".")) }
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = Self(text) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid app version") }
        self = value
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        let a = (lhs.major, lhs.minor, lhs.patch), b = (rhs.major, rhs.minor, rhs.patch)
        if a != b { return a < b }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            let an = a.allSatisfy(\.isNumber), bn = b.allSatisfy(\.isNumber)
            if an != bn { return an }
            if an && a.count != b.count { return a.count < b.count }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
