import XCTest
@testable import ChopChop

final class UpdateCheckTests: XCTestCase {
    @MainActor
    func testDevNeverFetchesProductionAppUpdatesButStillChecksEngine() async throws {
        let suite = "ChopChop-dev-updates-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = UpdateCheckProbe()
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true), engineInstallationManager: probe)
        defer { store.shutdown() }
        let updates = AppUpdateCoordinator(build: AppBuild(version: "0.0.1", isDevelopment: true), client: probe, defaults: defaults)
        XCTAssertFalse(updates.canCheckForUpdates)
        XCTAssertFalse(updates.canDownloadInstaller)
        XCTAssertFalse(updates.canChangeChannel)
        await updates.check()
        await updates.checkAtLaunch(using: store)
        await updates.checkAll(using: store)
        let counts = await probe.counts
        XCTAssertEqual(counts, [0, 2])
        XCTAssertEqual(updates.state, .idle)
        XCTAssertTrue(updates.canCheckAllUpdates)
    }

    @MainActor
    func testIndividualChecksOnlyContactTheirComponentAndRemainIndependent() async throws {
        let suite = "ChopChop-individual-checks-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = UpdateCheckProbe(holdApp: true, holdEngine: true)
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true), engineInstallationManager: probe)
        defer { store.shutdown(); Task { await probe.finishApp(); await probe.finishEngine() } }
        let updates = AppUpdateCoordinator(build: AppBuild(version: "0.0.1-beta.1"), client: probe, defaults: defaults)
        updates.automaticallyChecks = false

        let appCheck = Task { await updates.check() }
        try await waitUntil { updates.state == .checking }
        let appOnly = await probe.counts
        XCTAssertEqual(appOnly, [1, 0], "Checking ChopChop must not fetch Engine versions")
        XCTAssertFalse(updates.canCheckForUpdates)
        XCTAssertTrue(store.canCheckEngineUpdates, "The Engine control remains independent")
        XCTAssertTrue(updates.isChecking(using: store))
        XCTAssertFalse(updates.isCheckingAll, "An individual check must not animate the Check All control")
        await updates.checkAll(using: store)
        let whileAppIsBusy = await probe.counts
        XCTAssertEqual(whileAppIsBusy, [1, 0], "A busy Check All entry must not silently run a partial check")

        store.startEngineUpdateCheck()
        await probe.finishApp()
        await appCheck.value
        XCTAssertTrue(updates.canCheckForUpdates)
        XCTAssertFalse(store.canCheckEngineUpdates)
        XCTAssertTrue(updates.isChecking(using: store), "The sidebar stays active for the Engine check")
        await probe.finishEngine()
        await store.waitForEngineUpdateCheck()
        let both = await probe.counts
        XCTAssertEqual(both, [1, 1])

        store.startEngineUpdateCheck()
        await store.waitForEngineUpdateCheck()
        let engineOnly = await probe.counts
        XCTAssertEqual(engineOnly, [1, 2], "Checking Engine must not check ChopChop")
        XCTAssertTrue(store.canCheckEngineUpdates)
        XCTAssertFalse(updates.isChecking(using: store))
    }

    @MainActor
    func testLaunchPreferencePersistsAndManualChecksStillCheckBothComponents() async throws {
        let suite = "ChopChop-update-checks-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = UpdateCheckProbe()
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true), engineInstallationManager: probe)
        defer { store.shutdown() }
        let first = AppUpdateCoordinator(build: AppBuild(version: "0.0.1-beta.1"), client: probe, defaults: defaults)
        XCTAssertTrue(first.automaticallyChecks)
        first.automaticallyChecks = false
        let reopened = AppUpdateCoordinator(build: first.build, client: probe, defaults: defaults)
        XCTAssertFalse(reopened.automaticallyChecks)
        await reopened.checkAtLaunch(using: store)
        let before = await probe.counts
        XCTAssertEqual(before, [0, 0])
        await reopened.checkAll(using: store)
        try await waitUntil { !reopened.isChecking(using: store) }
        let after = await probe.counts
        XCTAssertEqual(after, [1, 1])
        XCTAssertEqual(store.latestEngineRelease?.version, EngineVersion("3.8.6"))
    }

    @MainActor
    func testLaunchChecksOncePerProcessAndAgainOnNextLaunch() async throws {
        let suite = "ChopChop-launch-checks-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = UpdateCheckProbe()
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true), engineInstallationManager: probe)
        defer { store.shutdown() }
        let first = AppUpdateCoordinator(build: AppBuild(version: "0.0.1-beta.1"), client: probe, defaults: defaults)
        await first.checkAtLaunch(using: store)
        try await waitUntil { !first.isChecking(using: store) }
        await first.checkAtLaunch(using: store)
        let firstCounts = await probe.counts
        XCTAssertEqual(firstCounts, [1, 1])
        let reopened = AppUpdateCoordinator(build: first.build, client: probe, defaults: defaults)
        await reopened.checkAtLaunch(using: store)
        try await waitUntil { !reopened.isChecking(using: store) }
        let reopenedCounts = await probe.counts
        XCTAssertEqual(reopenedCounts, [2, 2], "A launch check must not be suppressed by yesterday's daily-check throttle")
    }

    @MainActor
    func testCheckingStaysActiveUntilBothComponentsFinishAndRepeatedChecksCoalesce() async throws {
        for appFinishesFirst in [true, false] {
            let suite = "ChopChop-concurrent-checks-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let probe = UpdateCheckProbe(holdApp: true, holdEngine: true)
            let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true), engineInstallationManager: probe)
            defer { store.shutdown() }
            let updates = AppUpdateCoordinator(build: AppBuild(version: "0.0.1-beta.1"), client: probe, defaults: defaults)
            let check = Task { await updates.checkAll(using: store) }
            try await waitUntil { updates.state == .checking && store.isCheckingEngineUpdate }
            XCTAssertTrue(updates.isCheckingAll)
            await updates.checkAll(using: store)
            if appFinishesFirst {
                await probe.finishApp()
                try await waitUntil { updates.state != .checking }
                XCTAssertTrue(updates.isChecking(using: store), "The Engine request is still pending")
                XCTAssertTrue(updates.isCheckingAll)
                await updates.checkAll(using: store)
                await probe.finishEngine()
            } else {
                await probe.finishEngine()
                try await waitUntil { !store.isCheckingEngineUpdate }
                XCTAssertTrue(updates.isChecking(using: store), "The app request is still pending")
                XCTAssertTrue(updates.isCheckingAll)
                await probe.finishApp()
                await check.value
            }
            await check.value
            try await waitUntil { !updates.isChecking(using: store) }
            XCTAssertFalse(updates.isCheckingAll)
            let counts = await probe.counts
            XCTAssertEqual(counts, [1, 1])
        }
    }

    @MainActor
    func testAppCheckFailureDoesNotDiscardEngineResultsAndSettingsRoutingIsRepeatable() async throws {
        let suite = "ChopChop-offline-checks-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = UpdateCheckProbe(failApp: true)
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true), engineInstallationManager: probe)
        defer { store.shutdown() }
        let updates = AppUpdateCoordinator(build: AppBuild(version: "0.0.1-beta.1"), client: probe, defaults: defaults)
        await updates.checkAll(using: store)
        try await waitUntil { !updates.isChecking(using: store) }
        XCTAssertEqual(updates.state, .failed(.offline))
        XCTAssertEqual(store.recentEngineReleases.count, 1)
        XCTAssertFalse(store.consumeUpdateSettingsRequest())
        for _ in 0..<2 {
            store.requestUpdateSettings()
            XCTAssertTrue(store.consumeUpdateSettingsRequest())
            XCTAssertFalse(store.consumeUpdateSettingsRequest())
        }
        XCTAssertEqual(SettingsSearchIndex.entries.first { $0.id == "engine.update" }?.pane, .updates)
        XCTAssertEqual(SettingsSearchIndex.entries.first { $0.id == "updates.chopchop" }?.pane, .updates)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Update state did not settle")
    }
}

actor UpdateCheckProbe: AppReleaseFetching, EngineInstallationManaging {
    private var appCalls = 0
    private var engineCalls = 0
    private var holdApp: Bool
    private var holdEngine: Bool
    private let failApp: Bool
    private var appWaiter: CheckedContinuation<Void, Never>?
    private var engineWaiter: CheckedContinuation<Void, Never>?
    var counts: [Int] { [appCalls, engineCalls] }

    init(holdApp: Bool = false, holdEngine: Bool = false, failApp: Bool = false) {
        self.holdApp = holdApp; self.holdEngine = holdEngine; self.failApp = failApp
    }

    func latest(for current: AppVersion?, channel: AppUpdateChannel) async throws -> AppRelease? {
        appCalls += 1
        if holdApp { await withCheckedContinuation { appWaiter = $0 } }
        if failApp { throw AppUpdateError.offline }
        return nil
    }
    func localInstallation() async -> EngineInstallation? { nil }
    func latestRelease() async throws -> EngineRelease {
        engineCalls += 1
        if holdEngine { await withCheckedContinuation { engineWaiter = $0 } }
        return EngineDistribution.release(version: EngineVersion("3.8.6")!)
    }
    func recentReleases() async throws -> [EngineRelease] { [EngineDistribution.release(version: EngineVersion("3.8.6")!)] }
    func finishApp() { holdApp = false; appWaiter?.resume(); appWaiter = nil }
    func finishEngine() { holdEngine = false; engineWaiter?.resume(); engineWaiter = nil }
    func activate(_ installation: EngineInstallation) async throws { XCTFail("Checking must not activate an Engine") }
    func backupRuntimeState() async throws -> EngineRuntimeBackup? { nil }
    func install(_ release: EngineRelease, progress: @escaping @Sendable (EngineInstallationProgress) async -> Void) async throws -> EngineInstallation {
        XCTFail("Checking must not install an Engine")
        throw EngineInstallationError.invalidRelease
    }
}
