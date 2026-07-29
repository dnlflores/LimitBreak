import SwiftUI

/// Turns a model's free-text patch notes into color-coded, per-line SwiftUI
/// text that matches the app's neon-on-obsidian aesthetic.
///
/// The notes arrive as loose prose — one flowing block from a self-hosted
/// model, or newline-separated lines from the on-device template — so this
/// splits them into readable entries and tints the parts that carry meaning:
/// every number in gold, and RPG signal words in their palette color.
enum PatchNotesFormatter {

    /// One parsed block of the Markdown patch notes.
    enum PatchBlock {
        case heading(String, level: Int)
        case bullet(String)
        case paragraph(String)
    }

    /// Parses the Markdown contract — a `## ` title followed by `- ` bullets —
    /// into renderable blocks. A model that ignored the contract and returned a
    /// prose blob (no headers or bullets) degrades gracefully into bulleted
    /// sentences, so the Saga still reads as a list rather than a wall of text.
    static func blocks(from notes: String) -> [PatchBlock] {
        var parsed: [PatchBlock] = []
        for raw in notes.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                let text = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { parsed.append(.heading(text, level: min(level, 3))) }
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                parsed.append(.bullet(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
            } else {
                parsed.append(.paragraph(stripMarker(line)))
            }
        }

        let hasStructure = parsed.contains {
            if case .paragraph = $0 { return false }
            return true
        }
        if hasStructure { return parsed }
        return lines(from: notes).map { .bullet($0) }
    }

    /// Splits raw notes into display lines. Honors explicit line breaks; a
    /// single unbroken block is broken into sentences instead, so it still
    /// reads as a list. Decimal points (e.g. `133.3`) are never treated as
    /// sentence ends.
    static func lines(from notes: String) -> [String] {
        let byNewline = notes
            .split(whereSeparator: \.isNewline)
            .map { stripMarker(String($0)) }
            .filter { !$0.isEmpty }
        if byNewline.count > 1 { return byNewline }

        let text = byNewline.first ?? notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return sentences(in: text).map(stripMarker).filter { !$0.isEmpty }
    }

    /// Breaks a block into sentences on terminal punctuation, but only when the
    /// next character is whitespace or the end — so `98.7` and `13.3` stay whole.
    private static func sentences(in text: String) -> [String] {
        let characters = Array(text)
        var result: [String] = []
        var current = ""
        for (index, character) in characters.enumerated() {
            current.append(character)
            let isTerminator = character == "." || character == "!" || character == "?"
            let nextIsBreak = index + 1 >= characters.count || characters[index + 1].isWhitespace
            if isTerminator && nextIsBreak {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    /// Drops a leading bullet or dash so a marker can be drawn consistently.
    private static func stripMarker(_ line: String) -> String {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        for marker in ["•", "◆", "-", "–", "—", "*", "·"] where trimmed.hasPrefix(marker) {
            trimmed = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return trimmed
    }

    /// Builds the tinted, word-by-word `Text` for one line, honoring inline
    /// `**bold**` markers. Any word carrying a digit is gold and bold; a
    /// recognized signal word takes its palette color; text inside `**` is
    /// bolded; everything else is left in the default foreground.
    static func styledText(for line: String) -> Text {
        var result = Text("")
        var firstWord = true
        for segment in inlineSegments(line) {
            for word in segment.text.split(separator: " ", omittingEmptySubsequences: true) {
                if !firstWord { result = result + Text(" ") }
                firstWord = false
                result = result + styledWord(String(word), bold: segment.bold)
            }
        }
        return result
    }

    /// Splits a line on `**` markers into bold and non-bold runs. Even chunks
    /// are normal, odd chunks are bold; an unbalanced trailing `**` leaves its
    /// chunk normal rather than bolding the rest of the line.
    private static func inlineSegments(_ line: String) -> [(text: String, bold: Bool)] {
        let parts = line.components(separatedBy: "**")
        let balanced = parts.count % 2 == 1
        var segments: [(text: String, bold: Bool)] = []
        for (index, part) in parts.enumerated() where !part.isEmpty {
            segments.append((part, balanced && index % 2 == 1))
        }
        return segments
    }

    private static func styledWord(_ word: String, bold: Bool = false) -> Text {
        if word.contains(where: \.isNumber) {
            return Text(word).foregroundStyle(Theme.gold).fontWeight(.bold)
        }
        let key = word.lowercased().filter(\.isLetter)
        if let color = keywordColors[key] {
            return Text(word).foregroundStyle(color).fontWeight(bold ? .bold : .semibold)
        }
        return Text(word).foregroundStyle(.white.opacity(0.92)).fontWeight(bold ? .bold : .regular)
    }

    /// Signal words worth lighting up, mapped to the palette meaning they carry
    /// elsewhere in the app: violet for LimitBreak energy, gold for records,
    /// emerald for streaks/momentum, teal for ceilings, coral for combat flavor.
    private static let keywordColors: [String: Color] = [
        "limitbreak": Theme.violet, "limitbreaks": Theme.violet,
        "record": Theme.gold, "records": Theme.gold, "pr": Theme.gold, "prs": Theme.gold,
        "streak": Theme.emerald, "momentum": Theme.emerald, "buff": Theme.emerald,
        "ceiling": Theme.teal, "ceilings": Theme.teal, "shattered": Theme.teal,
        "unlocked": Theme.teal, "expanded": Theme.teal,
        "boss": Theme.coral, "bosses": Theme.coral, "raid": Theme.coral, "raids": Theme.coral,
        "damage": Theme.coral, "critical": Theme.coral, "combo": Theme.coral, "combos": Theme.coral,
    ]
}

/// Renders parsed patch notes in the app's neon-on-obsidian voice.
///
/// Lifted wholesale from the old Saga card so a chapter written today looks
/// identical to the notes that view produced — the notes didn't change, only
/// where they live.
struct PatchNotesBody: View {
    let markdown: String

    var body: some View {
        let blocks = PatchNotesFormatter.blocks(from: markdown)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                renderBlock(block, index: index)
            }
        }
        .textSelection(.enabled)
    }

    /// One parsed Markdown block. Headings become the week's title, bullets get
    /// a cycling accent marker plus tinted text — so the chapter reads like a
    /// color-coded RPG changelog rather than a wall of monospace.
    @ViewBuilder
    private func renderBlock(_ block: PatchNotesFormatter.PatchBlock, index: Int) -> some View {
        switch block {
        case let .heading(text, level):
            heading(text, level: level, isFirst: index == 0)
        case let .bullet(text):
            let accent = Self.markerAccents[index % Self.markerAccents.count]
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\u{25C6}")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(accent)
                PatchNotesFormatter.styledText(for: text)
                    .font(.system(.subheadline, design: .monospaced))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        case let .paragraph(text):
            PatchNotesFormatter.styledText(for: text)
                .font(.system(.subheadline, design: .monospaced))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A Markdown header. The `## ` title reads as a neon banner; deeper `### `
    /// headers fall back to a dim, kerned section label matching the app's cards.
    @ViewBuilder
    private func heading(_ text: String, level: Int, isFirst: Bool) -> some View {
        if level >= 3 {
            Text(text.uppercased())
                .font(.caption.weight(.semibold))
                .kerning(1.5)
                .foregroundStyle(Theme.textDim)
                .padding(.top, isFirst ? 0 : 8)
        } else {
            Text(text)
                .font(.system(.title3, design: .rounded, weight: .heavy))
                .foregroundStyle(Theme.limitBreakGradient)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, isFirst ? 0 : 6)
                .padding(.bottom, 2)
        }
    }

    /// Accent colors the per-line markers rotate through, drawn from the app's
    /// neon palette.
    private static let markerAccents: [Color] = [Theme.emerald, Theme.violet, Theme.gold, Theme.teal]
}
