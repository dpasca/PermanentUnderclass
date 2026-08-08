import SwiftUI

@main
struct PUnderclassApp: App {
    @NSApplicationDelegateAdaptor(PUnderclassAppDelegate.self)
    private var appDelegate
    @StateObject private var applicationModel = PUnderclassApplicationModel()

    var body: some Scene {
        WindowGroup("PUnderclass") {
            if let controller = applicationModel.controller {
                ContentView(controller: controller)
            } else {
                Color.clear
            }
        }
        .defaultSize(width: 1_160, height: 900)

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

    init() {
        let isSelfTest = DictationSelfTestRunner.isRequested
            || MeetingCaptureSelfTestRunner.isRequested
        controller = isSelfTest || !ApplicationInstanceCoordinator.shared.isPrimary
            ? nil
            : MeetingController()
    }
}

final class PUnderclassAppDelegate: NSObject, NSApplicationDelegate {
    private let instanceCoordinator = ApplicationInstanceCoordinator.shared
    private var dictationSelfTest: DictationSelfTestRunner?
    private var meetingCaptureSelfTest: MeetingCaptureSelfTestRunner?
    private var headlessModeController: HeadlessModeController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard instanceCoordinator.isPrimary else {
            if !instanceCoordinator.activatePrimary() {
                NSLog(
                    "The existing PUnderclass instance exited during launch. Please launch again."
                )
            }
            NSApplication.shared.terminate(nil)
            return
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
}
