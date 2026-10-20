import Foundation

public enum TranscriptText {
    /// Preserve supplied spaces; Japanese token boundaries do not imply spaces.
    public static func join(_ segments: [String]) -> String {
        segments.reduce(into: "") { output, text in
            guard !text.isEmpty else { return }
            if let prior = output.last, let next = text.first,
               !prior.isWhitespace, !next.isWhitespace,
               isLatinOrNumber(prior), isLatinOrNumber(next) {
                output += " "
            }
            output += text
        }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Missing confidence is never replaced by an invented measurement.
    public static func confidence(_ values: [Double?]) -> Double? {
        guard !values.isEmpty, values.allSatisfy({ $0?.isFinite == true }) else { return nil }
        let provided = values.compactMap { $0 }
        return min(1, max(0, provided.reduce(0, +) / Double(provided.count)))
    }

    private static func isLatinOrNumber(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x41 && scalar.value <= 0x5A)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A)
                || CharacterSet.decimalDigits.contains(scalar)
        }
    }
}
