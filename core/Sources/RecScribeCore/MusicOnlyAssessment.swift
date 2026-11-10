import Foundation

/// Experimental acoustic evidence, never permission to erase recognition or infer a language.
public struct MusicOnlyAssessment: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case instrumentalMusicCandidate, voiceOrMixed, inconclusive
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
    public static let minimumMusicScore = 0.95
    public static let maximumVoiceScore = 0.05
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
    public var automaticSuppressionAllowed: Bool { false }

    public static func evaluate(duration: Double, windows: [Window], completed: Bool) -> Self {
        func result(_ outcome: Outcome, _ reason: String) -> Self {
            Self(outcome: outcome, reason: reason, duration: duration, windows: Array(windows.prefix(maximumWindows)))
        }
        guard duration.isFinite, (3...120).contains(duration), completed,
              !windows.isEmpty, windows.count <= maximumWindows else {
            return result(.inconclusive, "Incomplete analysis or unsupported duration")
        }
        // Reject malformed evidence before comparing scores; absent classes are not zero.
        guard windows.allSatisfy({ window in
            window.start.isFinite && window.end.isFinite && window.start >= 0 &&
            window.end > window.start && window.end - window.start <= 1.000_001 &&
            window.end <= duration + 0.000_001 &&
            requiredLabels.allSatisfy { label in
                guard let value = window.scores[label] else { return false }
                return value.isFinite && (0...1).contains(value)
            }
        }) else { return result(.inconclusive, "Missing or invalid acoustic evidence") }
        if windows.contains(where: { window in
            voiceLabels.contains { window.scores[$0]! > maximumVoiceScore }
        }) { return result(.voiceOrMixed, "Voice evidence; preserve recognition") }
        var coveredThrough = 0.0
        for window in windows.sorted(by: { $0.start < $1.start }) {
            guard window.start <= coveredThrough + 0.000_001 else {
                return result(.inconclusive, "Acoustic coverage has gaps")
            }
            coveredThrough = max(coveredThrough, window.end)
        }
        guard coveredThrough >= duration - 0.000_001 else {
            return result(.inconclusive, "Acoustic coverage is incomplete")
        }
        guard windows.allSatisfy({ $0.scores["music"]! >= minimumMusicScore }) else {
            return result(.inconclusive, "Music evidence is insufficient")
        }
        return result(.instrumentalMusicCandidate, "Experimental candidate; reviewed corpus validation required")
    }
}
