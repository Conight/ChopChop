import XCTest
@testable import ChopChop

final class UITestScenarioTests: XCTestCase {
    func testScenarioRequiresAutomationAndOneRecognizedState() {
        XCTAssertNil(UITestScenario.read(from: ["CHOPCHOP_UI_SCENARIO": "installed-tasks"]))
        XCTAssertNil(UITestScenario.read(from: ["CHOPCHOP_UI_TESTING": "1"]))
        XCTAssertNil(UITestScenario.read(from: ["CHOPCHOP_UI_TESTING": "1", "CHOPCHOP_UI_SCENARIO": "unknown"]))
        XCTAssertEqual(UITestScenario.read(from: ["CHOPCHOP_UI_TESTING": "1", "CHOPCHOP_UI_SCENARIO": "installed-empty"]), .installedEmpty)
    }

    @MainActor
    func testInstalledEmptyScenarioAllowsImportWithoutInventingTasksOrStartingEngine() throws {
        let store = UITestScenario.installedEmpty.makeStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        XCTAssertEqual(store.engineSetupState, .ready)
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertEqual(store.runtime.phase, .stopped)
        XCTAssertTrue(DownloadInputPresentation().canPresent(in: store))
    }

    @MainActor
    func testFreshInstallationKeepsTheRealSetupFlowAndTaskScenarioIsExplicit() throws {
        let store = UITestScenario.freshInstall.makeStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        XCTAssertEqual(store.engineSetupState, .unchecked)
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertFalse(DownloadInputPresentation().canPresent(in: store))
        let populated = UITestScenario.installedTasks.makeStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { populated.shutdown() }
        XCTAssertEqual(populated.engineSetupState, .ready)
        XCTAssertEqual(populated.tasks.map(\.id), ["active-fixture", "waiting-fixture", "paused-fixture", "completed-fixture"])
        XCTAssertEqual(populated.runtime.phase, .stopped)
    }
}
