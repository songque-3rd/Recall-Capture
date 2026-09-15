import Foundation

public struct SessionLocation: Equatable, Sendable {
    public let directory: URL
    public let summaryPDF: URL
    public let transcriptJSONL: URL

    public init(directory: URL) {
        self.directory = directory
        self.summaryPDF = directory.appendingPathComponent("summary.pdf", isDirectory: false)
        self.transcriptJSONL = directory.appendingPathComponent("transcript.jsonl", isDirectory: false)
    }
}

public struct SessionPathPolicy {
    public let timezone: TimeZone

    public init(timezone: TimeZone = .current) {
        self.timezone = timezone
    }

    public func location(
        under root: URL,
        startedAt: Date,
        title: String,
        sessionID: UUID
    ) -> SessionLocation {
        let year = formatted(startedAt, pattern: "yyyy")
        let month = formatted(startedAt, pattern: "yyyy-MM")
        let minute = formatted(startedAt, pattern: "yyyy-MM-dd_HHmm")
        let safeTitle = Self.sanitize(title)
        let shortID = sessionID.uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
            .prefix(4)
        let folderName = "\(minute)__\(safeTitle)__\(shortID)"
        let directory = root
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        return SessionLocation(directory: directory)
    }

    public func createDirectory(
        for location: SessionLocation,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: location.directory,
            withIntermediateDirectories: true
        )
    }

    public static func sanitize(_ title: String, maximumLength: Int = 48) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        var previousWasSeparator = false

        for scalar in trimmed.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                result.append("-")
                previousWasSeparator = true
            }
        }

        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if result.isEmpty {
            result = "無題"
        }
        return String(result.prefix(maximumLength))
    }

    private func formatted(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timezone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
