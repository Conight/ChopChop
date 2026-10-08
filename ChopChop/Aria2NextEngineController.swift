import Darwin
import Foundation

nonisolated enum EngineError: LocalizedError, Sendable {
    case installationRequired
    case missingDownloadDirectory
    case missingRPCToken
    case invalidRPCPort(Int)
    case invalidListenPort(label: String, port: Int)
    case invalidNumericSetting(label: String, value: Int, range: ClosedRange<Int>)
    case executableLaunchFailed(path: String, reason: String)
    case processExited(Int32, String)
    case rpcUnavailableAfterLaunch(port: Int, reason: String)
    case portAlreadyInUse(label: String, port: Int)
    case alreadyRunning
    case notRunning

    var errorDescription: String? {
        switch self {
        case .installationRequired:
            String(localized: "Download and install Aria2 Next before starting the engine.")
        case .missingDownloadDirectory:
            String(localized: "Default download directory has not been selected.")
        case .missingRPCToken:
            String(localized: "RPC token is required before the engine can be launched.")
        case .invalidRPCPort(let port):
            String(localized: "RPC port must be between 1 and 65535. Current value: \(String(port)).")
        case .invalidListenPort(let label, let port):
            String(localized: "\(label) must be between 1 and 65535. Current value: \(String(port)).")
        case .invalidNumericSetting(let label, let value, let range):
            String(localized: "\(label) must be between \(range.lowerBound) and \(range.upperBound). Current value: \(value).")
        case .executableLaunchFailed(let path, let reason):
            String(localized: "Could not launch Aria2 Next at \(path).\n\(reason)")
        case .processExited(let code, let output):
            String(localized: "Aria2 Next exited with code \(code).\n\(output)")
        case .rpcUnavailableAfterLaunch(let port, let reason):
            String(localized: "Aria2 Next launched, but RPC did not become reachable on 127.0.0.1:\(String(port)).\n\(reason)")
        case .portAlreadyInUse(let label, let port):
            String(localized: "\(label) port \(String(port)) is already in use. Stop the app using this port, or set a different \(label) port in Settings.")
        case .alreadyRunning:
            String(localized: "Aria2 Next is already running.")
        case .notRunning:
            String(localized: "Aria2 Next is not running.")
        }
    }
}

nonisolated struct EngineRuntimeSnapshot: Equatable, Sendable {
    nonisolated enum Phase: Equatable, Sendable {
        case stopped
        case starting
        case running(pid: Int32)
        case stopping
        case failed(String)
    }

    var phase: Phase = .stopped
    var lastLaunchArguments: [String] = []
    var lastError: String?
    var sessionBackupURL: URL?
}

nonisolated struct EngineRPCConfiguration: Equatable, Sendable {
    var port: Int
    var token: String
}

nonisolated enum Aria2NextPaths {
    static let supportDirectoryName = "ChopChop"
    private static let automationBase = FileManager.default.temporaryDirectory
        .appendingPathComponent("ChopChopAutomation-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    static func supportDirectory() throws -> URL {
        if AppLaunchConfiguration.isTestAutomation {
            return try supportDirectory(applicationSupportBase: automationBase)
        }
        return try supportDirectory(
            applicationSupportBase: FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        )
    }

    static func supportDirectory(applicationSupportBase base: URL) throws -> URL {
        let directory = base.appendingPathComponent(supportDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

nonisolated enum EngineSessionMigration {
    /// Preserve the old task list before a new engine can rewrite output paths.
    /// Partial download files and recovery databases are never modified here.
    static func prepare(supportDirectory: URL, version: String) throws -> URL? {
        let fileManager = FileManager.default
        let marker = supportDirectory.appendingPathComponent("engine-version")
        let previous = try? String(contentsOf: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard previous != version else { return nil }

        let session = supportDirectory.appendingPathComponent("aria2.session")
        var backup: URL?
        if fileManager.fileExists(atPath: session.path),
           try session.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 > 0 {
            let directory = supportDirectory.appendingPathComponent("Session Backups", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("aria2-\(UUID().uuidString).session")
            try fileManager.copyItem(at: session, to: destination)
            backup = destination
        }
        try version.write(to: marker, atomically: true, encoding: .utf8)
        return backup
    }
}

private nonisolated enum ProcessWaiter {
    static func waitUntilExit(_ process: Process) async {
        // Process.waitUntilExit blocks; keep it off Swift's cooperative executor.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }
}

nonisolated enum Aria2ProcessLifecycleWatchdog {
    static let processName = "ChopChopAria2LifecycleWatchdog"

    static let wrapperScript = #"""
set -u
engine_path="$1"
pid_file="$2"
shift 2

exec 3<&0

"$engine_path" "$@" &
engine_pid=$!
printf '%s\n' "$engine_pid" > "$pid_file"

cleanup() {
    if [ "${cleaned_up:-0}" = "1" ]; then
        return
    fi
    cleaned_up=1
    if kill -0 "$engine_pid" 2>/dev/null; then
        kill -TERM "$engine_pid" 2>/dev/null || true
        wait_count=0
        while kill -0 "$engine_pid" 2>/dev/null && [ "$wait_count" -lt 20 ]; do
            sleep 0.1
            wait_count=$((wait_count + 1))
        done
        if kill -0 "$engine_pid" 2>/dev/null; then
            kill -KILL "$engine_pid" 2>/dev/null || true
        fi
    fi
}

parent_lifecycle_watchdog() {
    while IFS= read -r _ <&3; do :; done
    exec 3<&-
    cleanup
}

trap 'cleanup; rm -f "$pid_file"; exit 143' TERM INT HUP
parent_lifecycle_watchdog &
watchdog_pid=$!

wait "$engine_pid"
status=$?
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
rm -f "$pid_file"
exit "$status"
"""#

    static func wrapperArguments(
        engineExecutablePath: String,
        pidFilePath: String,
        engineArguments: [String]
    ) -> [String] {
        ["-c", wrapperScript, processName, engineExecutablePath, pidFilePath] + engineArguments
    }
}

nonisolated enum LocalHostPortProbe {
    static func isTCPPortInUse(port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        if !canBindTCP(port: port) {
            return true
        }
        return canConnect(port: port)
    }

    static func isUDPPortInUse(port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        return !canBindUDP(port: port)
    }

    static func canBindTCP(port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var reuseAddress = Int32(1)
        let setReuseResult = withUnsafePointer(to: &reuseAddress) { value in
            setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, value, socklen_t(MemoryLayout<Int32>.size))
        }
        guard setReuseResult == 0 else { return false }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        let converted = "127.0.0.1".withCString { value in
            inet_pton(AF_INET, value, &address.sin_addr)
        }
        guard converted == 1 else { return false }

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    static func canBindUDP(port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        let converted = "127.0.0.1".withCString { value in
            inet_pton(AF_INET, value, &address.sin_addr)
        }
        guard converted == 1 else { return false }

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    static func canConnect(port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        let converted = "127.0.0.1".withCString { value in
            inet_pton(AF_INET, value, &address.sin_addr)
        }
        guard converted == 1 else { return false }

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

nonisolated enum EngineLaunchPortPreflight {
    static func ensureConfiguredPortsAvailable(
        settings: EngineSettings,
        isTCPPortOccupied: (Int) -> Bool = { LocalHostPortProbe.isTCPPortInUse(port: $0) },
        isUDPPortOccupied: (Int) -> Bool = { LocalHostPortProbe.isUDPPortInUse(port: $0) }
    ) throws {
        if isTCPPortOccupied(settings.rpcPort) {
            throw EngineError.portAlreadyInUse(label: "RPC", port: settings.rpcPort)
        }
        if settings.ed2kListenPort > 0, isTCPPortOccupied(settings.ed2kListenPort) {
            throw EngineError.portAlreadyInUse(label: "ED2K", port: settings.ed2kListenPort)
        }
        if settings.ed2kUDPListenPort > 0, isUDPPortOccupied(settings.ed2kUDPListenPort) {
            throw EngineError.portAlreadyInUse(label: "ED2K UDP", port: settings.ed2kUDPListenPort)
        }
    }
}

@MainActor
protocol Aria2EngineControlling: AnyObject {
    var isRunning: Bool { get }
    var hasLaunchedProcess: Bool { get }
    var terminationStatus: Int32? { get }

    func selectInstallation(_ installation: EngineInstallation)
    func start(settings: EngineSettings) async throws -> EngineRuntimeSnapshot
    func stop() async throws -> EngineRuntimeSnapshot
    func terminateForAppExit()
    @discardableResult
    func clearTerminatedProcess() -> Int32?
    func client() throws -> Aria2RPCClient
}

extension Aria2EngineControlling {
    func selectInstallation(_ installation: EngineInstallation) {}
}

@MainActor
final class Aria2NextEngineController: Aria2EngineControlling {
    private var installation: EngineInstallation?
    private var process: Process?
    private var lifecycleInput: FileHandle?
    private var engineProcessID: Int32?
    private var pidFileURL: URL?
    private var rpcConfiguration: EngineRPCConfiguration?
    private var scopedURLs: [URL] = []
    private var isStopping = false
    private var isStarting = false

    func selectInstallation(_ installation: EngineInstallation) {
        self.installation = installation
    }

    var isRunning: Bool {
        process?.isRunning == true && !isStopping
    }

    var hasLaunchedProcess: Bool {
        process != nil
    }

    var terminationStatus: Int32? {
        guard let process, !process.isRunning else { return nil }
        return process.terminationStatus
    }

    func start(settings: EngineSettings) async throws -> EngineRuntimeSnapshot {
        try Task.checkCancellation()
        clearTerminatedProcess()
        guard !isRunning && !isStopping && !isStarting else { throw EngineError.alreadyRunning }
        try settings.validateLaunchRequirements()
        isStarting = true
        var didLaunch = false
        defer {
            isStarting = false
            if !didLaunch { stopSecurityScopedAccess() }
        }
        guard let installation else { throw EngineError.installationRequired }
        let executableURL = installation.executableURL
        let downloadDirectory = try downloadDirectoryURL(from: settings)
        try ensureLaunchPortsAvailable(settings: settings)
        let support = try Aria2NextPaths.supportDirectory()
        let sessionURL = support.appendingPathComponent("aria2.session", isDirectory: false)
        let logURL = support.appendingPathComponent("aria2.log", isDirectory: false)
        let pidFileURL = support.appendingPathComponent("aria2-\(UUID().uuidString).pid", isDirectory: false)
        let sessionExists = FileManager.default.fileExists(atPath: sessionURL.path)
        let sessionBackupURL = try EngineSessionMigration.prepare(
            supportDirectory: support,
            version: installation.version.description
        )
        try? FileManager.default.removeItem(at: pidFileURL)

        let arguments = launchArguments(
            settings: settings,
            downloadDirectory: downloadDirectory,
            sessionURL: sessionURL,
            sessionExists: sessionExists,
            logURL: logURL
        )
        let lifecyclePipe = Pipe()
        setCloseOnExec(lifecyclePipe.fileHandleForWriting)
        let process = Process()
        process.currentDirectoryURL = support
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = Aria2ProcessLifecycleWatchdog.wrapperArguments(
            engineExecutablePath: executableURL.path,
            pidFilePath: pidFileURL.path,
            engineArguments: arguments
        )
        process.standardInput = lifecyclePipe.fileHandleForReading
        // Undrained pipes can fill and stall the engine. aria2 writes diagnostics
        // to aria2.log; console output is disabled by --quiet.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            closeLifecycleInput(lifecyclePipe.fileHandleForReading)
        } catch {
            closeLifecycleInput(lifecyclePipe.fileHandleForReading)
            closeLifecycleInput(lifecyclePipe.fileHandleForWriting)
            throw EngineError.executableLaunchFailed(path: executableURL.path, reason: error.localizedDescription)
        }

        // Publish ownership before suspending so shutdown can cancel this launch.
        self.process = process
        self.lifecycleInput = lifecyclePipe.fileHandleForWriting
        self.pidFileURL = pidFileURL
        rpcConfiguration = EngineRPCConfiguration(port: settings.rpcPort, token: settings.rpcToken)

        let enginePID: Int32
        do {
            enginePID = try await waitForEngineProcessID(pidFileURL: pidFileURL, wrapperProcess: process)
            try Task.checkCancellation()
            guard self.process === process else { throw CancellationError() }
        } catch {
            if process.isRunning { process.terminate() }
            if self.process === process { clearLaunchedProcessState() }
            try? FileManager.default.removeItem(at: pidFileURL)
            throw error
        }

        self.engineProcessID = enginePID
        didLaunch = true

        return EngineRuntimeSnapshot(
            phase: .running(pid: enginePID),
            lastLaunchArguments: arguments.map {
                $0.hasPrefix("--rpc-secret=") ? "--rpc-secret=<redacted>" : $0
            },
            lastError: nil,
            sessionBackupURL: sessionBackupURL
        )
    }

    func stop() async throws -> EngineRuntimeSnapshot {
        if let exitStatus = clearTerminatedProcess() {
            throw EngineError.processExited(exitStatus, String(localized: "Aria2 Next stopped before the stop request completed."))
        }
        guard let process, process.isRunning else { throw EngineError.notRunning }
        isStopping = true
        process.terminate()
        await ProcessWaiter.waitUntilExit(process)
        if self.process === process {
            clearLaunchedProcessState()
        }
        isStopping = false
        return EngineRuntimeSnapshot(phase: .stopped)
    }

    func terminateForAppExit() {
        if process?.isRunning == true {
            process?.terminate()
        }
        clearLaunchedProcessState()
        isStopping = false
    }

    @discardableResult
    func clearTerminatedProcess() -> Int32? {
        guard let process, !process.isRunning else { return nil }
        let status = process.terminationStatus
        if self.process === process {
            clearLaunchedProcessState()
        }
        isStopping = false
        return status
    }

    func client() throws -> Aria2RPCClient {
        guard let rpcConfiguration, isRunning else { throw EngineError.notRunning }
        return try Aria2RPCClient(port: rpcConfiguration.port, token: rpcConfiguration.token)
    }

    private func downloadDirectoryURL(from settings: EngineSettings) throws -> URL {
        guard let path = settings.downloadDirectoryPath,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EngineError.missingDownloadDirectory
        }

        let url: URL
        if settings.downloadDirectoryBookmark != nil {
            url = try PreferencesStore.resolveBookmark(settings.downloadDirectoryBookmark, label: String(localized: "Download directory"))
        } else if EngineSettings.isDefaultDownloadDirectoryPath(path) {
            url = URL(fileURLWithPath: path).standardizedFileURL
        } else {
            throw PreferencesError.missingBookmark(String(localized: "Download directory"))
        }

        if url.startAccessingSecurityScopedResource() {
            scopedURLs.append(url)
        }
        return url
    }

    private func ensureLaunchPortsAvailable(settings: EngineSettings) throws {
        try EngineLaunchPortPreflight.ensureConfiguredPortsAvailable(settings: settings)
    }

    private func launchArguments(
        settings: EngineSettings,
        downloadDirectory: URL,
        sessionURL: URL,
        sessionExists: Bool,
        logURL: URL
    ) -> [String] {
        var arguments = [
            "--no-conf=true",
            // Matches aria2's macOS default in production, isolated alongside
            // the session file during automation. Keep this stable for resume.
            "--state-dir=\(sessionURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("aria2-next", isDirectory: true).path)",
            "--enable-rpc=true",
            "--pause=true", // Restored tasks must not transfer before explicit user resume.
            "--rpc-listen-all=false",
            "--summary-interval=0",
            "--save-session=\(sessionURL.path)",
            "--save-session-interval=30",
            "--log=\(logURL.path)",
            "--log-level=notice",
            "--quiet=true"
        ]
        if sessionExists {
            arguments.append("--input-file=\(sessionURL.path)")
        }
        var options = settings.engineOptions(downloadDirectoryPath: downloadDirectory.path, includeStartupOnly: true)
        if let bootstrapPaths = ED2KBootstrapCache.cachedPathsIfAvailable() {
            options["ed2k-server-list"] = bootstrapPaths.serverMetPath
            options["ed2k-node-list"] = bootstrapPaths.nodesDatPath
        }
        arguments.append(
            contentsOf: options
                .sorted { $0.key < $1.key }
                .map { "--\($0.key)=\($0.value)" }
        )
        return arguments
    }

    private func stopSecurityScopedAccess() {
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
    }

    private func waitForEngineProcessID(pidFileURL: URL, wrapperProcess: Process) async throws -> Int32 {
        for _ in 0..<100 {
            try Task.checkCancellation()
            guard self.process === wrapperProcess else { throw CancellationError() }
            if let pid = readProcessID(from: pidFileURL), pid > 0 {
                return pid
            }
            if !wrapperProcess.isRunning {
                throw EngineError.processExited(
                    wrapperProcess.terminationStatus,
                    String(localized: "Aria2 Next exited before publishing its process ID.")
                )
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw EngineError.executableLaunchFailed(
            path: pidFileURL.deletingLastPathComponent().path,
            reason: String(localized: "Aria2 Next lifecycle watchdog did not publish an engine process ID.")
        )
    }

    private func readProcessID(from url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return value
    }

    private func clearLaunchedProcessState() {
        closeLifecycleInput(lifecycleInput)
        lifecycleInput = nil
        if let pidFileURL {
            try? FileManager.default.removeItem(at: pidFileURL)
        }
        pidFileURL = nil
        engineProcessID = nil
        stopSecurityScopedAccess()
        process = nil
        rpcConfiguration = nil
    }

    private func closeLifecycleInput(_ fileHandle: FileHandle?) {
        try? fileHandle?.close()
    }

    private func setCloseOnExec(_ fileHandle: FileHandle) {
        let descriptor = fileHandle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0 else { return }
        _ = fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC)
    }
}
