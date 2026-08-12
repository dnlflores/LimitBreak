import Foundation

/// The model-independent shape of a coach's spoken turn.
///
/// A turn is either the coach *acting* (one or more `CoachToolCall`s) or the
/// coach *speaking* — and every spoken turn, whichever tier produced it,
/// resolves to one of these. That is the whole point of the type: Claude, a
/// self-hosted model, and the on-device model all answer in different wire
/// formats, but the app only ever sees a `CoachReply`, so a reply reads and
/// renders identically no matter who wrote it.
///
/// `message` is the prose the lifter reads. `suggestions` are the optional
/// tappable follow-ups the chat offers underneath it — phrased as the lifter,
/// so tapping one sends it verbatim as their next message.
struct CoachReply: Codable, Sendable, Equatable {
    var message: String
    var suggestions: [String]

    init(message: String, suggestions: [String] = []) {
        self.message = message
        self.suggestions = Self.tidy(suggestions)
    }
}

extension CoachReply {

    /// The most follow-ups a reply should ever offer. More than a few stops
    /// being a nudge and becomes a menu the lifter has to read past.
    static let maxSuggestions = 3

    /// Reads a reply out of a model's free text.
    ///
    /// The tiers that emit their answer as text (Claude and the self-hosted
    /// model) are told to answer with a single `{"message": …, "suggestions":
    /// […]}` object. This finds that object even when it arrives fenced in
    /// ```json or trailed by stray prose, and falls back to treating the whole
    /// text as the message when there is no such object — a model that answered
    /// in plain prose still gets through, just without suggestions. That
    /// fallback is why a malformed answer degrades instead of failing the turn.
    static func parse(fromText text: String) -> CoachReply {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .found(let candidates) = JSONExtractor.scan(trimmed) {
            for candidate in candidates {
                let object = JSONValue.objectFrom(jsonText: candidate)
                guard let message = object.string("message") else { continue }
                return CoachReply(message: message, suggestions: object.stringArray("suggestions"))
            }
        }
        return CoachReply(message: trimmed)
    }

    /// Trims, drops blanks and duplicates, and caps the count — a model that
    /// pads the list, repeats itself, or leaves an empty slot shouldn't be able
    /// to push more chips onto the screen than the design allows.
    private static func tidy(_ suggestions: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for suggestion in suggestions {
            let trimmed = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
            if result.count == maxSuggestions { break }
        }
        return result
    }
}
