import Foundation

/// Pulls a JSON object out of a language model's reply.
///
/// Hosted APIs can constrain output to a schema server-side. A local model
/// behind `/api/chat` cannot — it returns whatever it generated, and in
/// practice that means the JSON arrives wrapped: fenced in ```json, prefaced
/// with "Sure, here's the plan:", or trailing a `<think>` block from a
/// reasoning model.
///
/// So `PromptBuilder.jsonOutputContract` asks for bare JSON, and this type
/// assumes it won't get it. Being permissive here is what makes a small local
/// model usable at all — the alternative is failing a two-minute generation
/// over a code fence.
enum JSONExtractor {

    /// What a scan found. The distinction between "no JSON at all" and
    /// "JSON that starts but never closes" matters: the first means the model
    /// ignored the format instruction, the second almost always means the
    /// reply hit an output-token limit mid-generation. Those have completely
    /// different fixes, so they're never collapsed into one failure.
    enum Outcome: Equatable {
        /// One or more balanced objects, in the order they appeared.
        case found([String])
        /// No `{` anywhere — the model replied in prose.
        case none
        /// An object opened and never closed. Reply was cut off.
        case truncated
    }

    /// Every balanced top-level object in `text`, plus a diagnosis when there
    /// are none.
    ///
    /// All of them, not just the first: a reasoning model often emits a small
    /// object before the real answer, and the plan is whichever candidate
    /// actually looks like a plan. Choosing between them is the caller's job.
    static func scan(_ text: String) -> Outcome {
        let source = strippingReasoning(text)

        var objects: [String] = []
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false

        for index in source.indices {
            let character = source[index]

            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }

            switch character {
            case "\"":
                inString = true
            case "{":
                if depth == 0 { start = index }
                depth += 1
            case "}":
                guard depth > 0 else { break }
                depth -= 1
                if depth == 0, let start {
                    objects.append(String(source[start...index]))
                }
            default:
                break
            }
        }

        if !objects.isEmpty { return .found(objects) }
        // Opened but never balanced, or ended inside a string literal.
        if depth > 0 || inString { return .truncated }
        return .none
    }

    /// The first complete JSON object in `text`, or nil if there isn't one.
    static func firstObject(in text: String) -> String? {
        guard case .found(let objects) = scan(text) else { return nil }
        return objects.first
    }

    /// The extracted object as UTF-8, ready to hand to `JSONDecoder`.
    static func objectData(in text: String) -> Data? {
        firstObject(in: text)?.data(using: .utf8)
    }

    /// Removes reasoning spans, which thinking models emit before their real
    /// answer. They're dropped before scanning because the model's scratch work
    /// often contains a draft JSON object.
    ///
    /// Two shapes are handled. A properly paired `<think>…</think>` is cut
    /// whole. A *bare* closing tag with no opener — which several Qwen and
    /// DeepSeek builds produce, because the chat template opens the block for
    /// them and only the close is echoed back — means everything before it was
    /// reasoning, so the answer is whatever follows the last one.
    ///
    /// An unclosed `<think>` (a generation cut short mid-thought) drops
    /// everything from the tag onward, which correctly yields no object rather
    /// than a truncated one.
    static func strippingReasoning(_ text: String) -> String {
        var result = text
        for tag in ["think", "thinking", "reasoning", "thought"] {
            result = removingSpans(open: "<\(tag)>", close: "</\(tag)>", in: result)
            result = droppingThroughOrphanClose("</\(tag)>", in: result)
        }
        return result
    }

    private static func removingSpans(open: String, close: String, in text: String) -> String {
        var result = text
        while let openRange = result.range(of: open, options: .caseInsensitive) {
            if let closeRange = result.range(
                of: close,
                options: .caseInsensitive,
                range: openRange.upperBound..<result.endIndex
            ) {
                result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
            } else {
                result.removeSubrange(openRange.lowerBound..<result.endIndex)
            }
        }
        return result
    }

    /// Keeps only what follows the last unmatched closing tag.
    private static func droppingThroughOrphanClose(_ close: String, in text: String) -> String {
        guard let last = text.range(of: close, options: [.caseInsensitive, .backwards]) else {
            return text
        }
        return String(text[last.upperBound...])
    }
}
