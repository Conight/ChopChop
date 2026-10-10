import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import ChopChop

final class AppUpdaterTests: XCTestCase {
    func testUpdateDirectoryOwnershipRequiresAnExactPrefixAndUUID() {
        let id = UUID().uuidString
        let root = URL(fileURLWithPath: "/tmp/update-layout-test", isDirectory: true)
        XCTAssertTrue(AppUpdateStorage.isArchiveDirectory(root.appendingPathComponent("installer-" + id)))
        XCTAssertTrue(AppUpdateStorage.isStagingDirectory(root.appendingPathComponent(".ChopChop-update-" + id)))
        for name in ["installer-", "installer-backup", "installer-" + id + ".old", ".ChopChop-update-", ".ChopChop-update-" + id + "-other", "foreign-" + id] {
            XCTAssertFalse(AppUpdateStorage.isArchiveDirectory(root.appendingPathComponent(name)))
            XCTAssertFalse(AppUpdateStorage.isStagingDirectory(root.appendingPathComponent(name)))
        }
        XCTAssertFalse(AppUpdateStorage.isArchiveDirectory(root.appendingPathComponent(".ChopChop-update-" + id)))
        XCTAssertFalse(AppUpdateStorage.isStagingDirectory(root.appendingPathComponent("installer-" + id)))
    }
    private func manifest(_ bytes: Data = Data("archive".utf8)) -> AppUpdateManifest {
        AppUpdateManifest(schema: 1, version: "1.0.0-beta.2", buildNumber: "2", bundleIdentifier: ReleaseConfiguration.current.bundleIdentifier,
                          architecture: "arm64", minimumSystemVersion: "26.5", filename: "ChopChop-v1.0.0-beta.2-macos-arm64.dmg",
                          size: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                          codeDirectoryHash: String(repeating: "a", count: 40))
    }
    func testForkReleaseConfigurationRoutesURLsAndRejectsOtherAppIdentity() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let fork = try ReleaseConfiguration(repository: "example/ChopChopFork", bundleIdentifier: "org.example.ChopChopFork", publicKey: publicKey)
        let version = try XCTUnwrap(AppVersion("1.0.0-beta.2"))
        XCTAssertEqual(fork.releasesAPI.absoluteString, "https://api.github.com/repos/example/ChopChopFork/releases?per_page=100")
        XCTAssertEqual(fork.releaseURL(version: version).absoluteString, "https://github.com/example/ChopChopFork/releases/tag/v1.0.0-beta.2")
        XCTAssertEqual(fork.assetURL(version: version, name: AppUpdateManifest.manifestName(for: version)).absoluteString,
                       "https://github.com/example/ChopChopFork/releases/download/v1.0.0-beta.2/ChopChop-v1.0.0-beta.2-update.json")
        XCTAssertEqual(fork.issuesURL.absoluteString, "https://github.com/example/ChopChopFork/issues/new/choose")
        XCTAssertEqual(fork.installerIdentifier, "org.example.ChopChopFork.EngineInstaller")
        XCTAssertEqual(fork.signingKeychainService, "org.example.ChopChopFork.update-signing")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest())) as? [String: Any])
        object["bundleIdentifier"] = fork.bundleIdentifier
        let payload = try JSONSerialization.data(withJSONObject: object)
        let signed = SignedAppUpdate(payload: payload, signature: try key.signature(for: payload))
        XCTAssertEqual(try signed.verified(publicKey: publicKey, version: version, bundleIdentifier: fork.bundleIdentifier).bundleIdentifier, fork.bundleIdentifier)
        XCTAssertThrowsError(try signed.verified(publicKey: publicKey, version: version))
    }

    func testReleaseConfigurationIsEmbeddedInAppAndInstallerAndFailsClosed() throws {
        let current = ReleaseConfiguration.current
        XCTAssertEqual(current.bundleIdentifier, Bundle.main.bundleIdentifier)
        let helper = try XCTUnwrap(Bundle(url: Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/EngineInstaller.xpc")))
        XCTAssertEqual(try ReleaseConfiguration(bundle: helper), current)
        XCTAssertEqual(helper.bundleIdentifier, current.installerIdentifier)
        XCTAssertThrowsError(try ReleaseConfiguration(info: [:]))
        for repository in ["https://github.com/example/repo", "example/repo/extra", "example/repo?x=1", "example/..", "example/repo\n"] {
            XCTAssertThrowsError(try ReleaseConfiguration(repository: repository, bundleIdentifier: current.bundleIdentifier, publicKey: current.publicKey))
        }
        XCTAssertThrowsError(try ReleaseConfiguration(repository: current.repository, bundleIdentifier: "invalid/id", publicKey: current.publicKey))
        XCTAssertThrowsError(try ReleaseConfiguration(repository: current.repository, bundleIdentifier: current.bundleIdentifier, publicKey: "$(UNRESOLVED)"))
    }
    func testSignedManifestRejectsTamperingWrongKeyVersionAndInvalidMetadata() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let version = try XCTUnwrap(AppVersion("1.0.0-beta.2"))
        let payload = try JSONEncoder().encode(manifest())
        let signed = SignedAppUpdate(payload: payload, signature: try key.signature(for: payload))
        XCTAssertEqual(try signed.verified(publicKey: publicKey, version: version), manifest())
        XCTAssertThrowsError(try signed.verified(publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString(), version: version))
        XCTAssertThrowsError(try signed.verified(publicKey: publicKey, version: AppVersion("1.0.0-beta.3")!))
        XCTAssertThrowsError(try SignedAppUpdate(payload: payload + Data([32]), signature: signed.signature).verified(publicKey: publicKey, version: version))
        for (field, value) in [("filename", "../../Other.app" as Any), ("size", -1), ("size", AppUpdateManifest.maximumSize + 1),
                               ("bundleIdentifier", "other.app"), ("architecture", "x86_64"), ("buildNumber", "0"), ("codeDirectoryHash", "fake")] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any]); object[field] = value
            let invalid = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try SignedAppUpdate(payload: invalid, signature: key.signature(for: invalid)).verified(publicKey: publicKey, version: version), field)
        }
    }
    func testArchiveHashAndSizeAreBothEnforced() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data("archive".utf8)
        try bytes.write(to: url); try manifest(bytes).verifyArchive(url)
        for invalid in [Data("Archive".utf8), bytes.dropLast(), bytes + Data([0])] {
            try invalid.write(to: url)
            XCTAssertThrowsError(try manifest(bytes).verifyArchive(url))
        }
        for invalid in ["999.0", "26.foo", "26..5", "26.5.0.0", "-1.0"] {
            XCTAssertThrowsError(try AppUpdateInstallation.validateSystem(invalid))
        }
        try AppUpdateInstallation.validateSystem("26.5")
    }
    func testExplicitChannelsOverrideBuildDefaultWithoutDowngrading() throws {
        let data = Data("""
        [{"tag_name":"v1.1.0-beta.2","draft":false,"prerelease":true,"assets":[{"name":"ChopChop-v1.1.0-beta.2-macos-arm64.dmg","state":"uploaded","size":10},{"name":"ChopChop-v1.1.0-beta.2-update.json","state":"uploaded","size":100}]},
        {"tag_name":"v1.0.0","draft":false,"prerelease":false,"assets":[{"name":"ChopChop-v1.0.0-macos-arm64.dmg","state":"uploaded","size":10}]}]
        """.utf8)
        let stable = try GitHubAppReleaseClient.select(data: data, current: AppVersion("0.9.0-beta.1"), channel: .stable)
        XCTAssertEqual(stable?.version, AppVersion("1.0.0")); XCTAssertEqual(stable?.supportsInstallation, false)
        let beta = try GitHubAppReleaseClient.select(data: data, current: AppVersion("1.0.0"), channel: .prerelease)
        XCTAssertEqual(beta?.version, AppVersion("1.1.0-beta.2")); XCTAssertEqual(beta?.supportsInstallation, true)
        XCTAssertNil(try GitHubAppReleaseClient.select(data: data, current: AppVersion("1.1.0-beta.1"), channel: .stable))
    }
    func testReleaseArchiveCarriesDownloadSizeAndDigestWithoutUpdateSignature() throws {
        let hash = String(repeating: "a", count: 64)
        let data = Data("""
        [{"tag_name":"v1.0.0","draft":false,"prerelease":false,"assets":[{"name":"ChopChop-v1.0.0-macos-arm64.dmg","state":"uploaded","size":12345,"digest":"sha256:\(hash)"}]}]
        """.utf8)
        let release = try XCTUnwrap(GitHubAppReleaseClient.select(data: data, current: AppVersion("0.9.0")))
        XCTAssertFalse(release.supportsInstallation)
        XCTAssertEqual(release.archive.size, 12345)
        XCTAssertEqual(release.archive.sha256, hash)
        XCTAssertEqual(release.archive.filename, "ChopChop-v1.0.0-macos-arm64.dmg")
        XCTAssertEqual(try AppUpdateArchive.checksum(from: Data("\(hash)  \(release.archive.filename)\n".utf8), filename: release.archive.filename), hash)
        for text in ["\(hash)  other.dmg", "not-a-hash  \(release.archive.filename)", "\(hash)  \(release.archive.filename)\n\(hash)  \(release.archive.filename)"] {
            XCTAssertThrowsError(try AppUpdateArchive.checksum(from: Data(text.utf8), filename: release.archive.filename))
        }
    }

    @MainActor func testLegacyUpdateDownloadsInAppAndOpensOnlyTheVerifiedInstaller() async throws {
        let suite = "updater-direct-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dmg")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: file) }
        let bytes = Data("installer fixture".utf8)
        try bytes.write(to: file)
        let archive = DownloadedAppUpdateArchive(url: file, size: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        for signingConfigured in [false, true] {
            var installerCreated = false, quits = 0
            let opening = ArchiveOpeningFixture()
            let downloader = DirectArchiveFixture(archive: archive)
            let coordinator = AppUpdateCoordinator(build: .init(version: "0.9.0"), client: LegacyUpdateReleaseFixture(), defaults: defaults,
                signingConfigured: signingConfigured, archiveDownloader: downloader,
                openArchive: opening.open, makeInstaller: { installerCreated = true; return ControlledUpdateInstaller() },
                terminateApplication: { quits += 1 })
            await coordinator.check(); coordinator.download()
            await wait { if case .downloaded = coordinator.state { return true }; return false }
            XCTAssertFalse(installerCreated, "A checksum authorizes downloading, not automatic replacement")
            XCTAssertTrue(opening.urls.isEmpty)
            coordinator.installAndRestart(); XCTAssertEqual(quits, 0)
            try Data("changed installer".utf8).write(to: file)
            coordinator.openInstaller()
            await wait { coordinator.state == .failed(.invalidSignature) }
            XCTAssertTrue(opening.urls.isEmpty, "Never open a package that changed after downloading")
            XCTAssertEqual(quits, 0)
            try bytes.write(to: file)
            coordinator.retry()
            await wait { if case .downloaded = coordinator.state { return true }; return false }
            coordinator.openInstaller()
            await wait { coordinator.state == .failed(.openingInstallerFailed) }
            XCTAssertEqual(quits, 0, "Do not quit when the installer could not open")
            opening.succeeds = true
            coordinator.retry()
            await wait { quits == 1 }
            XCTAssertEqual(opening.urls, [file, file])
            XCTAssertEqual(downloader.calls, 2, "Retry opening the verified DMG without downloading it again")
        }
    }

    @MainActor func testInstallRequiresPreparedPackageAndSuccessfulWorkerHandoff() async throws {
        let suite = "updater-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let installer = ControlledUpdateInstaller()
        var quits = 0
        let coordinator = AppUpdateCoordinator(build: .init(version: "1.0.0-beta.1"), client: UpdateReleaseFixture(), defaults: defaults,
            signingConfigured: true, makeInstaller: { installer }, terminateApplication: { quits += 1 })
        coordinator.installAndRestart(); XCTAssertEqual(quits, 0)
        await coordinator.check(); coordinator.download()
        await wait { installer.isPreparing }
        installer.report(.init(stage: .downloading, completedBytes: 50, totalBytes: 100, bytesPerSecond: 25))
        await wait { if case .preparing(_, let p) = coordinator.state { return p.fraction == 0.5 }; return false }
        coordinator.installAndRestart(); XCTAssertEqual(quits, 0)
        installer.finishPrepare()
        await wait { if case .ready = coordinator.state { return true }; return false }
        coordinator.installAndRestart()
        await wait { installer.isInstalling }
        XCTAssertEqual(quits, 0, "Do not quit before the detached worker acknowledges readiness")
        installer.finishInstall(error: .installationFailed)
        await wait { coordinator.state == .failed(.installationFailed) }
        XCTAssertEqual(quits, 0); XCTAssertFalse(installer.cancelled, "Keep the verified package for a retry")
        XCTAssertFalse(coordinator.canChangeChannel)
        coordinator.channel = .stable
        XCTAssertEqual(coordinator.channel, .prerelease, "Changing channels must not abandon an uncertain handoff")
        await coordinator.check(); coordinator.download()
        XCTAssertEqual(coordinator.state, .failed(.installationFailed), "A new check must preserve the handed-off package")
        XCTAssertFalse(installer.isPreparing)
        coordinator.retry()
        await wait { installer.isInstalling }
        installer.finishInstall()
        await wait { quits == 1 }
        XCTAssertEqual(quits, 1)
    }
    @MainActor func testCancelDiscardsPackageIgnoresLateProgressAndPersistsChannel() async throws {
        let suite = "updater-\(UUID())"
        let isolated = UserDefaults(suiteName: suite)!
        defer { isolated.removePersistentDomain(forName: suite) }
        let installer = ControlledUpdateInstaller()
        let coordinator = AppUpdateCoordinator(build: .init(version: "1.0.0-beta.1"), client: UpdateReleaseFixture(), defaults: isolated,
            signingConfigured: true, makeInstaller: { installer })
        await coordinator.check(); coordinator.download()
        await wait { installer.isPreparing }
        coordinator.cancel()
        XCTAssertTrue(installer.cancelled)
        installer.report(.init(stage: .verifying))
        await Task.yield()
        if case .available = coordinator.state {} else { XCTFail("Cancellation must retain the available release") }
        coordinator.channel = .stable
        XCTAssertEqual(coordinator.state, .idle)
        let reopened = AppUpdateCoordinator(build: .init(version: "1.0.0-beta.1"), defaults: isolated)
        XCTAssertEqual(reopened.channel, .stable)
    }
    func testAuthenticatedInstallerRejectsInvalidVersionAndUnknownToken() async throws {
        let installer = AppUpdateInstallerRequest()
        let timeout = Task { try? await Task.sleep(for: .seconds(8)); if !Task.isCancelled { installer.cancel() } }
        defer { timeout.cancel(); installer.cancel() }
        do {
            _ = try await installer.prepare(version: "not-a-version", progress: { _ in })
            XCTFail("Invalid version was accepted")
        } catch { XCTAssertEqual(error as? AppUpdateError, .invalidResponse) }
        do { try await installer.install(token: "unrecognized-token"); XCTFail("Unknown installation was accepted") }
        catch { XCTAssertEqual(error as? AppUpdateError, .installerUnavailable) }
    }
    @MainActor func testRollbackFailureRemainsVisibleUntilManualCheck() async throws {
        let suite = "updater-recovery-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = AppUpdateCoordinator(build: .init(version: "1.0.0-beta.1"), client: UpdateReleaseFixture(), defaults: defaults, startupInstallationFailed: true)
        await coordinator.check(automatically: true)
        XCTAssertEqual(coordinator.state, .failed(.installationFailed))
        XCTAssertTrue(coordinator.installationNeedsAttention)
        await coordinator.check()
        XCTAssertTrue(coordinator.updateAvailable)
    }
    @MainActor func testChannelChangeIgnoresAnOlderPendingCheck() async throws {
        let suite = "updater-channel-\(UUID())", client = PendingReleaseFixture()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = AppUpdateCoordinator(build: .init(version: "1.0.0-beta.1"), client: client, defaults: defaults)
        let check = Task { await coordinator.check() }
        await wait { await client.pending }
        coordinator.channel = .stable
        await client.finish()
        await check.value
        XCTAssertEqual(coordinator.state, .idle, "A pending beta request must not overwrite a stable-channel selection")
    }
    @MainActor func testUpdateWindowRendersLongNotesAtMinimumSizeInBothAppearances() async throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suite = "updater-layout-\(UUID())"
            let isolated = UserDefaults(suiteName: suite)!
            defer { isolated.removePersistentDomain(forName: suite) }
            let coordinator = AppUpdateCoordinator(build: .init(version: "1.0.0-beta.1"), client: UpdateReleaseFixture(), defaults: isolated, signingConfigured: true)
            await coordinator.check()
            let host = NSHostingController(rootView: AppUpdateWindow(updates: coordinator))
            let size = NSSize(width: 480, height: 400)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.alphaValue = 0; window.appearance = NSAppearance(named: appearance)
            window.contentViewController = host; window.setContentSize(size); window.orderBack(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(300))
            host.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(window.contentLayoutRect.size, size)
            let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            let output = try Aria2NextPaths.supportDirectory().appendingPathComponent("Design Previews")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("app-update-\(appearance.rawValue).png"))
            print("APP_UPDATE_PREVIEW=\(output.path)")
        }
    }

    @MainActor func testLastReleaseParagraphIsVisibleAtScrollEndAfterResizing() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "AppUpdateReleaseNotes", withExtension: "md"))
        let markdown = try String(contentsOf: url, encoding: .utf8)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suite = "updater-scroll-end-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let coordinator = AppUpdateCoordinator(build: .init(version: "0.0.1-beta.1"),
                client: NotesReleaseFixture(notes: markdown), defaults: defaults, signingConfigured: false)
            let host = NSHostingController(rootView: AppUpdateWindow(updates: coordinator))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 500),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.alphaValue = 0; window.appearance = NSAppearance(named: appearance)
            window.contentViewController = host; window.orderBack(nil)
            defer { window.close() }
            await wait { if case .available = coordinator.state { return true }; return false }
            for size in [NSSize(width: 540, height: 500), NSSize(width: 480, height: 400),
                         NSSize(width: 800, height: 550), NSSize(width: 540, height: 500)] {
                window.setContentSize(size)
                try await Task.sleep(for: .milliseconds(200))
                host.view.layoutSubtreeIfNeeded()
                let scroll = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? NSScrollView }.first)
                let document = try XCTUnwrap(scroll.documentView)
                let text = try XCTUnwrap(descendants(of: document).compactMap { $0 as? NSTextView }.first)
                let layout = try XCTUnwrap(text.layoutManager)
                let container = try XCTUnwrap(text.textContainer)
                layout.ensureLayout(for: container)
                let range = (text.string as NSString).range(of: "license and notices are included in the app.")
                XCTAssertNotEqual(range.location, NSNotFound)
                let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let lastLine = layout.boundingRect(forGlyphRange: glyphs, in: container)
                let lastInDocument = text.convert(lastLine, to: document)
                XCTAssertEqual(container.containerSize.width, text.bounds.width, accuracy: 1)
                XCTAssertLessThanOrEqual(lastInDocument.maxY, document.bounds.maxY - 16, "The scroll document must include the final paragraph and bottom padding")
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
                host.view.layoutSubtreeIfNeeded()
                let visible = scroll.contentView.bounds
                XCTAssertTrue(visible.insetBy(dx: -1, dy: -1).contains(lastInDocument), "The entire final line must be visible at the bottom: \(visible) versus \(lastInDocument)")
                XCTAssertTrue(text.visibleRect.insetBy(dx: -1, dy: -1).contains(lastLine))
                let end = NSRange(location: range.location, length: range.length)
                text.setSelectedRange(end)
                XCTAssertEqual(text.selectedRange(), end)
                text.setSelectedRange(NSRange(location: 0, length: 0))
                if size.width == 480 {
                    let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
                    host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                    let output = try Aria2NextPaths.supportDirectory().appendingPathComponent("Design Previews")
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("app-update-scroll-end-\(appearance.rawValue).png"))
                    print("UPDATE_SCROLL_END_PREVIEW=\(output.path)")
                }
            }
        }
    }

    @MainActor func testProgressReplacesScrolledReleaseNotesAndStaysVisibleThroughEveryStage() async throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suite = "updater-progress-layout-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let installer = ControlledUpdateInstaller()
            let coordinator = AppUpdateCoordinator(build: .init(version: "1.0.0-beta.1"), client: UpdateReleaseFixture(),
                defaults: defaults, signingConfigured: true, makeInstaller: { installer }, terminateApplication: {})
            defer { coordinator.cancel() }
            await coordinator.check()
            let host = NSHostingController(rootView: AppUpdateWindow(updates: coordinator))
            let size = NSSize(width: 480, height: 400)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.alphaValue = 0; window.appearance = NSAppearance(named: appearance)
            window.contentViewController = host; window.setContentSize(size); window.orderBack(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(200))
            host.view.layoutSubtreeIfNeeded()
            let notes = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? NSScrollView }.first)
            let document = try XCTUnwrap(notes.documentView)
            let renderedNotes = try XCTUnwrap(descendants(of: document).compactMap { $0 as? NSTextView }.first)
            let container = try XCTUnwrap(renderedNotes.textContainer)
            let layout = try XCTUnwrap(renderedNotes.layoutManager)
            layout.ensureLayout(for: container)
            XCTAssertLessThanOrEqual(layout.usedRect(for: container).maxY, renderedNotes.bounds.height + 1)
            // Reproduce reading the notes to the bottom, without synthesizing user input.
            let bottom = max(0, document.bounds.height - notes.contentView.bounds.height)
            XCTAssertGreaterThan(bottom, 0)
            notes.contentView.scroll(to: NSPoint(x: 0, y: bottom))
            notes.reflectScrolledClipView(notes.contentView)
            XCTAssertGreaterThan(notes.contentView.bounds.minY, 0)
            let frame = window.frame
            coordinator.download()
            await wait { installer.isPreparing }

            let samples: [AppUpdateProgress] = [
                .init(stage: .connecting),
                .init(stage: .downloading, completedBytes: 524_288, totalBytes: 1_048_576, bytesPerSecond: 262_144),
                .init(stage: .downloading, completedBytes: 524_288),
                .init(stage: .verifying), .init(stage: .preparing)
            ]
            for (index, sample) in samples.enumerated() {
                installer.report(sample)
                await wait { if case .preparing(_, let value) = coordinator.state { return value == sample }; return false }
                try await Task.sleep(for: .milliseconds(200))
                host.view.layoutSubtreeIfNeeded()
                let indicator = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? NSProgressIndicator }.first)
                XCTAssertEqual(indicator.style, .bar)
                XCTAssertEqual(indicator.isIndeterminate, sample.stage != .downloading || sample.fraction == nil)
                XCTAssertGreaterThan(indicator.bounds.width, 300)
                XCTAssertGreaterThan(indicator.visibleRect.height, 0)
                XCTAssertTrue(host.view.bounds.contains(indicator.convert(indicator.bounds, to: host.view)))
                var parent = indicator.superview
                while let view = parent {
                    XCTAssertFalse(view is NSScrollView, "Progress must not scroll away with release notes")
                    parent = view.superview
                }
                XCTAssertEqual(window.frame, frame, "Changing update stages must not resize the window")
                if let fraction = sample.fraction {
                    XCTAssertEqual((indicator.doubleValue - indicator.minValue) / (indicator.maxValue - indicator.minValue), fraction, accuracy: 0.01)
                }
                try saveProgressPreview(host.view, name: "\(index)-\(appearance.rawValue)")
            }
            installer.finishPrepare()
            await wait { if case .ready = coordinator.state { return true }; return false }
            coordinator.installAndRestart()
            await wait { installer.isInstalling }
            try await Task.sleep(for: .milliseconds(200))
            host.view.layoutSubtreeIfNeeded()
            let installing = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? NSProgressIndicator }.first)
            XCTAssertEqual(installing.style, .bar); XCTAssertTrue(installing.isIndeterminate)
            XCTAssertEqual(window.frame, frame)
            installer.finishInstall()
        }
    }

    @MainActor func testProgressUsesIndeterminateForUnknownTotalsAndIgnoresInvalidSpeeds() {
        for total in [nil, 0, -1] as [Int64?] {
            XCTAssertNil(AppUpdateProgress(stage: .downloading, completedBytes: 100, totalBytes: total).fraction)
        }
        XCTAssertEqual(AppUpdateProgress(stage: .downloading, completedBytes: 200, totalBytes: 100).fraction, 1)
        for rate in [Double.nan, .infinity, -.infinity, Double(Int64.max), -1, 0] {
            XCTAssertNil(AppUpdateProgress(stage: .downloading, bytesPerSecond: rate).speedSummary)
        }
        XCTAssertNotNil(AppUpdateProgress(stage: .downloading, bytesPerSecond: 1_024).speedSummary)
    }

    @MainActor private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    @MainActor private func saveProgressPreview(_ view: NSView, name: String) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let output = try Aria2NextPaths.supportDirectory().appendingPathComponent("Design Previews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("app-update-progress-\(name).png"))
        print("UPDATE_PROGRESS_PREVIEW=\(output.path)")
    }

    @MainActor func testDownloadedInstallerLayoutFitsMinimumWindow() async throws {
        let suite = "updater-installer-layout-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let archive = DownloadedAppUpdateArchive(url: URL(fileURLWithPath: "/unused-fixture.dmg"), size: 17, sha256: String(repeating: "a", count: 64))
        let coordinator = AppUpdateCoordinator(build: .init(version: "0.9.0"), client: LegacyUpdateReleaseFixture(), defaults: defaults,
            signingConfigured: false, archiveDownloader: DirectArchiveFixture(archive: archive))
        await coordinator.check(); coordinator.download()
        await wait { if case .downloaded = coordinator.state { return true }; return false }
        let output = try Aria2NextPaths.supportDirectory().appendingPathComponent("Design Previews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingController(rootView: AppUpdateWindow(updates: coordinator))
            let size = NSSize(width: 480, height: 400)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.alphaValue = 0; window.appearance = NSAppearance(named: appearance)
            window.contentViewController = host; window.setContentSize(size); window.orderBack(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(200))
            host.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(window.contentLayoutRect.size, size)
            let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("app-update-installer-\(appearance.rawValue).png"))
        }
        print("DIRECT_UPDATE_PREVIEW=\(output.path)")
    }

    @MainActor func testDownloadedPackageRestoresFromDiskWithoutNetworkAndRejectsChangedFiles() async throws {
        let suite = "updater-recovery-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite).resolvingSymlinksInPath()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let result = try await LegacyUpdateReleaseFixture().latest(for: nil, channel: .stable)
        let release = try XCTUnwrap(result)
        let job = root.appendingPathComponent("installer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        let file = job.appendingPathComponent(release.archive.filename)
        let bytes = Data("installer fixture".utf8)
        try bytes.write(to: file)
        let archive = DownloadedAppUpdateArchive(url: file, size: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let recovery = AppUpdateRecoveryStore(defaults: defaults, archiveDirectory: root)
        recovery.save(release, archive: archive)
        let client = PendingReleaseFixture()
        let restored = AppUpdateCoordinator(build: .init(version: "0.9.0"), client: client, defaults: defaults, archiveCacheDirectory: root)
        await restored.check()
        if case .downloaded(let value, let file) = restored.state { XCTAssertEqual(value, release); XCTAssertEqual(file, archive) }
        else { XCTFail("Downloaded installer was not restored") }
        let requestedNetwork = await client.pending
        XCTAssertFalse(requestedNetwork)
        try Data("modified installer".utf8).write(to: file)
        let changed = AppUpdateCoordinator(build: .init(version: "0.9.0"), defaults: defaults, archiveCacheDirectory: root)
        await changed.restoreIfNeeded()
        XCTAssertEqual(changed.state, .failed(.invalidSignature))
        recovery.save(release, archive: archive)
        XCTAssertNil(recovery.load(current: AppVersion("1.0.0"), channel: .stable), "An installed update must not be offered again")
        recovery.save(release, archive: .init(url: URL(fileURLWithPath: "/Applications/Other.app"), size: archive.size, sha256: archive.sha256))
        XCTAssertNil(recovery.load(current: nil, channel: .stable), "Recovery cannot open arbitrary paths")
    }

    @MainActor func testPreparedRecoveryAndExitTimeoutRetryReusePackage() async throws {
        let suite = "updater-handoff-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let result = try await UpdateReleaseFixture().latest(for: nil, channel: .prerelease)
        let release = try XCTUnwrap(result)
        AppUpdateRecoveryStore(defaults: defaults).save(release)
        let first = ControlledUpdateInstaller(), retry = ControlledUpdateInstaller()
        var created = 0, quits = 0
        let coordinator = AppUpdateCoordinator(build: .init(version: "1.0.0-beta.1"), defaults: defaults,
            signingConfigured: true, monitorInterval: .milliseconds(10), makeInstaller: {
                created += 1; return created == 1 ? first : retry
            }, terminateApplication: { quits += 1 })
        await coordinator.restoreIfNeeded()
        XCTAssertEqual(coordinator.state, .ready(release), suite)
        XCTAssertFalse(first.isPreparing, "Restore must not download the signed package again")
        coordinator.installAndRestart()
        await wait { first.isInstalling }
        first.finishInstall()
        await wait { quits == 1 }
        XCTAssertEqual(coordinator.state, .waitingToQuit(release))
        coordinator.channel = .stable
        XCTAssertEqual(coordinator.channel, .prerelease)
        XCTAssertEqual(coordinator.state, .waitingToQuit(release), "Channel changes must not reset an active installation")
        coordinator.retryQuit(); XCTAssertEqual(quits, 2)
        first.workerExited()
        await wait { coordinator.state == .failed(.terminationTimedOut) }
        coordinator.retry()
        await wait { retry.isInstalling }
        XCTAssertFalse(retry.isPreparing)
        retry.finishInstall()
        await wait { quits == 3 }
        retry.workerExited()
        await wait { coordinator.state == .failed(.terminationTimedOut) }
        coordinator.cancel()
    }

    @MainActor private func wait(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition timed out", file: file, line: line)
    }
}

private struct NotesReleaseFixture: AppReleaseFetching {
    let notes: String
    func latest(for current: AppVersion?, channel: AppUpdateChannel) async throws -> AppRelease? {
        AppRelease(version: AppVersion("0.0.1-beta.2")!, notes: notes)
    }
}

private struct UpdateReleaseFixture: AppReleaseFetching {
    func latest(for current: AppVersion?, channel: AppUpdateChannel) async throws -> AppRelease? {
        AppRelease(version: AppVersion("1.0.0-beta.2")!, notes: """
        ## Improvements

        - **Reliable downloads:** 更新与下载可靠性改进。
        - Native controls and [release notes](https://github.com/Conight/ChopChop/releases).

        ### Installation

        ```sh
        shasum -a 256 -c ChopChop-v1.0.0-beta.2-macos-arm64.dmg.sha256
        ```

        \(String(repeating: "- Improved updates and download reliability. 更新与下载可靠性改进。\n", count: 40))
        """, supportsInstallation: true)
    }
}
private final class ControlledUpdateInstaller: AppUpdateInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var preparation: CheckedContinuation<String, any Error>?
    private var installation: CheckedContinuation<Void, any Error>?
    private var callback: (@Sendable (AppUpdateProgress) -> Void)?
    private var wasCancelled = false
    private var workerStatus: AppUpdateInstallationStatus = .waitingForExit
    var resumeToken: String? = "prepared-token"
    var cancelled: Bool { lock.withLock { wasCancelled } }
    var isPreparing: Bool { lock.withLock { preparation != nil } }
    var isInstalling: Bool { lock.withLock { installation != nil } }
    func prepare(version: String, progress: @escaping @Sendable (AppUpdateProgress) -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in lock.withLock { wasCancelled = false; preparation = continuation; callback = progress } }
    }
    func install(token: String) async throws {
        try await withCheckedThrowingContinuation { continuation in lock.withLock { installation = continuation } }
    }
    func finishPrepare() { let pending = lock.withLock { let p = preparation; preparation = nil; return p }; pending?.resume(returning: "prepared-token") }
    func finishInstall(error: AppUpdateError? = nil) {
        let pending = lock.withLock { let p = installation; installation = nil; return p }
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
    func report(_ progress: AppUpdateProgress) { lock.withLock { callback }?(progress) }
    func resume(version: String) async throws -> String? { resumeToken }
    func status(token: String) async throws -> AppUpdateInstallationStatus { lock.withLock { workerStatus } }
    func workerExited() { lock.withLock { workerStatus = .terminationTimedOut } }
    func disconnect() {}
    func cancel() {
        let pending = lock.withLock { wasCancelled = true; let p = preparation; preparation = nil; return p }
        pending?.resume(throwing: CancellationError())
    }
}

private actor PendingReleaseFixture: AppReleaseFetching {
    private var continuation: CheckedContinuation<AppRelease?, any Error>?
    var pending: Bool { continuation != nil }
    func latest(for current: AppVersion?, channel: AppUpdateChannel) async throws -> AppRelease? {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish() {
        continuation?.resume(returning: AppRelease(version: AppVersion("1.0.0-beta.2")!, notes: ""))
        continuation = nil
    }
}

private struct LegacyUpdateReleaseFixture: AppReleaseFetching {
    func latest(for current: AppVersion?, channel: AppUpdateChannel) async throws -> AppRelease? {
        AppRelease(version: AppVersion("1.0.0")!, notes: "Download directly in ChopChop.", archiveSize: 17)
    }
}
@MainActor private final class ArchiveOpeningFixture {
    var succeeds = false
    var urls: [URL] = []
    func open(_ url: URL) -> Bool { urls.append(url); return succeeds }
}
private final class DirectArchiveFixture: AppUpdateArchiveDownloading, @unchecked Sendable {
    let archive: DownloadedAppUpdateArchive
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    init(archive: DownloadedAppUpdateArchive) { self.archive = archive }
    func download(_ archive: AppUpdateArchive, progress: @escaping @Sendable (AppUpdateProgress) -> Void) async throws -> DownloadedAppUpdateArchive {
        lock.withLock { count += 1 }
        progress(.init(stage: .downloading, completedBytes: self.archive.size, totalBytes: self.archive.size))
        return self.archive
    }
}
