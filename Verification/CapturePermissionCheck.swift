@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

@main
enum CapturePermissionCheck {
    struct Failure: Error { let message: String }
    final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func record() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }

    static func main() async throws {
        let micStates: [(AVAuthorizationStatus, CapturePermissionState)] = [
            (.notDetermined, .notDetermined), (.authorized, .authorized),
            (.denied, .denied), (.restricted, .restricted)
        ]
        let speechStates: [(SFSpeechRecognizerAuthorizationStatus, CapturePermissionState)] = [
            (.notDetermined, .notDetermined), (.authorized, .authorized),
            (.denied, .denied), (.restricted, .restricted)
        ]
        for (mic, expectedMic) in micStates {
            for (speech, expectedSpeech) in speechStates {
                for allowed in [false, true] {
                    let requests = Requests()
                    let service = CapturePermissionService(
                        microphoneStatus: { mic },
                        requestMicrophone: { requests.record(); return allowed },
                        screenAccess: { false },
                        requestScreen: { requests.record(); return allowed },
                        speechStatus: { speech },
                        requestSpeech: { requests.record(); return allowed ? .authorized : .denied }
                    )
                    let snapshot = service.snapshot()
                    try check(snapshot.microphone == expectedMic, "Microphone state lost")
                    try check(snapshot.speechRecognition == expectedSpeech, "Speech state lost")
                    try check(snapshot.screenRecording == .unconfirmed, "Screen denial cannot be inferred")
                    try check(requests.count == 0, "Reading status must never request permission")
                    let microphoneAllowed = await service.requestMicrophoneIfNeeded()
                    let speechAllowed = await service.requestSpeechRecognitionIfNeeded()
                    try check(microphoneAllowed == (mic == .authorized || (mic == .notDetermined && allowed)), "Microphone result ignored")
                    try check(speechAllowed == (speech == .authorized || (speech == .notDetermined && allowed)), "Speech result ignored")
                    let expectedRequests = (mic == .notDetermined ? 1 : 0) + (speech == .notDetermined ? 1 : 0)
                    try check(requests.count == expectedRequests, "Denied/restricted/already authorized permissions must not prompt")
                    try check(service.requestScreenRecordingIfNeeded() == allowed, "Screen request result ignored")
                    try check(requests.count == expectedRequests + 1, "Explicit screen request missing")
                }
            }
        }
        let requests = Requests()
        let authorized = CapturePermissionService(
            microphoneStatus: { .authorized }, requestMicrophone: { requests.record(); return false },
            screenAccess: { true }, requestScreen: { requests.record(); return false },
            speechStatus: { .authorized }, requestSpeech: { requests.record(); return .denied }
        )
        try check(authorized.snapshot().screenRecording == .authorized, "Screen authorization lost")
        try check(authorized.requestScreenRecordingIfNeeded(), "Authorized screen request failed")
        try check(requests.count == 0, "Authorized screen permission must not prompt")
        print("capture-permissions: passed (32 refusal/authorization combinations; no real TCC requests)")
    }
}
