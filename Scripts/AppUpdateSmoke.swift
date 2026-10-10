import AppKit
import CryptoKit
import Foundation

@main struct AppUpdateSmoke {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: message, code: 1) }
    }
    static func main() throws {
        let args = CommandLine.arguments
        if args[1] == "download-release" {
            // Explicit, opt-in read-only verification against a published release; never opens or installs it.
            Task {
                do {
                    let archive = AppUpdateArchive(version: AppVersion(args[2])!, size: Int64(args[3])!, sha256: args[4])
                    let package = try await AppUpdateArchiveDownloader(directory: URL(fileURLWithPath: args[5]), assetURL: { version, name in
                        URL(string: "https://github.com/\(args[6])/releases/download/v\(version)/\(name)")!
                    }).download(archive, progress: { _ in })
                    try await package.verify()
                    print("Downloaded and verified \(package.url.lastPathComponent) (\(package.size) bytes)")
                    exit(0)
                } catch { fputs("Direct release download failed: \(error)\n", stderr); exit(1) }
            }
            dispatchMain()
        }
        if args[1] == "transfer" {
            Task {
                do { try await transfer(base: args[2], root: URL(fileURLWithPath: args[3])); exit(0) }
                catch { fputs("Transfer smoke failed: \(error)\n", stderr); exit(1) }
            }
            dispatchMain()
        }
        if args[1] == "key" {
            let key = Curve25519.Signing.PrivateKey()
            try key.rawRepresentation.base64EncodedString().write(toFile: args[2], atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: args[2])
            print(key.publicKey.rawRepresentation.base64EncodedString()); return
        }
        if args[1] == "verify-signed" {
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: String(contentsOfFile: args[2], encoding: .utf8))!)
            let envelope = try JSONDecoder().decode(SignedAppUpdate.self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
            let manifest = try envelope.verified(publicKey: key.publicKey.rawRepresentation.base64EncodedString(), version: AppVersion("1.0.0-beta.2")!, bundleIdentifier: "org.example.ChopChopFork")
            try manifest.verifyArchive(URL(fileURLWithPath: args[4]))
            print("Passed signed DMG packaging and manifest round trip")
            return
        }
        let root = URL(fileURLWithPath: args[2]).resolvingSymlinksInPath()
        let target = root.appendingPathComponent("ChopChop.app")
        let stage = root.appendingPathComponent(".ChopChop-update-00000000-0000-4000-8000-000000000001")
        let candidate = stage.appendingPathComponent("ChopChop.app")
        let encodedKey = try String(contentsOf: root.appendingPathComponent("key"), encoding: .utf8)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: encodedKey)!)
        let version = AppVersion("1.0.0-beta.2")!
        let manifest = AppUpdateManifest(schema: 1, version: version.description, buildNumber: "2", bundleIdentifier: "org.example.ChopChopFork",
            architecture: "arm64", minimumSystemVersion: "26.5", filename: AppUpdateManifest.filename(for: version), size: 1,
            sha256: String(repeating: "a", count: 64), codeDirectoryHash: try AppUpdateManifest.codeHash(at: candidate))
        let payload = try JSONEncoder().encode(manifest)
        let signed = try JSONEncoder().encode(SignedAppUpdate(payload: payload, signature: key.signature(for: payload)))
        var pid: Int32 = 0
        if args[1].hasPrefix("worker") || args[1] == "waiting" {
            try AppUpdateInstallation.openAndWait(target)
            let parent = try unwrap(NSWorkspace.shared.runningApplications.first { $0.bundleURL?.resolvingSymlinksInPath() == target })
            pid = parent.processIdentifier
        }
        let job = AppUpdateInstallation.Job(target: target, directory: stage, manifest: manifest, signedManifest: signed,
            publicKey: key.publicKey.rawRepresentation.base64EncodedString(), originalInode: try AppUpdateInstallation.inode(target), parentPID: pid)
        if args[1] == "resume" {
            try JSONEncoder().encode(job).write(to: stage.appendingPathComponent("job.json"), options: .atomic)
            let resumed = try unwrap(AppUpdateInstallation.resume(version: version, target: target, parentPID: 123))
            try require(resumed.parentPID == 123 && resumed.directory == stage, "Prepared update did not recover for new app process")
            try JSONEncoder().encode(getpid()).write(to: stage.appendingPathComponent("worker-ready"))
            do { _ = try AppUpdateInstallation.resume(version: version, target: target, parentPID: 456); throw NSError(domain: "Accepted another process's worker", code: 2) }
            catch AppUpdateError.installerUnavailable {}
            try require(try AppUpdateInstallation.resume(version: version, target: target, parentPID: 123)?.parentPID == 123, "Could not reconnect to the same process's worker")
            try FileManager.default.removeItem(at: stage.appendingPathComponent("worker-ready"))
            try Data("tampered recovery".utf8).write(to: candidate.appendingPathComponent("Contents/Resources/change"))
            do { _ = try AppUpdateInstallation.resume(version: version, target: target, parentPID: 123); throw NSError(domain: "Accepted tampered recovery", code: 2) }
            catch AppUpdateError.invalidApplication {}
        } else if args[1] == "waiting" {
            let parent = try unwrap(NSRunningApplication(processIdentifier: pid))
            defer { _ = parent.terminate() }
            do { try AppUpdateInstallation.waitForTermination(of: parent, timeout: 0.1); throw NSError(domain: "Ignored running app", code: 2) }
            catch AppUpdateError.terminationTimedOut {}
            try require(!parent.isTerminated, "Timeout forcibly terminated the app")
            try require(try AppUpdateInstallation.inode(target) == job.originalInode, "Timeout changed the installed app")
            try require(FileManager.default.fileExists(atPath: candidate.path), "Timeout removed the prepared update")
        } else if args[1] == "tamper" {
            try Data("tamper".utf8).write(to: candidate.appendingPathComponent("Contents/Resources/change"))
            _ = try AppUpdateInstallation.run("/usr/bin/codesign", ["--force", "--sign", "-", candidate.path], timeout: 20)
            do { try AppUpdateInstallation.exchange(job); throw NSError(domain: "Accepted re-signed substitute", code: 2) }
            catch AppUpdateError.invalidApplication {}
            try require(try AppUpdateInstallation.inode(target) == job.originalInode, "Tampering changed installed app")
        } else if args[1] == "rollback" {
            var launches = 0
            do {
                try AppUpdateInstallation.finishInstallation(job, launch: { _, _ in launches += 1; throw AppUpdateError.installationFailed }, isRunning: { _ in false })
                throw NSError(domain: "Expected launch failure", code: 2)
            } catch AppUpdateError.installationFailed {}
            try require(launches == 2, "Rollback must reopen the old app")
            try require(try AppUpdateInstallation.inode(target) == job.originalInode, "Rollback lost original app")
        } else if args[1] == "success" {
            try AppUpdateInstallation.finishInstallation(job, launch: { _, _ in }, isRunning: { _ in false })
            try require(try AppUpdateInstallation.inode(target) != job.originalInode, "Successful exchange did not replace app")
            try require(!FileManager.default.fileExists(atPath: stage.path), "Successful exchange left backup")
        } else if args[1].hasPrefix("worker") {
            let file = stage.appendingPathComponent("job.json")
            try JSONEncoder().encode(job).write(to: file)
            let worker = Process()
            worker.executableURL = target.appendingPathComponent("Contents/XPCServices/EngineInstaller.xpc/Contents/MacOS/EngineInstaller")
            worker.arguments = ["--apply-app-update", file.path]
            try worker.run()
            defer {
                for app in NSWorkspace.shared.runningApplications where app.bundleURL?.resolvingSymlinksInPath() == target { _ = app.terminate() }
                if worker.isRunning { worker.terminate() }
            }
            try wait { FileManager.default.fileExists(atPath: stage.appendingPathComponent("worker-ready").path) || !worker.isRunning }
            try require(worker.isRunning, "Worker exited before acknowledging readiness")
            try require(getpgid(worker.processIdentifier) == worker.processIdentifier, "Worker shares the XPC service process group")
            try require(try AppUpdateInstallation.inode(target) == job.originalInode, "Worker replaced app before it quit")
            try require(NSRunningApplication(processIdentifier: pid)?.terminate() == true, "Could not terminate fixture")
            try wait { !worker.isRunning }
            if args[1] == "worker-failure" {
                try require(worker.terminationStatus != 0, "Failing launch did not report failure")
                try require(try AppUpdateInstallation.inode(target) == job.originalInode, "Failed launch did not restore original app")
            } else {
                try require(worker.terminationStatus == 0, "Detached worker failed")
                try require(try AppUpdateInstallation.inode(target) != job.originalInode, "Worker did not install update")
            }
            try require(!FileManager.default.fileExists(atPath: stage.path), "Worker left stage after successful launch")
        }
        try require(try String(contentsOf: root.appendingPathComponent("user-data"), encoding: .utf8) == "untouched", "Installation modified user data")
        print("Passed update \(args[1])")
    }
    static func unwrap<T>(_ value: T?) throws -> T { guard let value else { throw AppUpdateError.installationFailed }; return value }
    static func wait(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(25)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        try require(condition(), "Timed out waiting for worker")
    }
    final class ProgressLog: @unchecked Sendable {
        let lock = NSLock(); var values: [AppUpdateProgress] = []
        func append(_ value: AppUpdateProgress) { lock.withLock { values.append(value) } }
    }
    static func transfer(base: String, root: URL) async throws {
        for endpoint in ["ok", "paced", "chunked", "oversized", "short", "not-found", "slow"] {
            let file = root.appendingPathComponent(endpoint)
            let log = ProgressLog()
            let task = Task { try await AppUpdateTransfer(destination: file, expectedSize: 1_048_576, progress: { log.append($0) }).receive(from: URL(string: base + "/" + endpoint)!) }
            if endpoint == "slow" { try await Task.sleep(for: .milliseconds(200)); task.cancel() }
            do {
                try await task.value
                try require(["ok", "paced", "chunked"].contains(endpoint), "Invalid response was accepted: \(endpoint)")
                try require(try Data(contentsOf: file) == Data(repeating: 65, count: 1_048_576), "Transfer bytes differ")
                let samples = log.lock.withLock { log.values }
                try require(samples.first?.completedBytes == 0 && samples.first?.fraction == 0, "Missing initial download progress")
                try require(samples.last?.completedBytes == 1_048_576 && samples.last?.fraction == 1, "Progress missing")
                try require(zip(samples, samples.dropFirst()).allSatisfy { $0.completedBytes <= $1.completedBytes }, "Progress went backwards")
                if endpoint == "paced" {
                    try require(samples.contains { $0.completedBytes > 0 && $0.completedBytes < 1_048_576 && $0.bytesPerSecond > 0 }, "No measured intermediate progress")
                }
            } catch {
                if ["ok", "paced", "chunked"].contains(endpoint) { throw error }
                if endpoint == "slow" { try require(error is CancellationError, "Cancellation error lost") }
                try require(!FileManager.default.fileExists(atPath: file.path), "Failed transfer left accepted payload")
            }
        }
        let version = AppVersion("1.0.0-beta.2")!
        let bytes = Data(repeating: 65, count: 1_048_576)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        for endpoint in ["ok", "checksum", "bad-hash", "slow"] {
            let directory = root.appendingPathComponent("installer-" + endpoint)
            let downloader = AppUpdateArchiveDownloader(directory: directory, assetURL: { _, name in
                URL(string: base + (name.hasSuffix(".sha256") ? "/checksum" : (endpoint == "slow" ? "/slow" : "/ok")))!
            })
            let digest = endpoint == "checksum" ? nil : (endpoint == "bad-hash" ? String(repeating: "b", count: 64) : hash)
            let task = Task { try await downloader.download(.init(version: version, size: Int64(bytes.count), sha256: digest), progress: { _ in }) }
            if endpoint == "slow" { try await Task.sleep(for: .milliseconds(200)); task.cancel() }
            if ["bad-hash", "slow"].contains(endpoint) {
                do { _ = try await task.value; throw NSError(domain: "Accepted invalid direct download", code: 3) }
                catch AppUpdateError.invalidSignature { try require(endpoint == "bad-hash", "Unexpected verification failure") }
                catch is CancellationError { try require(endpoint == "slow", "Unexpected cancellation") }
                try require(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty, "Failed direct download left temporary files")
            } else {
                let package = try await task.value
                try await package.verify()
                try require(package.url.lastPathComponent == AppUpdateManifest.filename(for: version), "Installer lost its canonical name")
            }
        }
        print("Passed local HTTP streaming, unknown length, size rejection, truncation, HTTP failure, direct installer checksum verification and cancellation cleanup")
    }
}
