import Foundation

@objc(ChopChopEngineInstallerProtocol)
nonisolated protocol EngineInstallerProtocol: AppUpdateInstallerProtocol {
    func install(version: String, directoryBookmark: Data,
                 reply: @escaping @Sendable (String?, String?) -> Void)
}

@objc(ChopChopEngineInstallerProgressReporting)
nonisolated protocol EngineInstallerProgressReporting: AppUpdateProgressReporting {
    func reportProgress(_ data: Data)
}
