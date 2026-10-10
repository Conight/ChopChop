import Foundation
import IOKit.pwr_mgt

nonisolated enum PowerAssertionError: LocalizedError, Sendable {
    case acquisitionFailed(IOReturn)

    var errorDescription: String? {
        switch self {
        case .acquisitionFailed(let result):
            String(localized: "Could not prevent idle sleep. IOKit returned \(result).")
        }
    }
}

nonisolated protocol PowerAssertionControlling: AnyObject {
    var isAcquired: Bool { get }
    func update(preventSleep: Bool, hasActiveDownloads: Bool) throws
    func release()
}

nonisolated final class DownloadPowerAssertionController: PowerAssertionControlling {
    private var assertionID = IOPMAssertionID(0)
    private(set) var isAcquired = false

    func update(preventSleep: Bool, hasActiveDownloads: Bool) throws {
        guard preventSleep && hasActiveDownloads else {
            release()
            return
        }
        try acquireIfNeeded()
    }

    func release() {
        guard isAcquired else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isAcquired = false
    }

    deinit {
        release()
    }

    private func acquireIfNeeded() throws {
        guard !isAcquired else { return }
        var newAssertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            String(localized: "Active ChopChop downloads") as CFString,
            &newAssertionID
        )
        guard result == kIOReturnSuccess else {
            throw PowerAssertionError.acquisitionFailed(result)
        }
        assertionID = newAssertionID
        isAcquired = true
    }
}
