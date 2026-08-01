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

/// Owns services for the lifetime of the process rather than the lifetime of
/// one SwiftUI window. Quick Dictation therefore keeps working when its debug
/// window is closed and the app is effectively headless.
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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
}
