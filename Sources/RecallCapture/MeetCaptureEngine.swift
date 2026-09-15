import CaptureCore
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

struct MeetWindowDescriptor: Identifiable, Hashable, Sendable {
    let id: CGWindowID
    let title: String
    let applicationName: String
    let bundleIdentifier: String

    var label: String {
        title.isEmpty ? applicationName : "\(applicationName) — \(title)"
    }
}

final class MeetCaptureEngine: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    typealias SampleHandler = @Sendable (AudioTrack, CMSampleBuffer) -> Void
    typealias FailureHandler = @Sendable (Error) -> Void

    private let captureQueue: DispatchQueue
    private let sampleHandler: SampleHandler
    private let failureHandler: FailureHandler
    private var stream: SCStream?

    init(
        captureQueue: DispatchQueue,
        sampleHandler: @escaping SampleHandler,
        failureHandler: @escaping FailureHandler
    ) {
        self.captureQueue = captureQueue
        self.sampleHandler = sampleHandler
        self.failureHandler = failureHandler
    }

    static func availableWindows() async throws -> [MeetWindowDescriptor] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        let candidates = content.windows.compactMap { window -> BrowserWindowCandidate? in
            guard let application = window.owningApplication else { return nil }
            return BrowserWindowCandidate(
                id: window.windowID,
                title: window.title ?? "",
                applicationName: application.applicationName,
                bundleIdentifier: application.bundleIdentifier,
                isOnScreen: window.isOnScreen,
                windowLayer: window.windowLayer,
                width: Double(window.frame.width),
                height: Double(window.frame.height)
            )
        }
        return BrowserWindowFilter.visibleUniqueWindows(from: candidates).map { candidate in
            MeetWindowDescriptor(
                id: CGWindowID(candidate.id),
                title: candidate.title,
                applicationName: candidate.applicationName,
                bundleIdentifier: candidate.bundleIdentifier
            )
        }
    }

    func start(windowID: CGWindowID, microphoneDeviceID: String?) async throws {
        guard stream == nil else { throw AudioCaptureError.alreadyRecording }
        let content = try await SCShareableContent.current
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw AudioCaptureError.meetWindowUnavailable
        }

        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = true
        if let microphoneDeviceID {
            configuration.microphoneCaptureDeviceID = microphoneDeviceID
        }

        let newStream = SCStream(
            filter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration,
            delegate: self
        )
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
        try newStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: captureQueue)
        stream = newStream
        try await newStream.startCapture()
    }

    func stop() async throws {
        guard let stream else { return }
        try await stream.stopCapture()
        self.stream = nil
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        self.stream = nil
        failureHandler(error)
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }
        switch outputType {
        case .audio:
            sampleHandler(.system, sampleBuffer)
        case .microphone:
            sampleHandler(.microphone, sampleBuffer)
        default:
            break
        }
    }
}
