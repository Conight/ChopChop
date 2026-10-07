import Foundation

// Standalone probe links only installer sources; it doesn't initialize the app, preferences,
// or UI. These definitions satisfy the manager's bundle/default-location dependencies.
nonisolated enum Aria2NextPaths {
    static func supportDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true).appendingPathComponent("ChopChop")
    }
}
nonisolated enum BundledAria2Next {
    static func executableURL() throws -> URL { throw CocoaError(.fileNoSuchFile) }
    static func version() throws -> String { throw CocoaError(.fileNoSuchFile) }
}

private actor ProbeProgress {
    var sawPartialDownload = false
    func record(_ progress: EngineInstallationProgress) {
        if let fraction = progress.fractionCompleted, fraction > 0, fraction < 1 { sawPartialDownload = true }
        print(progress.title, progress.percentDescription ?? "", progress.stage == .downloading ? progress.transferDescription : "")
    }
}

@main struct EngineInstallationProbe {
    static func main() async {
        do {
            let support = try Aria2NextPaths.supportDirectory()
            let manifest = support.appendingPathComponent("installed-engine.json")
            let originalManifest = try? Data(contentsOf: manifest)
            let manager = EngineInstallationManager(supportDirectory: support, useBundle: false)
            let progress = ProbeProgress()
            let release = try await manager.latestRelease()
            let installation = try await manager.install(release) { await progress.record($0) }
            defer { try? FileManager.default.removeItem(at: installation.executableURL.deletingLastPathComponent()) }
            guard await progress.sawPartialDownload else {
                throw EngineInstallationError.installationFailed("No byte progress arrived before download completion.")
            }
            guard (try? Data(contentsOf: manifest)) == originalManifest else {
                throw EngineInstallationError.installationFailed("The probe changed the active installation.")
            }
            print("PASS: Aria2 Next \(installation.version) downloaded, verified and executed with the Release app's sandbox and Hardened Runtime. Active installation unchanged.")
        } catch {
            print("FAIL: \(error.localizedDescription)")
            exit(1)
        }
    }
}
