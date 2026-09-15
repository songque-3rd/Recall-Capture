@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

enum CapturePermissionState: String, Sendable {
    case notDetermined
    case authorized
    case denied
}

struct CapturePermissionSnapshot: Sendable {
    let microphone: CapturePermissionState
    let screenRecording: CapturePermissionState
}

struct CapturePermissionService: Sendable {
    func snapshot() -> CapturePermissionSnapshot {
        CapturePermissionSnapshot(
            microphone: microphoneState,
            screenRecording: screenRecordingState
        )
    }

    var microphoneState: CapturePermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    var screenRecordingState: CapturePermissionState {
        CGPreflightScreenCaptureAccess() ? .authorized : .denied
    }

    func requestMicrophoneIfNeeded() async -> Bool {
        switch microphoneState {
        case .authorized: true
        case .denied: false
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    func requestScreenRecordingIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }
}
