import SwiftUI

@main
struct MeetingCopilotApp: App {
    @NSApplicationDelegateAdaptor(MeetingCopilotAppDelegate.self)
    private var appDelegate
    @StateObject private var applicationModel = MeetingCopilotApplicationModel()

    var body: some Scene {
        WindowGroup("PUnderclass") {
            if let controller = applicationModel.controller {
                ContentView(controller: controller)
            } else {
                Color.clear
            }
        }
        .defaultSize(width: 1_160, height: 900)
    }
}

/// Owns services for the lifetime of the app's single window.
final class MeetingCopilotApplicationModel: ObservableObject {
    let controller: MeetingController?

    init() {
        let isSelfTest = DictationSelfTestRunner.isRequested
            || MeetingCaptureSelfTestRunner.isRequested
        controller = isSelfTest || !ApplicationInstanceCoordinator.shared.isPrimary
            ? nil
            : MeetingController()
    }
}

final class MeetingCopilotAppDelegate: NSObject, NSApplicationDelegate {
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
