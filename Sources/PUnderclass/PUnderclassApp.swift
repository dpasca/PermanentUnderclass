import AppKit
import SwiftUI

enum PUnderclassApplicationIcon {
    private static let resourceName = "AppIcon"

    @discardableResult
    static func install(
        on application: NSApplication = .shared,
        bundle: Bundle = .main
    ) -> Bool {
        guard
            let iconURL = bundle.url(
                forResource: resourceName,
                withExtension: "icns"
            ),
            let icon = NSImage(contentsOf: iconURL)
        else {
            return false
        }

        application.applicationIconImage = icon
        return true
    }
}

@main
struct PUnderclassApp: App {
    @NSApplicationDelegateAdaptor(PUnderclassAppDelegate.self)
    private var appDelegate
    @StateObject private var applicationModel = PUnderclassApplicationModel()

    var body: some Scene {
        WindowGroup("PermanentUnderclass") {
            if let controller = applicationModel.controller {
                ContentView(
                    controller: controller,
                    documentationDemoMode: applicationModel.documentationDemoMode
                )
            } else {
                Color.clear
            }
        }
        .defaultSize(
            width: 1_160,
            height: applicationModel.documentationDemoMode == .quickDictation
                ? 560
                : 900
        )

        Window(
            "Meeting & Interview Preparation",
            id: PUnderclassWindow.preparation
        ) {
            if let controller = applicationModel.controller {
                ReferenceMaterialView(controller: controller)
            } else {
                Color.clear
            }
        }
        .defaultSize(width: 900, height: 820)

        // Every setting has one home, reachable with the standard ⌘, rather
        // than through several header popovers.
        Settings {
            if let controller = applicationModel.controller {
                SettingsView(controller: controller)
            } else {
                Color.clear
            }
        }
    }
}

/// Owns the shared services used by the app's main and auxiliary windows.
final class PUnderclassApplicationModel: ObservableObject {
    let controller: MeetingController?
    let documentationDemoMode: DocumentationDemoMode?

    init() {
        documentationDemoMode = DocumentationDemoMode.requested()
        let isSelfTest = DictationSelfTestRunner.isRequested
            || MeetingCaptureSelfTestRunner.isRequested
        if let documentationDemoMode {
            controller = MeetingController.documentationDemo(documentationDemoMode)
        } else if isSelfTest || !ApplicationInstanceCoordinator.shared.isPrimary {
            controller = nil
        } else {
            controller = MeetingController()
        }
    }
}

final class PUnderclassAppDelegate: NSObject, NSApplicationDelegate {
    private let instanceCoordinator = ApplicationInstanceCoordinator.shared
    private var dictationSelfTest: DictationSelfTestRunner?
    private var meetingCaptureSelfTest: MeetingCaptureSelfTestRunner?
    private var headlessModeController: HeadlessModeController?
    private var documentationController: MeetingController?
    private var documentationWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let documentationDemoMode = DocumentationDemoMode.requested() {
            if !PUnderclassApplicationIcon.install() {
                NSLog("Could not load the bundled application icon.")
            }
            configureDocumentationWindow(for: documentationDemoMode)
            return
        }

        guard instanceCoordinator.isPrimary else {
            if !instanceCoordinator.activatePrimary() {
                NSLog(
                    "The existing PermanentUnderclass instance exited during launch. Please launch again."
                )
            }
            NSApplication.shared.terminate(nil)
            return
        }

        if !PUnderclassApplicationIcon.install() {
            NSLog("Could not load the bundled application icon.")
        }

        let headlessModeController = HeadlessModeController()
        self.headlessModeController = headlessModeController
        instanceCoordinator.setReopenHandler { [weak self] in
            self?.requestApplicationRestore()
        }
        do {
            try headlessModeController.start()
        } catch {
            NSLog(
                "Headless-mode shortcut unavailable: %@",
                error.localizedDescription
            )
        }

        if DictationSelfTestRunner.isRequested {
            let runner = DictationSelfTestRunner()
            dictationSelfTest = runner
            runner.start()
        } else if MeetingCaptureSelfTestRunner.isRequested {
            let runner = MeetingCaptureSelfTestRunner()
            meetingCaptureSelfTest = runner
            runner.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        instanceCoordinator.stop()
        headlessModeController?.stop()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        requestApplicationRestore()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        headlessModeController?.isHeadless != true
    }

    private func requestApplicationRestore() {
        DispatchQueue.main.async { [weak self] in
            self?.headlessModeController?.showApplication()
        }
    }

    private func configureDocumentationWindow(
        for mode: DocumentationDemoMode,
        attemptsRemaining: Int = 20
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let window = NSApplication.shared.windows.first(where: {
                $0.canBecomeMain
            }) else {
                if attemptsRemaining > 1 {
                    self?.configureDocumentationWindow(
                        for: mode,
                        attemptsRemaining: attemptsRemaining - 1
                    )
                } else {
                    self?.presentDocumentationWindow(for: mode)
                }
                return
            }

            let height: CGFloat = mode == .quickDictation ? 560 : 900
            window.setContentSize(NSSize(width: 1_160, height: height))
            window.center()
            window.collectionBehavior.insert(.moveToActiveSpace)
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    private func presentDocumentationWindow(for mode: DocumentationDemoMode) {
        let controller = MeetingController.documentationDemo(mode)
        let rootView = ContentView(
            controller: controller,
            documentationDemoMode: mode
        )
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PermanentUnderclass"
        window.contentViewController = NSHostingController(rootView: rootView)
        let height: CGFloat = mode == .quickDictation ? 560 : 900
        window.setContentSize(NSSize(width: 1_160, height: height))
        window.center()
        window.collectionBehavior.insert(.moveToActiveSpace)

        documentationController = controller
        documentationWindow = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
