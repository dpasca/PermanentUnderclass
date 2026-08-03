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
        controller = isSelfTest ? nil : MeetingController()
    }
}

final class MeetingCopilotAppDelegate: NSObject, NSApplicationDelegate {
    private var dictationSelfTest: DictationSelfTestRunner?
    private var meetingCaptureSelfTest: MeetingCaptureSelfTestRunner?
    private var headlessModeController: HeadlessModeController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let headlessModeController = HeadlessModeController()
        self.headlessModeController = headlessModeController
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
        headlessModeController?.stop()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        headlessModeController?.isHeadless != true
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        headlessModeController?.isHeadless != true
    }
}
