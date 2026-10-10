import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

/// Shared by the authenticated XPC service and its detached installation worker.
/// Jobs are staged beside the installed app so replacement is an atomic filesystem exchange.
nonisolated enum AppUpdateInstallation {
    struct Job: Codable, Sendable {
        let target: URL
        let directory: URL
        let manifest: AppUpdateManifest
        let signedManifest: Data
        let publicKey: String
        let originalInode: UInt64
        let parentPID: Int32
        var candidate: URL { directory.appendingPathComponent(AppUpdateStorage.applicationName) }
    }

    static func installedApp() -> URL {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    static func inode(_ url: URL) throws -> UInt64 {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeDirectory,
              let value = values[.systemFileNumber] as? NSNumber else { throw AppUpdateError.installLocation }
        return value.uint64Value
    }
    static func validateLocation(_ target: URL) throws {
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent()
        guard target.pathExtension == "app", target == target.resolvingSymlinksInPath(),
              !target.path.contains("/AppTranslocation/"),
              fm.isWritableFile(atPath: parent.path), fm.isWritableFile(atPath: target.path),
              try target.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly == false else {
            throw AppUpdateError.installLocation
        }
    }

    @concurrent static func prepare(version: AppVersion, target: URL, parentPID: Int32,
                                   progress: @escaping @Sendable (AppUpdateProgress) -> Void) async throws -> Job {
        try validateLocation(target)
        guard let current = Bundle(url: target),
              let configuration = try? ReleaseConfiguration(bundle: current),
              current.bundleIdentifier == configuration.bundleIdentifier else { throw AppUpdateError.signingNotConfigured }
        let publicKey = configuration.publicKey
        if let tag = current.object(forInfoDictionaryKey: "ChopChopReleaseVersion") as? String,
           let installed = AppVersion(tag), version <= installed { throw AppUpdateError.invalidApplication }
        progress(.init(stage: .connecting))
        let session = URLSession(configuration: EngineDownload.configuration(timeout: 30))
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: configuration.assetURL(version: version, name: AppUpdateManifest.manifestName(for: version)))
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < AppUpdateManifest.maximumEnvelopeSize else { throw AppUpdateError.downloadFailed }
        guard let envelope = try? JSONDecoder().decode(SignedAppUpdate.self, from: data) else { throw AppUpdateError.invalidSignature }
        let manifest = try envelope.verified(publicKey: publicKey, version: version, bundleIdentifier: configuration.bundleIdentifier)
        try validateSystem(manifest.minimumSystemVersion)
        let directory = target.deletingLastPathComponent().appendingPathComponent(AppUpdateStorage.stagingPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
        let archive = directory.appendingPathComponent("update.dmg")
        try await AppUpdateTransfer(destination: archive, expectedSize: manifest.size, progress: progress)
            .receive(from: configuration.assetURL(version: version, name: manifest.filename))
        try Task.checkCancellation()
        progress(.init(stage: .verifying))
        try manifest.verifyArchive(archive)
        try Task.checkCancellation()
        progress(.init(stage: .preparing))
        let mount = directory.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        _ = try await EngineDownload.runTool("/usr/bin/hdiutil", arguments: ["attach", archive.path, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path], timeoutInterval: 60)
        do {
            let source = mount.appendingPathComponent(AppUpdateStorage.applicationName)
            try validateBundle(source, manifest: manifest, publicKey: publicKey, current: target)
            _ = try await EngineDownload.runTool("/usr/bin/ditto", arguments: [source.path, directory.appendingPathComponent(AppUpdateStorage.applicationName).path], timeoutInterval: 120)
        } catch {
            _ = try? run("/usr/bin/hdiutil", ["detach", mount.path], timeout: 20)
            throw error
        }
        _ = try run("/usr/bin/hdiutil", ["detach", mount.path], timeout: 20)
        try Task.checkCancellation()
        let job = Job(target: target, directory: directory, manifest: manifest, signedManifest: data,
                      publicKey: publicKey, originalInode: try inode(target), parentPID: parentPID)
        try validateBundle(job.candidate, manifest: manifest, publicKey: publicKey, current: target)
        try JSONEncoder().encode(job).write(to: directory.appendingPathComponent(AppUpdateStorage.jobFile), options: .atomic)
        try FileManager.default.removeItem(at: archive)
        try? FileManager.default.removeItem(at: mount)
        complete = true
        return job
    }

    static func validateSystem(_ minimum: String) throws {
        let components = minimum.split(separator: ".", omittingEmptySubsequences: false)
        let parts = components.compactMap { Int($0) }
        guard parts.count == components.count, (2...3).contains(parts.count), parts.allSatisfy({ $0 >= 0 }),
              ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: parts[0], minorVersion: parts[1], patchVersion: parts.count == 3 ? parts[2] : 0)) else {
            throw AppUpdateError.unsupportedSystem
        }
    }

    static func validateBundle(_ url: URL, manifest: AppUpdateManifest, publicKey: String, current: URL) throws {
        // Read the plist afresh: Bundle caches metadata for a URL across an atomic exchange.
        let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        guard url == url.resolvingSymlinksInPath(),
              let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == manifest.bundleIdentifier,
              let installedBundle = Bundle(url: current),
              let installedConfiguration = try? ReleaseConfiguration(bundle: installedBundle),
              installedBundle.bundleIdentifier == installedConfiguration.bundleIdentifier,
              let candidateConfiguration = try? ReleaseConfiguration(info: info),
              candidateConfiguration == installedConfiguration,
              info["CFBundleExecutable"] as? String == "ChopChop",
              info["ChopChopReleaseVersion"] as? String == "v" + manifest.version,
              info["CFBundleVersion"] as? String == manifest.buildNumber,
              info["LSMinimumSystemVersion"] as? String == manifest.minimumSystemVersion,
              info["ChopChopUpdatePublicKey"] as? String == publicKey,
              try AppUpdateManifest.codeHash(at: url) == manifest.codeDirectoryHash else {
            throw AppUpdateError.invalidApplication
        }
        try validateSystem(manifest.minimumSystemVersion)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures), nil) == errSecSuccess else {
            throw AppUpdateError.invalidApplication
        }
        func team(_ path: URL) -> String? {
            var code: SecStaticCode?; var info: CFDictionary?
            guard SecStaticCodeCreateWithPath(path as CFURL, [], &code) == errSecSuccess, let code,
                  SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
            return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        }
        if let currentTeam = team(current), team(url) != currentTeam { throw AppUpdateError.invalidApplication }
        let executable = url.appendingPathComponent("Contents/MacOS/ChopChop")
        let handle = try FileHandle(forReadingFrom: executable); defer { try? handle.close() }
        guard try handle.read(upToCount: 8) == Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1]) else { throw AppUpdateError.invalidApplication }
        // Framework symlinks are allowed only when they resolve inside the verified bundle.
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { throw AppUpdateError.invalidApplication }
        for case let file as URL in files {
            if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true,
               !file.resolvingSymlinksInPath().path.hasPrefix(url.path + "/") { throw AppUpdateError.invalidApplication }
        }
    }

    /// Recover only a package authenticated by this installed app's pinned key.
    static func resume(version: AppVersion, target: URL, parentPID: Int32) throws -> Job? {
        try validateLocation(target)
        guard let current = Bundle(url: target),
              let configuration = try? ReleaseConfiguration(bundle: current),
              current.bundleIdentifier == configuration.bundleIdentifier else { throw AppUpdateError.signingNotConfigured }
        let key = configuration.publicKey
        if let tag = current.object(forInfoDictionaryKey: "ChopChopReleaseVersion") as? String,
           let installed = AppVersion(tag), version <= installed { return nil }
        let parent = target.deletingLastPathComponent()
        for entry in try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink == false,
                  AppUpdateStorage.isStagingDirectory(entry) else { continue }
            // Directory enumeration may return /private/tmp while Foundation normalizes it to /tmp.
            // Reject links explicitly, then compare normalized parents instead of their URL spelling.
            let directory = entry.resolvingSymlinksInPath()
            guard directory.deletingLastPathComponent() == parent else { continue }
            let file = directory.appendingPathComponent(AppUpdateStorage.jobFile)
            guard let data = try? Data(contentsOf: file), data.count < 131_072,
                  let old = try? JSONDecoder().decode(Job.self, from: data), old.manifest.version == version.description else { continue }
            guard old.target == target, old.directory == directory, old.publicKey == key,
                  try inode(target) == old.originalInode,
                  try JSONDecoder().decode(SignedAppUpdate.self, from: old.signedManifest).verified(publicKey: key, version: version, bundleIdentifier: configuration.bundleIdentifier) == old.manifest else {
                throw AppUpdateError.invalidApplication
            }
            // Reconnect after an acknowledgement was lost, but never take over another app process's job.
            if workerIsRunning(in: directory) {
                guard old.parentPID == parentPID else { throw AppUpdateError.installerUnavailable }
                try validateBundle(old.candidate, manifest: old.manifest, publicKey: key, current: target)
                return old
            }
            try validateBundle(old.candidate, manifest: old.manifest, publicKey: key, current: target)
            let job = Job(target: target, directory: directory, manifest: old.manifest, signedManifest: old.signedManifest,
                          publicKey: key, originalInode: old.originalInode, parentPID: parentPID)
            try JSONEncoder().encode(job).write(to: file, options: .atomic)
            return job
        }
        return nil
    }

    static func workerIsRunning(in directory: URL) -> Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(AppUpdateStorage.workerReadyFile)),
              let pid = try? JSONDecoder().decode(Int32.self, from: data), pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    static func launchWorker(_ job: Job) throws -> Process {
        guard try inode(job.target) == job.originalInode else { throw AppUpdateError.installationFailed }
        try validateLocation(job.target)
        guard !workerIsRunning(in: job.directory) else { throw AppUpdateError.installerUnavailable }
        let ready = job.directory.appendingPathComponent(AppUpdateStorage.workerReadyFile)
        try? FileManager.default.removeItem(at: ready)
        try? FileManager.default.removeItem(at: job.directory.appendingPathComponent(AppUpdateStorage.workerErrorFile))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--apply-app-update", job.directory.appendingPathComponent(AppUpdateStorage.jobFile).path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, process.isRunning {
            if FileManager.default.fileExists(atPath: ready.path) { return process }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { process.terminate() }
        throw AppUpdateError.installationFailed
    }

    static func applyJob(at file: URL) throws {
        let data = try Data(contentsOf: file)
        guard data.count < 131_072 else { throw AppUpdateError.invalidApplication }
        let job = try JSONDecoder().decode(Job.self, from: data)
        let ownApp = installedApp().resolvingSymlinksInPath()
        guard job.target == ownApp, file == job.directory.appendingPathComponent(AppUpdateStorage.jobFile),
              job.directory == job.directory.resolvingSymlinksInPath(),
              job.directory.deletingLastPathComponent() == job.target.deletingLastPathComponent(),
              AppUpdateStorage.isStagingDirectory(job.directory),
              let current = Bundle(url: job.target),
              let configuration = try? ReleaseConfiguration(bundle: current),
              current.bundleIdentifier == configuration.bundleIdentifier, configuration.publicKey == job.publicKey,
              let version = AppVersion(job.manifest.version),
              try JSONDecoder().decode(SignedAppUpdate.self, from: job.signedManifest).verified(publicKey: job.publicKey, version: version, bundleIdentifier: configuration.bundleIdentifier) == job.manifest,
              try inode(job.target) == job.originalInode,
              let parent = NSRunningApplication(processIdentifier: job.parentPID),
              parent.bundleURL?.resolvingSymlinksInPath() == job.target else { throw AppUpdateError.invalidApplication }
        let descriptor = open(job.directory.appendingPathComponent(AppUpdateStorage.workerLockFile).path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw AppUpdateError.installerUnavailable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw AppUpdateError.installerUnavailable }
        defer { _ = flock(descriptor, LOCK_UN) }
        // Subscribe before acknowledging readiness: the app can quit as soon as
        // it receives that acknowledgement. The kernel event tracks this process
        // instance even if Launch Services retains the app's XPC/child processes.
        let termination = try ProcessExitMonitor(processIdentifier: job.parentPID)
        try validateBundle(job.candidate, manifest: job.manifest, publicKey: job.publicKey, current: job.target)
        try JSONEncoder().encode(getpid()).write(to: job.directory.appendingPathComponent(AppUpdateStorage.workerReadyFile), options: .atomic)
        do {
            try termination.wait()
            try finishInstallation(job, launch: { try openAndWait($0, reportFailure: $1) }, isRunning: { target in
                NSWorkspace.shared.runningApplications.contains { !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath() == target }
            })
        } catch {
            try? JSONEncoder().encode(error as? AppUpdateError ?? .installationFailed)
                .write(to: job.directory.appendingPathComponent(AppUpdateStorage.workerErrorFile), options: .atomic)
            throw error
        }
    }

    /// Wait for an actual process exit, not AppKit's asynchronously updated app
    /// registration. This runs only in the detached installer, never on the UI.
    final class ProcessExitMonitor {
        private let queue: Int32
        private let processIdentifier: pid_t
        private var exited: Bool

        init(processIdentifier: pid_t) throws {
            guard processIdentifier > 0, processIdentifier != getpid() else { throw AppUpdateError.invalidApplication }
            let descriptor = kqueue()
            guard descriptor >= 0 else { throw AppUpdateError.installerUnavailable }
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                close(descriptor)
                throw AppUpdateError.installerUnavailable
            }
            var event = kevent(ident: UInt(processIdentifier), filter: Int16(EVFILT_PROC),
                               flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT), fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
            let result = kevent(descriptor, &event, 1, nil, 0, nil)
            let error = errno
            // A manual quit can win the race between authentication and registration.
            // Only ESRCH proves absence; permission and registration failures must fail closed.
            guard result >= 0 || error == ESRCH else {
                close(descriptor)
                throw AppUpdateError.installerUnavailable
            }
            queue = descriptor
            self.processIdentifier = processIdentifier
            exited = result < 0
        }

        deinit { close(queue) }

        func wait(timeout: TimeInterval = 180) throws {
            guard timeout.isFinite, timeout >= 0 else { throw AppUpdateError.invalidApplication }
            if exited { return }
            // A wall-clock adjustment must not prolong the installation timeout.
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while true {
                let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
                var interval = timespec(tv_sec: Int(remaining), tv_nsec: Int(remaining.truncatingRemainder(dividingBy: 1) * 1_000_000_000))
                var event = kevent()
                let count = kevent(queue, nil, 0, &event, 1, &interval)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw AppUpdateError.installerUnavailable }
                guard count > 0 else { throw AppUpdateError.terminationTimedOut }
                guard event.flags & UInt16(EV_ERROR) == 0,
                      event.filter == Int16(EVFILT_PROC), event.ident == UInt(processIdentifier),
                      event.fflags & UInt32(NOTE_EXIT) != 0 else { throw AppUpdateError.installerUnavailable }
                exited = true
                return
            }
        }
    }

    /// Keep the old bundle until Launch Services reports that the new app finished launching.
    /// A hung app is never forcibly terminated; its backup remains beside the installed app.
    static func finishInstallation(_ job: Job, launch: (URL, Bool) throws -> Void, isRunning: (URL) -> Bool) throws {
        do { try exchange(job) }
        catch { try? launch(job.target, true); throw error }
        do { try launch(job.target, false) }
        catch {
            if !isRunning(job.target) {
                guard renamex_np(job.candidate.path, job.target.path, UInt32(RENAME_SWAP)) == 0 else { throw AppUpdateError.installationFailed }
                try? launch(job.target, true)
                try? FileManager.default.removeItem(at: job.directory)
            }
            throw AppUpdateError.installationFailed
        }
        try? FileManager.default.removeItem(at: job.directory)
    }

    private final class LaunchResult: @unchecked Sendable {
        let lock = NSLock()
        var result: Result<NSRunningApplication, any Error>?
    }

    static func openAndWait(_ target: URL, reportFailure: Bool = false) throws {
        let box = LaunchResult()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        if reportFailure { configuration.arguments = ["--chopchop-update-failed"] }
        NSWorkspace.shared.openApplication(at: target, configuration: configuration) { app, error in
            box.lock.withLock { box.result = app.map(Result.success) ?? .failure(error ?? AppUpdateError.installationFailed) }
        }
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let result = box.lock.withLock({ box.result }) {
                let app = try result.get()
                if app.isTerminated { throw AppUpdateError.installationFailed }
                if app.isFinishedLaunching { return }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        throw AppUpdateError.installationFailed
    }

    static func exchange(_ job: Job) throws {
        guard try inode(job.target) == job.originalInode else { throw AppUpdateError.installationFailed }
        try validateBundle(job.candidate, manifest: job.manifest, publicKey: job.publicKey, current: job.target)
        guard renamex_np(job.candidate.path, job.target.path, UInt32(RENAME_SWAP)) == 0 else { throw AppUpdateError.installationFailed }
        do { try validateBundle(job.target, manifest: job.manifest, publicKey: job.publicKey, current: job.candidate) }
        catch {
            _ = renamex_np(job.candidate.path, job.target.path, UInt32(RENAME_SWAP))
            throw error
        }
    }

    static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval) throws -> Data {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool); process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let limit = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: limit)
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); limit.cancel()
        guard process.terminationStatus == 0 else { throw AppUpdateError.installationFailed }
        return output
    }
}
