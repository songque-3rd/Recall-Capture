import Foundation

public enum SessionState: String, Equatable, Sendable {
    case idle
    case recording
    case finalizingAudio
    case detectingSpeech
    case transcribing
    case diarizing
    case formatting
    case writingArtifacts
    case validatingArtifacts
    case completed
    case failed
}

public enum SessionTransitionError: Error, Equatable {
    case invalidTransition(from: SessionState, to: SessionState)
}

public struct SessionStateMachine: Sendable {
    public private(set) var state: SessionState = .idle

    public init() {}

    public mutating func transition(to next: SessionState) throws {
        guard Self.allowedTransitions[state, default: []].contains(next) else {
            throw SessionTransitionError.invalidTransition(from: state, to: next)
        }
        state = next
    }

    private static let allowedTransitions: [SessionState: Set<SessionState>] = [
        .idle: [.recording, .detectingSpeech],
        .recording: [.finalizingAudio, .failed],
        .finalizingAudio: [.detectingSpeech, .failed],
        .detectingSpeech: [.transcribing, .failed],
        .transcribing: [.diarizing, .failed],
        .diarizing: [.formatting, .failed],
        .formatting: [.writingArtifacts, .failed],
        .writingArtifacts: [.validatingArtifacts, .failed],
        .validatingArtifacts: [.completed, .failed],
        .completed: [],
        .failed: []
    ]
}
