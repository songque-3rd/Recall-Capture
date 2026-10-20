@preconcurrency import AVFoundation
import CaptureCore
import Foundation

struct AudioInputSnapshot: Sendable {
    let level: AudioSignalLevel
    let receivedAt: Date
    let lastSoundAt: Date?

    func isFresh(at now: Date) -> Bool { now.timeIntervalSince(receivedAt) < 2 }
    func hasRecentSound(at now: Date) -> Bool {
        lastSoundAt.map { now.timeIntervalSince($0) < 5 } ?? false
    }
}

enum AudioInputMeter {
    static func measure(_ buffer: AVAudioPCMBuffer) -> AudioSignalLevel {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return .init(rms: 0, peak: 0) }
        let stride = Int(buffer.stride)
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        var sum = 0.0, peak = 0.0, count = 0
        // Sample every frame so even brief clipping is visible.
        for channel in 0..<channels {
            for frame in 0..<frames {
                let data = list[buffer.format.isInterleaved ? 0 : channel].mData!
                let index = frame * stride + (buffer.format.isInterleaved ? channel : 0)
                let value: Double
                switch buffer.format.commonFormat {
                case .pcmFormatFloat32: value = Double(data.assumingMemoryBound(to: Float.self)[index])
                case .pcmFormatFloat64:
                    value = data.assumingMemoryBound(to: Double.self)[index]
                case .pcmFormatInt16: value = Double(data.assumingMemoryBound(to: Int16.self)[index]) / 32_768
                case .pcmFormatInt32: value = Double(data.assumingMemoryBound(to: Int32.self)[index]) / 2_147_483_648
                default: return .init(rms: 0, peak: 0)
                }
                guard value.isFinite else { continue }
                sum += value * value
                peak = max(peak, abs(value))
                count += 1
            }
        }
        return .init(rms: count > 0 ? sqrt(sum / Double(count)) : 0, peak: peak)
    }
}
