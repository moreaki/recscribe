import Foundation

/// Experimental acoustic evidence, never permission to erase recognition or infer a language.
public struct MusicOnlyAssessment: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case instrumentalMusicCandidate, musicNeedsListeningReview, voiceOrMixed, inconclusive
    }

    public struct Window: Codable, Equatable, Sendable {
        public let start: Double
        public let end: Double
        public let scores: [String: Double]

        public init(start: Double, end: Double, scores: [String: Double]) {
            self.start = start
            self.end = end
            self.scores = scores
        }
    }

    // These are hypotheses for corpus evaluation, not calibrated accuracy percentages.
    public static let minimumMusicScore = 0.85
    public static let maximumVoiceScore = 0.05
    public static let minimumContextMusicScore = 0.80
    public static let minimumShortWindowMusicScore = 0.65
    public static let maximumWindows = 512
    public static let voiceLabels: Set<String> = [
        "speech", "shout", "yell", "battle_cry", "children_shouting", "screaming", "whispering",
        "laughter", "baby_laughter", "giggling", "snicker", "belly_laugh", "chuckle_chortle",
        "crying_sobbing", "baby_crying", "singing", "choir_singing", "yodeling", "rapping",
        "humming", "whistling", "cheering", "chatter", "crowd", "babble", "sigh",
        "breathing", "snoring", "gasp", "cough", "sneeze", "nose_blowing", "booing"
    ]
    public static let requiredLabels = voiceLabels.union(["music"])

    public let outcome: Outcome
    public let reason: String
    public let duration: Double
    public let windows: [Window]
    public let contextWindows: [Window]?
    public let voiceGuardWindows: [Window]?
    public let voiceGuardCompleted: Bool?
    public var automaticSuppressionAllowed: Bool { false }
    public var musicOnlyConfirmationAllowed: Bool {
        outcome == .instrumentalMusicCandidate && voiceGuardCompleted == true && voiceGuardWindows?.isEmpty == false
    }

    public static func evaluate(duration: Double, windows: [Window], completed: Bool,
                                contextWindows: [Window] = [], contextCompleted: Bool = false,
                                voiceGuardWindows: [Window] = [], voiceGuardCompleted: Bool = false) -> Self {
        func result(_ outcome: Outcome, _ reason: String) -> Self {
            let primary = Array(windows.prefix(maximumWindows))
            let voices = Array(voiceGuardWindows.prefix(maximumWindows - primary.count))
            return Self(outcome: outcome, reason: reason, duration: duration, windows: primary,
                 contextWindows: contextWindows.isEmpty ? nil : Array(contextWindows.prefix(maximumWindows - primary.count - voices.count)),
                 voiceGuardWindows: voiceGuardWindows.isEmpty ? nil : voices,
                 voiceGuardCompleted: voiceGuardWindows.isEmpty && !voiceGuardCompleted ? nil : voiceGuardCompleted)
        }
        guard duration.isFinite, (3...120).contains(duration), completed,
              !windows.isEmpty, windows.count <= maximumWindows else {
            return result(.inconclusive, "Incomplete analysis or unsupported duration")
        }
        // Reject malformed evidence before comparing scores; absent classes are not zero.
        func valid(_ windows: [Window], maximumSeconds: Double) -> Bool {
            windows.allSatisfy { window in
                window.start.isFinite && window.end.isFinite && window.start >= 0 &&
                window.end > window.start && window.end - window.start <= maximumSeconds + 0.000_001 &&
                window.end <= duration + 0.000_001 &&
                requiredLabels.allSatisfy { label in
                    guard let value = window.scores[label] else { return false }
                    return value.isFinite && (0...1).contains(value)
                }
            }
        }
        func hasVoice(_ windows: [Window]) -> Bool {
            windows.contains { window in voiceLabels.contains { window.scores[$0]! > maximumVoiceScore } }
        }
        func coversPassage(_ windows: [Window]) -> Bool {
            var coveredThrough = 0.0
            for window in windows.sorted(by: { $0.start < $1.start }) {
                guard window.start <= coveredThrough + 0.000_001 else { return false }
                coveredThrough = max(coveredThrough, window.end)
            }
            return coveredThrough >= duration - 0.000_001
        }
        guard valid(windows, maximumSeconds: 3) else { return result(.inconclusive, "Missing or invalid acoustic evidence") }
        if hasVoice(windows) { return result(.voiceOrMixed, "Voice evidence; preserve recognition") }
        guard coversPassage(windows) else { return result(.inconclusive, "Acoustic coverage is incomplete") }
        guard voiceGuardWindows.count <= maximumWindows - windows.count else {
            return result(.inconclusive, "Too many voice observations")
        }
        if !voiceGuardWindows.isEmpty {
            guard voiceGuardCompleted, valid(voiceGuardWindows, maximumSeconds: 1),
                  voiceGuardWindows.allSatisfy({ abs($0.end - $0.start - 1) < 0.000_001 }),
                  coversPassage(voiceGuardWindows) else {
                return result(.inconclusive, "Incomplete or invalid short-window voice evidence")
            }
            if hasVoice(voiceGuardWindows) { return result(.voiceOrMixed, "Voice evidence in short windows; preserve recognition") }
        }
        // If context evidence is present it must be complete, valid and voice-free,
        // even if the short-window music scores would pass on their own.
        if !contextWindows.isEmpty {
            guard duration >= 8, contextCompleted, contextWindows.count <= maximumWindows - windows.count - voiceGuardWindows.count,
                  valid(contextWindows, maximumSeconds: 8),
                  contextWindows.allSatisfy({ abs($0.end - $0.start - 8) < 0.000_001 }),
                  coversPassage(contextWindows) else {
                return result(.inconclusive, "Incomplete or invalid longer-context evidence")
            }
            if hasVoice(contextWindows) { return result(.voiceOrMixed, "Voice evidence in longer context; preserve recognition") }
        }
        if windows.allSatisfy({ $0.scores["music"]! >= minimumMusicScore }) {
            guard !voiceGuardWindows.isEmpty, voiceGuardCompleted else {
                return result(.inconclusive, "Short-window voice check required before music-only confirmation")
            }
            return result(.instrumentalMusicCandidate, "Experimental candidate; listening confirmation required")
        }
        if !contextWindows.isEmpty,
           windows.allSatisfy({ $0.scores["music"]! >= minimumShortWindowMusicScore }),
           contextWindows.allSatisfy({ $0.scores["music"]! >= minimumContextMusicScore }) {
            return result(.musicNeedsListeningReview, "Possible music in longer context; quiet speech cannot be ruled out")
        }
        return result(.inconclusive, "Music evidence is insufficient")
    }
}
