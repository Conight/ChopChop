//
//  ChopChopUITests.swift
//  ChopChopUITests
//
//  Created by Conight on 3/6/26.
//

import AppKit
import XCTest

final class ChopChopUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsEmptyDownloadLibrary() throws {
        let app = launchApp()

        let title = staticText(in: app, id: "empty-state-title", label: "No Downloads")
        let message = staticText(
            in: app,
            id: "empty-state-message",
            label: "Add a download link to get started. Your downloads in this category will appear here."
        )
        let searchField = searchField(in: app)
        let quickStats = app.descendants(matching: .any)
            .matching(identifier: "sidebar-quick-stats-card")
            .firstMatch
        let speedCurve = app.descendants(matching: .any)
            .matching(identifier: "sidebar-speed-curve")
            .firstMatch
        let engineVersion = app.descendants(matching: .any)
            .matching(identifier: "sidebar-quick-stats-engine-version-row")
            .firstMatch
        let engineStatus = app.descendants(matching: .any)
            .matching(identifier: "sidebar-quick-stats-engine-status-row")
            .firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        XCTAssertTrue(message.waitForExistence(timeout: 8))
        XCTAssertTrue(searchField.waitForExistence(timeout: 8))
        XCTAssertTrue(quickStats.waitForExistence(timeout: 8))
        XCTAssertTrue(speedCurve.waitForExistence(timeout: 8))
        XCTAssertTrue(engineVersion.waitForExistence(timeout: 8))
        XCTAssertTrue(engineStatus.waitForExistence(timeout: 8))
        XCTAssertEqual(textValue(of: title), "No Downloads")
        XCTAssertEqual(textValue(of: message), "Add a download link to get started. Your downloads in this category will appear here.")
        XCTAssertEqual(textValue(of: engineVersion), "Engine Unavailable")
        XCTAssertEqual(textValue(of: engineStatus), "Stopped")
    }

    @MainActor
    func testSettingsShowsUnavailableEngineBeforeSetup() throws {
        let app = launchApp(openSettings: true)
        let enginePane = sidebarDestination(in: app, id: "settings-pane-engine", label: "Engine")
        XCTAssertTrue(enginePane.waitForExistence(timeout: 4))
        enginePane.click()

        XCTAssertTrue(app.staticTexts["Installed version"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Unavailable"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["Check for Updates"].exists)
        XCTAssertFalse(app.buttons["Download for This Mac"].exists)
        XCTAssertFalse(app.buttons["Download Latest"].exists)
    }

    @MainActor
    func testMissingEngineRequiresInstallationAndCannotBeDismissed() throws {
        let app = launchApp(autoStart: true)
        let install = app.buttons["engine-install-button"]
        XCTAssertTrue(install.waitForExistence(timeout: 8))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(install.exists)
    }

    @MainActor
    func testFixtureTasksExposeCorrectPauseResumeButtons() throws {
        let app = launchApp(withTaskFixtures: true)

        XCTAssertTrue(actionButton(in: app, id: "task-active-fixture-pause-button", label: "Pause Ubuntu.iso").waitForExistence(timeout: 8))
        XCTAssertTrue(actionButton(in: app, id: "task-waiting-fixture-pause-button", label: "Pause Queue.mov").waitForExistence(timeout: 8))
        XCTAssertTrue(actionButton(in: app, id: "task-paused-fixture-resume-button", label: "Resume Paused.zip").waitForExistence(timeout: 8))
        XCTAssertTrue(staticText(in: app, id: "task-completed-fixture-name", label: "Finished.dmg").waitForExistence(timeout: 8))

        XCTAssertFalse(actionButton(in: app, id: "task-active-fixture-resume-button", label: "Resume Ubuntu.iso").exists)
        XCTAssertFalse(actionButton(in: app, id: "task-waiting-fixture-resume-button", label: "Resume Queue.mov").exists)
        XCTAssertFalse(actionButton(in: app, id: "task-paused-fixture-pause-button", label: "Pause Paused.zip").exists)
        XCTAssertFalse(actionButton(in: app, id: "task-completed-fixture-pause-button", label: "Pause Finished.dmg").exists)
        XCTAssertFalse(actionButton(in: app, id: "task-completed-fixture-resume-button", label: "Resume Finished.dmg").exists)
    }

    @MainActor
    func testRemovingFixtureTaskShowsNativeConfirmationOptions() throws {
        let app = launchApp(withTaskFixtures: true)

        let completed = staticText(in: app, id: "task-completed-fixture-name", label: "Finished.dmg")
        XCTAssertTrue(completed.waitForExistence(timeout: 8))
        completed.rightClick()
        app.menuItems["Remove Download…"].click()

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 4))
        XCTAssertTrue(sheet.buttons["Remove from List"].waitForExistence(timeout: 4))
        XCTAssertTrue(sheet.buttons["Move Files to Trash and Remove"].waitForExistence(timeout: 4))
        XCTAssertTrue(sheet.buttons["Cancel"].waitForExistence(timeout: 4))

        sheet.buttons["Cancel"].click()
        XCTAssertTrue(waitForNonExistence(sheet.buttons["Remove from List"], timeout: 4))
    }

    @MainActor
    func testSearchFiltersFixtureTasks() throws {
        let app = launchApp(withTaskFixtures: true)

        XCTAssertTrue(actionButton(in: app, id: "task-active-fixture-pause-button", label: "Pause Ubuntu.iso").waitForExistence(timeout: 8))
        XCTAssertTrue(staticText(in: app, id: "task-completed-fixture-name", label: "Finished.dmg").waitForExistence(timeout: 8))

        let searchField = searchField(in: app)
        XCTAssertTrue(searchField.waitForExistence(timeout: 8))
        searchField.click()
        searchField.typeText("Ubuntu")
        searchField.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(actionButton(in: app, id: "task-active-fixture-pause-button", label: "Pause Ubuntu.iso").waitForExistence(timeout: 4))
        XCTAssertTrue(waitForNonExistence(staticText(in: app, id: "task-completed-fixture-name", label: "Finished.dmg"), timeout: 4))

        clear(searchField)
        XCTAssertTrue(staticText(in: app, id: "task-completed-fixture-name", label: "Finished.dmg").waitForExistence(timeout: 4))
    }

    @MainActor
    func testInspectorNetworkAllowsDuplicateTrackerRows() throws {
        let app = launchApp(withTaskFixtures: true)
        let taskName = app.staticTexts.matching(identifier: "task-active-fixture-name").firstMatch
        XCTAssertTrue(taskName.waitForExistence(timeout: 8))

        taskName.click()
        app.buttons.matching(identifier: "toolbar-inspector-button").firstMatch.click()
        segmentedPickerOption(in: app, label: "Network").click()

        let tracker = "Announced · udp://tracker.opentrackr.org:1337/announce"
        let firstTrackerRow = app.descendants(matching: .any)
            .matching(identifier: "inspector-network-trackers-row-0")
            .firstMatch
        let secondTrackerRow = app.descendants(matching: .any)
            .matching(identifier: "inspector-network-trackers-row-1")
            .firstMatch
        XCTAssertTrue(firstTrackerRow.waitForExistence(timeout: 4))
        XCTAssertTrue(secondTrackerRow.waitForExistence(timeout: 4))
        XCTAssertEqual(textValue(of: firstTrackerRow), tracker)
        XCTAssertEqual(textValue(of: secondTrackerRow), tracker)
    }

    @MainActor
    func testSidebarSelectionFiltersFixtureTasks() throws {
        let app = launchApp(withTaskFixtures: true)
        XCTAssertTrue(app.windows["All"].waitForExistence(timeout: 8))

        sidebarDestination(in: app, id: "sidebar-destination-active", label: "Active").click()
        XCTAssertTrue(app.windows["Active"].waitForExistence(timeout: 4))
        XCTAssertTrue(actionButton(in: app, id: "task-active-fixture-pause-button", label: "Pause Ubuntu.iso").waitForExistence(timeout: 4))
        XCTAssertTrue(waitForNonExistence(staticText(in: app, id: "task-completed-fixture-name", label: "Finished.dmg"), timeout: 4))

        sidebarDestination(in: app, id: "sidebar-destination-waiting", label: "Waiting").click()
        XCTAssertTrue(app.windows["Waiting"].waitForExistence(timeout: 4))
        XCTAssertTrue(actionButton(in: app, id: "task-waiting-fixture-pause-button", label: "Pause Queue.mov").waitForExistence(timeout: 4))
        XCTAssertTrue(actionButton(in: app, id: "task-paused-fixture-resume-button", label: "Resume Paused.zip").waitForExistence(timeout: 4))
        XCTAssertTrue(waitForNonExistence(actionButton(in: app, id: "task-active-fixture-pause-button", label: "Pause Ubuntu.iso"), timeout: 4))

        sidebarDestination(in: app, id: "sidebar-destination-completed", label: "Completed").click()
        XCTAssertTrue(app.windows["Completed"].waitForExistence(timeout: 4))
        XCTAssertTrue(staticText(in: app, id: "task-completed-fixture-name", label: "Finished.dmg").waitForExistence(timeout: 4))
        XCTAssertTrue(waitForNonExistence(actionButton(in: app, id: "task-waiting-fixture-pause-button", label: "Pause Queue.mov"), timeout: 4))

        sidebarDestination(in: app, id: "sidebar-destination-all", label: "All").click()
        XCTAssertTrue(app.windows["All"].waitForExistence(timeout: 4))
        XCTAssertTrue(actionButton(in: app, id: "task-active-fixture-pause-button", label: "Pause Ubuntu.iso").waitForExistence(timeout: 4))
        XCTAssertTrue(staticText(in: app, id: "task-completed-fixture-name", label: "Finished.dmg").waitForExistence(timeout: 4))
    }

    @MainActor
    func testAddDownloadPanelValidatesURLBeforeSubmit() throws {
        let app = launchApp()

        let addButton = actionButton(in: app, id: "toolbar-add-button", label: "Add")
        XCTAssertTrue(addButton.waitForExistence(timeout: 8))
        addButton.click()

        XCTAssertTrue(staticText(in: app, id: "add-download-title", label: "Add Download").waitForExistence(timeout: 4))
        let submitButton = actionButton(in: app, id: "add-download-submit-button", label: "Start Download")
        XCTAssertTrue(submitButton.waitForExistence(timeout: 4))
        XCTAssertFalse(submitButton.isEnabled)

        let urlField = addDownloadURLField(in: app)
        XCTAssertTrue(urlField.waitForExistence(timeout: 4))
        paste("https://example.com/file.iso", into: urlField)
        XCTAssertTrue(waitForEnabled(submitButton, timeout: 4))

        actionButton(in: app, id: "add-download-cancel-button", label: "Cancel").click()
        XCTAssertFalse(staticText(in: app, id: "add-download-title", label: "Add Download").waitForExistence(timeout: 2))
    }

    @MainActor
    func testAddDownloadMagnetLoadFilesReportsMissingEngine() throws {
        let app = launchApp()

        let addButton = actionButton(in: app, id: "toolbar-add-button", label: "Add")
        XCTAssertTrue(addButton.waitForExistence(timeout: 8))
        addButton.click()

        let urlField = addDownloadURLField(in: app)
        XCTAssertTrue(urlField.waitForExistence(timeout: 4))
        paste("magnet:?xt=urn:btih:BF650E61509ABA5376CB3946305B2B5270A68B17", into: urlField)

        let loadFilesButton = actionButton(in: app, id: "add-download-submit-button", label: "Choose Files…")
        XCTAssertTrue(loadFilesButton.waitForExistence(timeout: 4))
        XCTAssertTrue(waitForEnabled(loadFilesButton, timeout: 4))
        loadFilesButton.click()

        XCTAssertTrue(app.staticTexts["Engine Not Running"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Start Aria2 Next before adding downloads."].waitForExistence(timeout: 4))
        XCTAssertTrue(app.descendants(matching: .any)["add-download-error"].exists)
        XCTAssertTrue(loadFilesButton.isEnabled)
    }

    @MainActor
    func testPasteToolbarOpensAddPanelWithClipboardLink() throws {
        let app = launchApp()
        let url = "https://example.com/file.iso"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)

        let pasteButton = actionButton(in: app, id: "toolbar-paste-button", label: "Paste")
        XCTAssertTrue(pasteButton.waitForExistence(timeout: 8))
        pasteButton.click()

        XCTAssertTrue(staticText(in: app, id: "add-download-title", label: "Add Download").waitForExistence(timeout: 4))
        let urlField = addDownloadURLField(in: app)
        XCTAssertTrue(waitForTextValue(urlField, url, timeout: 4))
    }

    @MainActor
    func testAddDownloadAdvancedKeepsActionsReachableAndContainsSpeedLimit() throws {
        let app = launchApp()

        let addButton = actionButton(in: app, id: "toolbar-add-button", label: "Add")
        XCTAssertTrue(addButton.waitForExistence(timeout: 8))
        addButton.click()

        let submitButton = actionButton(in: app, id: "add-download-submit-button", label: "Start Download")
        let cancelButton = actionButton(in: app, id: "add-download-cancel-button", label: "Cancel")
        let advancedToggle = disclosureControl(in: app, id: "add-download-advanced-toggle", label: "Advanced Options")


        XCTAssertTrue(submitButton.waitForExistence(timeout: 4))
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 4))
        XCTAssertTrue(advancedToggle.waitForExistence(timeout: 4))
        XCTAssertFalse(app.checkBoxes["add-download-limit-speed-toggle"].exists)
        XCTAssertFalse(app.checkBoxes["Limit speed"].exists)

        let urlField = addDownloadURLField(in: app)
        XCTAssertTrue(urlField.waitForExistence(timeout: 4))
        paste("https://example.com/file.iso", into: urlField)
        XCTAssertTrue(waitForEnabled(submitButton, timeout: 4))

        advancedToggle.click()
        let limitSpeedToggle = toggleControl(in: app, id: "add-download-limit-speed-toggle", label: "Limit speed")
        XCTAssertTrue(limitSpeedToggle.waitForExistence(timeout: 4))
        XCTAssertTrue(submitButton.isHittable)
        XCTAssertTrue(cancelButton.isHittable)

        advancedToggle.click()
        XCTAssertTrue(waitForNonExistence(limitSpeedToggle, timeout: 4))

        advancedToggle.click()
        let reopenedLimitSpeedToggle = toggleControl(in: app, id: "add-download-limit-speed-toggle", label: "Limit speed")
        XCTAssertTrue(reopenedLimitSpeedToggle.waitForExistence(timeout: 4))
        XCTAssertTrue(submitButton.isHittable)
        XCTAssertTrue(cancelButton.isHittable)
    }

    @MainActor
    func testSettingsBitTorrentPaneExposesTrackerControls() throws {
        let app = launchApp(openSettings: true)

        let enginePaneTitle = app.descendants(matching: .any)["settings-current-pane-title"]
        XCTAssertTrue(enginePaneTitle.waitForExistence(timeout: 8))

        let bitTorrentPane = sidebarDestination(in: app, id: "settings-pane-bittorrent", label: "BitTorrent")
        XCTAssertTrue(bitTorrentPane.waitForExistence(timeout: 4))
        bitTorrentPane.click()

        XCTAssertTrue(app.descendants(matching: .any)["settings-bt-file-selection-note"].waitForExistence(timeout: 4))
        XCTAssertTrue(toggleControl(in: app, id: "settings-bt-dht-toggle", label: "DHT").waitForExistence(timeout: 4))
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "settings-bt-sharing-mode-picker")
                .firstMatch
                .waitForExistence(timeout: 4)
        )
        let sharingMode = app.popUpButtons["settings-bt-sharing-mode-picker"]
        sharingMode.click()
        app.menuItems["Seed until manually stopped"].click()
        sharingMode.click()
        app.menuItems["Stop by ratio or time"].click()
        XCTAssertTrue(actionButton(in: app, id: "settings-bt-sync-trackers-button", label: "Sync Trackers").waitForExistence(timeout: 4))

        XCTAssertTrue(app.descendants(matching: .any)["settings-bt-tracker-sources-editor"].waitForExistence(timeout: 4))
        XCTAssertTrue(textEntry(in: app, id: "settings-bt-tracker-source-filter-field", label: "Filter").waitForExistence(timeout: 4))
        let customSourceField = textEntry(in: app, id: "settings-bt-custom-tracker-source-field", label: "Custom tracker source URL")
        let addCustomSourceButton = actionButton(in: app, id: "settings-bt-add-custom-tracker-source-button", label: "Add")
        XCTAssertTrue(customSourceField.waitForExistence(timeout: 4))
        XCTAssertTrue(addCustomSourceButton.waitForExistence(timeout: 4))
        paste("https://example.com/trackers.txt", into: customSourceField)
        addCustomSourceButton.click()
        XCTAssertTrue(waitForEnabled(
            actionButton(
                in: app,
                id: "settings-bt-remove-custom-tracker-source-button",
                label: "Remove Custom Source"
            ),
            timeout: 4
        ))
        XCTAssertTrue(app.descendants(matching: .any)["settings-bt-tracker-list-editor"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "settings-bt-tracker-text-editor").firstMatch.exists)

        XCTAssertTrue(textEntry(in: app, id: "settings-bt-tracker-filter-field", label: "Filter").waitForExistence(timeout: 4))
        let addTrackerField = textEntry(in: app, id: "settings-bt-tracker-add-field", label: "Add tracker URL")
        let addTrackerButton = actionButton(in: app, id: "settings-bt-tracker-add-button", label: "Add")
        XCTAssertTrue(addTrackerField.waitForExistence(timeout: 4))
        XCTAssertTrue(addTrackerButton.waitForExistence(timeout: 4))

        let trackerURL = "udp://tracker.example.com:1337/announce"
        paste(trackerURL, into: addTrackerField)
        addTrackerButton.click()
        let removeTrackerButton = actionButton(
            in: app,
            id: "settings-bt-tracker-remove-button",
            label: "Remove Selected Tracker"
        )
        XCTAssertTrue(waitForEnabled(removeTrackerButton, timeout: 4))

        let rawToggle = actionButton(in: app, id: "settings-bt-tracker-raw-toggle", label: "Edit Raw List...")
        XCTAssertTrue(rawToggle.waitForExistence(timeout: 4))
        rawToggle.click()
        XCTAssertTrue(app.buttons["Hide Raw List"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "settings-bt-tracker-raw-editor-label").firstMatch.waitForExistence(timeout: 4))
    }

    @MainActor
    func testSettingsED2KPaneExposesBootstrapAndSearchControls() throws {
        let app = launchApp(openSettings: true)

        let ed2kPane = sidebarDestination(in: app, id: "settings-pane-ed2k", label: "ED2K")
        XCTAssertTrue(ed2kPane.waitForExistence(timeout: 8))
        ed2kPane.click()

        XCTAssertTrue(textEntry(in: app, id: "settings-ed2k-listen-port-field", label: "ED2K listen port").waitForExistence(timeout: 4))
        XCTAssertTrue(textEntry(in: app, id: "settings-ed2k-udp-listen-port-field", label: "ED2K UDP listen port").waitForExistence(timeout: 4))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "settings-ed2k-upload-slots-stepper").firstMatch.waitForExistence(timeout: 4))
        XCTAssertTrue(textEntry(in: app, id: "settings-ed2k-server-met-url-field", label: "server.met URL").waitForExistence(timeout: 4))
        XCTAssertTrue(textEntry(in: app, id: "settings-ed2k-nodes-dat-url-field", label: "nodes.dat URL").waitForExistence(timeout: 4))
        XCTAssertTrue(textEntry(in: app, id: "settings-ed2k-server-list-field", label: "One server per line, for example server.example:4661").waitForExistence(timeout: 4))
        XCTAssertTrue(toggleControl(in: app, id: "settings-ed2k-bootstrap-auto-sync-toggle", label: "Sync bootstrap files automatically").waitForExistence(timeout: 4))
        XCTAssertTrue(actionButton(in: app, id: "settings-ed2k-sync-bootstrap-button", label: "Sync Bootstrap Files").waitForExistence(timeout: 4))
        XCTAssertTrue(textEntry(in: app, id: "settings-ed2k-search-keyword-field", label: "Keyword").waitForExistence(timeout: 4))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "settings-ed2k-search-file-type-picker").firstMatch.waitForExistence(timeout: 4))
        let videoType = segmentedPickerOption(in: app, label: "Video")
        XCTAssertTrue(videoType.waitForExistence(timeout: 4))
        videoType.click()
        let audioType = segmentedPickerOption(in: app, label: "Audio")
        XCTAssertTrue(audioType.waitForExistence(timeout: 4))
        audioType.click()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "settings-ed2k-search-timeout-stepper").firstMatch.waitForExistence(timeout: 4))
        XCTAssertTrue(actionButton(in: app, id: "settings-ed2k-search-button", label: "Search").waitForExistence(timeout: 4))
    }

    @MainActor
    func testSettingsWindowClosesWithoutBlockingMainWindow() throws {
        let app = launchApp(openSettings: true)
        let settingsMarker = app.descendants(matching: .any)
            .matching(identifier: "settings-current-pane-title")
            .firstMatch
        XCTAssertTrue(settingsMarker.waitForExistence(timeout: 8))

        let downloadsPane = sidebarDestination(in: app, id: "settings-pane-downloads", label: "Downloads")
        XCTAssertTrue(downloadsPane.waitForExistence(timeout: 4))
        downloadsPane.click()
        XCTAssertTrue(staticText(in: app, id: "settings-current-pane-title", label: "Downloads").waitForExistence(timeout: 4))

        let addButton = actionButton(in: app, id: "toolbar-add-button", label: "Add")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitForNonExistence(settingsMarker, timeout: 4))

        XCTAssertTrue(addButton.waitForExistence(timeout: 4))
        addButton.click()
        XCTAssertTrue(staticText(in: app, id: "add-download-title", label: "Add Download").waitForExistence(timeout: 4))
    }

    @MainActor
    private func launchApp(withTaskFixtures: Bool = false, openSettings: Bool = false, autoStart: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CHOPCHOP_UI_TESTING"] = "1"
        if autoStart { app.launchEnvironment["CHOPCHOP_UI_AUTO_START"] = "1" }
        if withTaskFixtures {
            app.launchEnvironment["CHOPCHOP_UI_FIXTURE_TASKS"] = "1"
        }
        app.launchArguments = ["--reset-preferences"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        if openSettings {
            openSettingsWindow(in: app)
        }
        addTeardownBlock { @MainActor in
            if app.state != .notRunning {
                app.terminate()
                XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
            }
        }
        return app
    }

    @MainActor
    private func openSettingsWindow(in app: XCUIApplication) {
        let settingsMarker = app.descendants(matching: .any)
            .matching(identifier: "settings-current-pane-title")
            .firstMatch
        if settingsMarker.waitForExistence(timeout: 2) {
            return
        }

        openSettingsWindowFromAppMenu(in: app)
        if settingsMarker.waitForExistence(timeout: 4) {
            return
        }

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settingsMarker.waitForExistence(timeout: 8))
    }

    @MainActor
    private func openSettingsWindowFromAppMenu(in app: XCUIApplication) {
        let appMenu = app.menuBars.menuBarItems["ChopChop"]
        guard appMenu.waitForExistence(timeout: 4) else { return }
        appMenu.click()

        let settingsItems = [
            app.menuItems["Settings…"],
            app.menuItems["Settings..."]
        ]
        for settingsItem in settingsItems where settingsItem.waitForExistence(timeout: 2) {
            settingsItem.click()
            return
        }
    }

    @MainActor
    private func addDownloadURLField(in app: XCUIApplication) -> XCUIElement {
        let candidates = [
            app.textFields["add-download-url-field"],
            app.textViews["add-download-url-field"],
            app.textFields["URL, Magnet, ED2K, torrent, or metalink"],
            app.textViews["URL, Magnet, ED2K, torrent, or metalink"]
        ]
        for candidate in candidates where candidate.waitForExistence(timeout: 1) {
            return candidate
        }
        return app.textFields["add-download-url-field"]
    }

    @MainActor
    private func searchField(in app: XCUIApplication) -> XCUIElement {
        let candidates = [
            app.searchFields["Search downloads"],
            app.searchFields.firstMatch,
            app.textFields["Search downloads"],
            app.textFields["search-field"]
        ]
        for candidate in candidates where candidate.waitForExistence(timeout: 1) {
            return candidate
        }
        return app.searchFields["Search downloads"]
    }

    @MainActor
    private func textEntry(in app: XCUIApplication, id: String, label: String) -> XCUIElement {
        let candidates = [
            app.textFields.matching(identifier: id).firstMatch,
            app.textViews.matching(identifier: id).firstMatch,
            app.descendants(matching: .any).matching(identifier: id).firstMatch,
            app.textFields[label],
            app.textViews[label]
        ]
        for candidate in candidates where candidate.waitForExistence(timeout: 1) {
            return candidate
        }
        return app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    private func actionButton(in app: XCUIApplication, id: String, label: String) -> XCUIElement {
        let identifiedButton = app.buttons[id]
        if identifiedButton.exists {
            return identifiedButton
        }
        return app.buttons[label]
    }

    @MainActor
    private func disclosureControl(in app: XCUIApplication, id: String, label: String) -> XCUIElement {
        let candidates = [
            app.buttons.matching(identifier: id).firstMatch,
            app.descendants(matching: .any).matching(identifier: id).firstMatch,
            app.buttons[label],
            app.staticTexts[label]
        ]
        for candidate in candidates where candidate.waitForExistence(timeout: 1) {
            return candidate
        }
        return app.buttons[label]
    }

    @MainActor
    private func toggleControl(in app: XCUIApplication, id: String, label: String) -> XCUIElement {
        let candidates = [
            app.checkBoxes.matching(identifier: id).firstMatch,
            app.buttons.matching(identifier: id).firstMatch,
            app.switches.matching(identifier: id).firstMatch,
            app.descendants(matching: .any).matching(identifier: id).firstMatch,
            app.checkBoxes[label],
            app.buttons[label],
            app.switches[label],
            app.descendants(matching: .any).matching(identifier: label).firstMatch
        ]
        for candidate in candidates where candidate.waitForExistence(timeout: 1) {
            return candidate
        }
        return app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    private func segmentedPickerOption(in app: XCUIApplication, label: String) -> XCUIElement {
        let candidates = [
            app.buttons[label],
            app.radioButtons[label],
            app.staticTexts[label],
            app.descendants(matching: .any).matching(identifier: label).firstMatch
        ]
        for candidate in candidates where candidate.waitForExistence(timeout: 1) {
            return candidate
        }
        return app.descendants(matching: .any).matching(identifier: label).firstMatch
    }

    @MainActor
    private func sidebarDestination(in app: XCUIApplication, id: String, label: String) -> XCUIElement {
        let candidates = [
            app.cells.matching(identifier: id).firstMatch,
            app.buttons.matching(identifier: id).firstMatch,
            app.groups.matching(identifier: id).firstMatch,
            app.outlines.descendants(matching: .any).matching(identifier: id).firstMatch,
            app.collectionViews.descendants(matching: .any).matching(identifier: id).firstMatch,
            app.descendants(matching: .any).matching(identifier: id).firstMatch,
            app.staticTexts.matching(identifier: id).firstMatch,
            app.staticTexts[label]
        ]
        for candidate in candidates where candidate.waitForExistence(timeout: 1) {
            return candidate
        }
        return app.staticTexts[label]
    }

    @MainActor
    private func staticText(in app: XCUIApplication, id: String, label: String) -> XCUIElement {
        let identifiedText = app.staticTexts[id]
        if identifiedText.exists {
            return identifiedText
        }
        return app.staticTexts[label]
    }

    @MainActor
    private func textValue(of element: XCUIElement) -> String {
        (element.value as? String) ?? element.label
    }

    @MainActor
    private func paste(_ text: String, into element: XCUIElement) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        element.click()
        element.typeKey("v", modifierFlags: .command)
    }

    @MainActor
    private func clear(_ element: XCUIElement) {
        element.click()
        element.typeKey("a", modifierFlags: .command)
        element.typeKey(.delete, modifierFlags: [])
    }

    @MainActor
    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "enabled == true")
        let expectation = expectation(for: predicate, evaluatedWith: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = expectation(for: predicate, evaluatedWith: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForTextValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label == %@ OR value == %@", value, value)
        let expectation = expectation(for: predicate, evaluatedWith: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
