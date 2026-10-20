@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
@preconcurrency import Speech

enum CapturePermissionState: String, Sendable {
    case notDetermined, authorized, denied, restricted, unconfirmed
}

struct CapturePermissionSnapshot: Sendable {
    let microphone: CapturePermissionState
    let screenRecording: CapturePermissionState
    var speechRecognition: CapturePermissionState = .notDetermined
}

// Reading status never prompts. Explicit recording or meeting-window loading requests access.
// Dependencies let verification exercise every branch without touching macOS TCC.
struct CapturePermissionService: Sendable {
    var microphoneStatus: @Sendable () -> AVAuthorizationStatus = {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }
    var requestMicrophone: @Sendable () async -> Bool = {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
    var screenAccess: @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() }
    var requestScreen: @Sendable () -> Bool = { CGRequestScreenCaptureAccess() }
    var speechStatus: @Sendable () -> SFSpeechRecognizerAuthorizationStatus = {
        SFSpeechRecognizer.authorizationStatus()
    }
    var requestSpeech: @Sendable () async -> SFSpeechRecognizerAuthorizationStatus = {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    func snapshot() -> CapturePermissionSnapshot {
        CapturePermissionSnapshot(
            microphone: microphoneState,
            screenRecording: screenRecordingState,
            speechRecognition: speechRecognitionState
        )
    }

    var microphoneState: CapturePermissionState {
        switch microphoneStatus() {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unconfirmed
        }
    }

    var screenRecordingState: CapturePermissionState {
        // A false preflight result cannot distinguish denial from no prior request.
        screenAccess() ? .authorized : .unconfirmed
    }

    var speechRecognitionState: CapturePermissionState {
        switch speechStatus() {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unconfirmed
        }
    }

    func requestMicrophoneIfNeeded() async -> Bool {
        switch microphoneState {
        case .authorized: true
        case .notDetermined: await requestMicrophone()
        case .denied, .restricted, .unconfirmed: false
        }
    }

    func requestScreenRecordingIfNeeded() -> Bool {
        screenAccess() || requestScreen()
    }

    func requestSpeechRecognitionIfNeeded() async -> Bool {
        switch speechRecognitionState {
        case .authorized: true
        case .notDetermined: await requestSpeech() == .authorized
        case .denied, .restricted, .unconfirmed: false
        }
    }
}
