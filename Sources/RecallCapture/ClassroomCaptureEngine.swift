@preconcurrency import AVFoundation
import CaptureCore
import CoreMedia
import Foundation

struct MicrophoneDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

final class ClassroomCaptureEngine: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    typealias SampleHandler = @Sendable (AudioTrack, CMSampleBuffer) -> Void

    private let captureQueue: DispatchQueue
    private let sampleHandler: SampleHandler
    private var session: AVCaptureSession?

    init(captureQueue: DispatchQueue, sampleHandler: @escaping SampleHandler) {
        self.captureQueue = captureQueue
        self.sampleHandler = sampleHandler
    }

    static func availableMicrophones() -> [MicrophoneDescriptor] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices.map {
            MicrophoneDescriptor(id: $0.uniqueID, name: $0.localizedName)
        }
    }

    func start(deviceID: String?) throws {
        guard session == nil else { throw AudioCaptureError.alreadyRecording }
        let device: AVCaptureDevice?
        if let deviceID {
            device = AVCaptureDevice(uniqueID: deviceID)
        } else {
            device = AVCaptureDevice.default(for: .audio)
        }
        guard let device else { throw AudioCaptureError.noInputDevice }

        let newSession = AVCaptureSession()
        newSession.beginConfiguration()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard newSession.canAddInput(input) else { throw AudioCaptureError.cannotAddInput }
            newSession.addInput(input)

            let output = AVCaptureAudioDataOutput()
            guard newSession.canAddOutput(output) else { throw AudioCaptureError.cannotAddOutput }
            newSession.addOutput(output)
            output.setSampleBufferDelegate(self, queue: captureQueue)
            newSession.commitConfiguration()
        } catch {
            newSession.commitConfiguration()
            throw error
        }

        newSession.startRunning()
        session = newSession
    }

    func stop() {
        guard let session else { return }
        session.stopRunning()
        self.session = nil
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }
        sampleHandler(.microphone, sampleBuffer)
    }
}
