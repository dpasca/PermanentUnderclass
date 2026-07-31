import CoreAudio
import Darwin
import Foundation

/// Verifies process-tap creation under the signed app identity without opening
/// WebSockets or requiring a person to press Start Listening.
final class MeetingCaptureSelfTestRunner {
    static let argument = "--meeting-capture-self-test"
    static var isRequested: Bool {
        CommandLine.arguments.contains(argument)
    }

    private var capture: ProcessTapCapture?
    private var packetCount = 0
    private var isFinished = false

    func start() {
        do {
            let processes = try AudioProcessCatalog.load()
            let targetName = Self.argumentValue
            let target = targetName.flatMap { requestedName in
                processes.first(where: { $0.name == requestedName })
            } ?? processes.first(where: \.isProducingOutput) ?? processes.first

            guard let target else {
                finish(success: false, message: "No Core Audio process is available.")
                return
            }
            log(
                "target name=\(target.name) pid=\(target.pid) "
                    + "object_id=\(target.id) output=\(target.isProducingOutput)"
            )

            let capture = ProcessTapCapture()
            self.capture = capture
            try capture.start(processObjectID: target.id) { [weak self] _ in
                self?.packetCount += 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                self.finish(
                    success: true,
                    message: "process_tap=created packets=\(self.packetCount)"
                )
            }
        } catch {
            finish(success: false, message: error.localizedDescription)
        }
    }

    private static var argumentValue: String? {
        guard
            let index = CommandLine.arguments.firstIndex(of: argument),
            CommandLine.arguments.indices.contains(index + 1)
        else {
            return nil
        }
        return CommandLine.arguments[index + 1]
    }

    private func finish(success: Bool, message: String) {
        guard !isFinished else { return }
        isFinished = true
        capture?.stop()
        capture = nil
        log("RESULT \(success ? "PASS" : "FAIL") \(message)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            _exit(success ? EXIT_SUCCESS : EXIT_FAILURE)
        }
    }

    private func log(_ message: String) {
        let line = "MEETING_CAPTURE_SELF_TEST \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}
