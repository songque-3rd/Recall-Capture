import Foundation

public struct BrowserWindowCandidate: Equatable, Sendable {
    public let id: UInt32
    public let title: String
    public let applicationName: String
    public let bundleIdentifier: String
    public let isOnScreen: Bool
    public let windowLayer: Int
    public let width: Double
    public let height: Double

    public init(
        id: UInt32,
        title: String,
        applicationName: String,
        bundleIdentifier: String,
        isOnScreen: Bool,
        windowLayer: Int = 0,
        width: Double,
        height: Double
    ) {
        self.id = id
        self.title = title
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.isOnScreen = isOnScreen
        self.windowLayer = windowLayer
        self.width = width
        self.height = height
    }
}

public enum BrowserWindowFilter {
    public static let supportedBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.hnc.Discord",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "us.zoom.xos"
    ]

    private static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "org.mozilla.firefox"
    ]

    public static func visibleUniqueWindows(
        from candidates: [BrowserWindowCandidate]
    ) -> [BrowserWindowCandidate] {
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard supportedBundleIdentifiers.contains(candidate.bundleIdentifier),
                  candidate.isOnScreen,
                  candidate.windowLayer == 0,
                  candidate.width >= 200,
                  candidate.height >= 120,
                  !title.isEmpty,
                  !isBrowserShellTitle(
                    title,
                    applicationName: candidate.applicationName,
                    bundleIdentifier: candidate.bundleIdentifier
                  ) else {
                return nil
            }
            let duplicateKey = [
                candidate.bundleIdentifier.lowercased(),
                title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            ].joined(separator: "\u{1F}")
            guard seen.insert(duplicateKey).inserted else { return nil }
            return BrowserWindowCandidate(
                id: candidate.id,
                title: title,
                applicationName: candidate.applicationName,
                bundleIdentifier: candidate.bundleIdentifier,
                isOnScreen: candidate.isOnScreen,
                windowLayer: candidate.windowLayer,
                width: candidate.width,
                height: candidate.height
            )
        }
        .sorted { lhs, rhs in
            let lhsIsMeeting = isLikelyMeetingWindow(lhs)
            let rhsIsMeeting = isLikelyMeetingWindow(rhs)
            if lhsIsMeeting != rhsIsMeeting { return lhsIsMeeting }
            let lhsLabel = "\(lhs.applicationName) — \(lhs.title)"
            let rhsLabel = "\(rhs.applicationName) — \(rhs.title)"
            return lhsLabel.localizedStandardCompare(rhsLabel) == .orderedAscending
        }
    }

    private static func isBrowserShellTitle(
        _ title: String,
        applicationName: String,
        bundleIdentifier: String
    ) -> Bool {
        guard browserBundleIdentifiers.contains(bundleIdentifier) else { return false }
        let normalize: (String) -> String = {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let normalizedTitle = normalize(title)
        let shellTitles = [
            applicationName,
            "Safari",
            "Google Chrome",
            "Chrome",
            "Microsoft Edge",
            "Firefox"
        ].map(normalize)
        return shellTitles.contains(normalizedTitle)
    }

    private static func isLikelyMeetingWindow(_ candidate: BrowserWindowCandidate) -> Bool {
        let searchable = "\(candidate.applicationName) \(candidate.title)"
        return ["Meet", "Zoom", "Discord"].contains {
            searchable.localizedCaseInsensitiveContains($0)
        }
    }
}
