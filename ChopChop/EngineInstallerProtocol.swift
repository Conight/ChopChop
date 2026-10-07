import Foundation

@objc(ChopChopEngineInstallerProtocol)
nonisolated protocol EngineInstallerProtocol {
    func install(version: String, directoryBookmark: Data,
                 reply: @escaping @Sendable (String?, String?) -> Void)
}

@objc(ChopChopEngineInstallerProgressReporting)
nonisolated protocol EngineInstallerProgressReporting {
    func reportProgress(_ data: Data)
}
