/// Launch protocol shared by the app and its UI runner. Each scenario describes
/// one coherent starting state; independent Boolean switches could leave setup
/// permanently checking while a test tried to use disabled import controls.
nonisolated enum UITestScenario: String {
    case freshInstall = "fresh-install"
    case installedEmpty = "installed-empty"
    case installedTasks = "installed-tasks"

    static let installedEngineVersion = "3.0.8"

    static func read(from environment: [String: String]) -> Self? {
        guard environment["CHOPCHOP_UI_TESTING"] == "1",
              let value = environment["CHOPCHOP_UI_SCENARIO"] else { return nil }
        return Self(rawValue: value)
    }
}
