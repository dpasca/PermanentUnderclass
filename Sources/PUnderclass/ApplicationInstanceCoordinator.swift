import AppKit
import OSLog

/// Keeps independently built copies of PUnderclass from running concurrently.
/// Launch Services normally reopens an existing app, but development worktrees
/// contain distinct app bundles that can otherwise launch as separate processes.
final class ApplicationInstanceCoordinator: NSObject {
    static let shared = ApplicationInstanceCoordinator()

    private static let bundleIdentifier =
        "com.newtypekk.punderclass"
    private static let reopenNotification = Notification.Name(
        "com.newtypekk.punderclass.reopen"
    )
    private static let logger = Logger(
        subsystem: bundleIdentifier,
        category: "ApplicationInstance"
    )

    private let distributedNotifications =
        DistributedNotificationCenter.default()
    private let currentProcessIdentifier =
        ProcessInfo.processInfo.processIdentifier
    private let primaryApplication: NSRunningApplication?
    private var reopenHandler: (() -> Void)?
    private var hasPendingReopen = false
    private var isObserving = false

    var isPrimary: Bool {
        primaryApplication == nil
    }

    private override init() {
        let candidate = Self.findPrimaryApplication()
        primaryApplication = candidate.processIdentifier == currentProcessIdentifier
            ? nil
            : candidate
        super.init()
        if primaryApplication == nil {
            startObserving()
        }
    }

    func setReopenHandler(_ handler: @escaping () -> Void) {
        reopenHandler = handler
        guard hasPendingReopen else { return }
        hasPendingReopen = false
        handler()
    }

    /// Asks the older process to reveal itself, then brings it to the front.
    /// Returns false only when the process disappeared during this launch.
    @discardableResult
    func activatePrimary() -> Bool {
        guard
            let primaryApplication,
            !primaryApplication.isTerminated
        else {
            return false
        }

        distributedNotifications.postNotificationName(
            Self.reopenNotification,
            object: Self.bundleIdentifier,
            userInfo: nil,
            deliverImmediately: true
        )
        primaryApplication.activate(options: [.activateAllWindows])
        Self.logger.notice(
            "secondary_handed_off primary_pid=\(primaryApplication.processIdentifier, privacy: .public)"
        )
        return true
    }

    func stop() {
        guard isObserving else { return }
        distributedNotifications.removeObserver(self)
        isObserving = false
        reopenHandler = nil
        hasPendingReopen = false
    }

    private func startObserving() {
        guard !isObserving else { return }
        distributedNotifications.addObserver(
            self,
            selector: #selector(handleReopenRequest),
            name: Self.reopenNotification,
            object: Self.bundleIdentifier,
            suspensionBehavior: .deliverImmediately
        )
        isObserving = true
    }

    @objc private func handleReopenRequest(_ notification: Notification) {
        Self.logger.notice("reopen_requested")
        guard let reopenHandler else {
            hasPendingReopen = true
            return
        }
        reopenHandler()
    }

    private static func findPrimaryApplication() -> NSRunningApplication {
        let currentApplication = NSRunningApplication.current
        var applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        )
        .filter { !$0.isTerminated }
        if !applications.contains(where: {
            $0.processIdentifier == currentApplication.processIdentifier
        }) {
            applications.append(currentApplication)
        }

        return applications.min { left, right in
            let leftDate = left.launchDate ?? .distantFuture
            let rightDate = right.launchDate ?? .distantFuture
            if leftDate == rightDate {
                return left.processIdentifier < right.processIdentifier
            }
            return leftDate < rightDate
        } ?? currentApplication
    }

    deinit {
        stop()
    }
}
