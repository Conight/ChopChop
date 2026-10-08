import AppKit
import Combine
import CryptoKit
import Darwin
import SwiftUI

nonisolated enum FileDigestAlgorithm: String, CaseIterable, Identifiable, Sendable {
    case sha256 = "SHA-256", sha512 = "SHA-512", sha1 = "SHA-1", md5 = "MD5"
    var id: String { rawValue }
    var hexLength: Int { switch self { case .sha256: 64; case .sha512: 128; case .sha1: 40; case .md5: 32 } }
    var isLegacy: Bool { self == .sha1 || self == .md5 }
    func normalizedExpected(_ text: String) throws -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        guard value.count == hexLength, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw DownloadOperationError(String(localized: "Enter a \(hexLength)-character hexadecimal \(rawValue) checksum."))
        }
        return value
    }
}

nonisolated enum FileDigest {
    @concurrent
    static func compute(_ url: URL, algorithm: FileDigestAlgorithm,
                        progress: @escaping @Sendable (Double) async -> Void = { _ in }) async throws -> String {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        switch algorithm {
        case .sha256: return try await hash(url, using: SHA256.self, progress: progress)
        case .sha512: return try await hash(url, using: SHA512.self, progress: progress)
        case .sha1: return try await hash(url, using: Insecure.SHA1.self, progress: progress)
        case .md5: return try await hash(url, using: Insecure.MD5.self, progress: progress)
        }
    }

    private static func hash<H: HashFunction>(_ url: URL, using: H.Type,
                                              progress: @escaping @Sendable (Double) async -> Void) async throws -> String {
        try Task.checkCancellation()
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(handle.fileDescriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else {
            throw DownloadOperationError(String(localized: "Choose a regular downloaded file."))
        }
        var hasher = H()
        var count: Int64 = 0
        var reported: Double = -1
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
            count += Int64(chunk.count)
            let fraction = before.st_size > 0 ? min(1, Double(count) / Double(before.st_size)) : 1
            if fraction - reported >= 0.01 { await progress(fraction); reported = fraction }
        }
        try Task.checkCancellation()
        var after = stat()
        var pathAfter = stat()
        guard stat(url.path, &pathAfter) == 0, pathAfter.st_dev == before.st_dev, pathAfter.st_ino == before.st_ino,
              fstat(handle.fileDescriptor, &after) == 0, count == before.st_size,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw DownloadOperationError(String(localized: "The file changed during verification. Wait for it to finish and try again."))
        }
        await progress(1)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class FileVerificationCoordinator: ObservableObject {
    @Published private(set) var progress: Double?
    @Published private(set) var digest: String?
    @Published private(set) var issue: String?
    private var work: Task<Void, Never>?
    private var generation = UUID()

    func verify(_ url: URL, algorithm: FileDigestAlgorithm) {
        cancel()
        let request = UUID(); generation = request
        progress = 0; digest = nil; issue = nil
        work = Task { [weak self] in
            do {
                let result = try await FileDigest.compute(url, algorithm: algorithm) { [weak self] value in
                    await self?.report(value, generation: request)
                }
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.digest = result; self.progress = nil; self.work = nil
            } catch is CancellationError { }
            catch {
                guard let self, self.generation == request else { return }
                self.issue = DownloadPrivacy.redact(error.localizedDescription); self.progress = nil; self.work = nil
            }
        }
    }
    private func report(_ value: Double, generation: UUID) {
        guard self.generation == generation else { return }
        progress = value
    }
    func cancel() { generation = UUID(); work?.cancel(); work = nil; progress = nil }
    func reset() { cancel(); digest = nil; issue = nil }
}

struct FileVerificationView: View {
    let file: DownloadFile
    @StateObject private var verifier = FileVerificationCoordinator()
    @State private var algorithm = FileDigestAlgorithm.sha256
    @State private var expected = ""
    @State private var inputIssue: String?
    @State private var selectedURL: URL?
    @State private var isExpanded: Bool
    init(file: DownloadFile, initiallyExpanded: Bool = false) {
        self.file = file
        _isExpanded = State(initialValue: initiallyExpanded)
    }
    var body: some View {
        DisclosureGroup(String(localized: "Verify Checksum"), isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let selectedURL { Text(String(localized: "File: \(selectedURL.lastPathComponent)")).font(.caption).textSelection(.enabled) }
                Picker(String(localized: "Algorithm"), selection: $algorithm) {
                    ForEach(FileDigestAlgorithm.allCases) { Text($0.rawValue).tag($0) }
                }
                TextField(String(localized: "Expected checksum (optional)"), text: $expected, axis: .vertical)
                    .nativeTextFieldStyle().lineLimit(2...4)
                if algorithm.isLegacy {
                    Text(String(localized: "Use SHA-256 or SHA-512 when available. MD5 and SHA-1 are provided for older published checksums."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let progress = verifier.progress {
                    ProgressView(value: progress)
                    HStack {
                        Text(String(localized: "Verifying \(Int(progress * 100))%"))
                        Button(String(localized: "Cancel")) { verifier.cancel() }
                    }
                } else {
                    Button(String(localized: "Calculate Checksum")) { calculate() }
                }
                if let digest = verifier.digest {
                    Text(digest).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let value = try? algorithm.normalizedExpected(expected) {
                        Label(digest == value ? String(localized: "Checksum matches") : String(localized: "Checksum does not match"),
                              systemImage: digest == value ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(digest == value ? .green : .red)
                    }
                    Button(String(localized: "Copy Checksum")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(digest, forType: .string) }
                }
                if let issue = inputIssue ?? verifier.issue {
                    Text(issue).font(.caption).foregroundStyle(.red)
                    Button(String(localized: "Locate Downloaded File…")) { locate() }
                }
            }.padding(.top, 8)
        }
        .onChange(of: algorithm) { _, _ in verifier.reset(); inputIssue = nil }
        .onChange(of: expected) { _, _ in inputIssue = (try? algorithm.normalizedExpected(expected)) == nil && !expected.trimmedForEngine.isEmpty ? String(localized: "Check the checksum length and hexadecimal characters.") : nil }
        .onDisappear { verifier.cancel() }
    }
    private func calculate() {
        do {
            _ = try algorithm.normalizedExpected(expected)
            inputIssue = nil
            verifier.verify(selectedURL ?? URL(fileURLWithPath: file.path), algorithm: algorithm)
        } catch { inputIssue = error.localizedDescription }
    }
    private func locate() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose the downloaded file to verify.")
        if panel.runModal() == .OK, let url = panel.url { selectedURL = url; calculate() }
    }
}
