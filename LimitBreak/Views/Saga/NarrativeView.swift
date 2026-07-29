import SwiftUI
import SwiftData

/// The Saga tab: AI patch notes synthesized from the week's telemetry, using
/// whichever coaching tier the lifter has selected in Settings.
struct NarrativeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [TrainingProfile]

    @State private var patchNotes: String?
    @State private var isGenerating = false
    @State private var telemetry = WeeklyTelemetry()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    titleHeader

                    telemetryCard

                    if let patchNotes {
                        patchNotesCard(patchNotes)
                    }

                    generateButton

                    Text(privacyFooter)
                        .font(.caption2)
                        .foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .obsidianBackground()
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                telemetry = NarrativeEngine.weeklyTelemetry(context: modelContext)
            }
        }
    }

    private var titleHeader: some View {
        HStack(alignment: .center) {
            Text("Saga")
                .font(.largeTitle.bold())
            Spacer()
        }
        .padding(.bottom, 8)
    }

    private var telemetryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("THIS WEEK'S TELEMETRY")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textDim)
                .kerning(1.5)

            HStack {
                telemetryStat("\(telemetry.sessionCount)", "Sessions", Theme.emerald)
                telemetryStat("\(telemetry.setCount)", "Sets", Theme.emerald)
                telemetryStat(Int(telemetry.totalVolume).formatted(.number.notation(.compactName)), "lbs Moved", Theme.violet)
                telemetryStat("\(telemetry.prCount)", "Records", Theme.gold)
            }
        }
        .cardStyle()
    }

    private func telemetryStat(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity)
    }

    private func patchNotesCard(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "scroll.fill")
                    .foregroundStyle(Theme.gold)
                Text("WEEKLY PATCH NOTES")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textDim)
                    .kerning(1.5)
            }

            let blocks = PatchNotesFormatter.blocks(from: notes)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    patchBlock(block, index: index)
                }
            }
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Theme.limitBreakGradient.opacity(0.5), lineWidth: 1)
        )
    }

    /// Renders one parsed Markdown block. Headings become the week's title,
    /// bullets get a cycling accent marker plus tinted text — so the card reads
    /// like a color-coded RPG changelog rather than a wall of monospace.
    @ViewBuilder
    private func patchBlock(_ block: PatchNotesFormatter.PatchBlock, index: Int) -> some View {
        switch block {
        case let .heading(text, level):
            headingView(text, level: level, isFirst: index == 0)
        case let .bullet(text):
            let accent = Self.markerAccents[index % Self.markerAccents.count]
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("◆")
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

    /// A Markdown header. The `## ` week title reads as a neon banner; deeper
    /// `### ` headers fall back to a dim, kerned section label matching the
    /// app's card headers.
    @ViewBuilder
    private func headingView(_ text: String, level: Int, isFirst: Bool) -> some View {
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

    private var generateButton: some View {
        Button {
            generate()
        } label: {
            HStack {
                if isGenerating {
                    ProgressView()
                        .tint(.black)
                } else {
                    Image(systemName: "sparkles")
                }
                Text(patchNotes == nil ? "GENERATE PATCH NOTES" : "REGENERATE")
                    .font(.subheadline.weight(.bold))
                    .kerning(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.limitBreakGradient, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.black)
        }
        .disabled(isGenerating)
    }

    /// The provider to route generation through, or nil when cloud AI is off —
    /// in which case the notes are synthesized on-device.
    private var activeProvider: AIProvider? {
        guard let profile = profiles.first, profile.cloudAIEnabled else { return nil }
        return profile.aiProvider
    }

    /// Where the notes are composed — and therefore where the week's telemetry
    /// goes — tracks the AI provider chosen in Settings. When a provider is
    /// selected but not yet configured, generation falls back on-device, so the
    /// footer says so too.
    private var privacyFooter: String {
        let onDevice = "Patch notes are synthesized entirely on-device. Your training telemetry never leaves this phone."
        guard let profile = profiles.first, profile.cloudAIEnabled else { return onDevice }
        switch profile.aiProvider {
        case .claude where CloudWorkoutAI.isConfigured:
            return "Patch notes are composed by Claude. Your weekly training telemetry is sent to Anthropic to write them — nothing else leaves your device."
        case .odysseus where OdysseusConfig.isConfigured:
            return "Patch notes are composed by your own Odysseus server. Your weekly training telemetry is sent over your tailnet to write them — nothing else leaves your device."
        default:
            return onDevice
        }
    }

    private func generate() {
        isGenerating = true
        Haptics.shared.tick()
        let snapshot = NarrativeEngine.weeklyTelemetry(context: modelContext)
        telemetry = snapshot
        let provider = activeProvider
        Task { @MainActor in
            let notes = await NarrativeEngine.generatePatchNotes(from: snapshot, provider: provider)
            withAnimation(.spring(duration: 0.4)) {
                patchNotes = notes
                isGenerating = false
            }
            Haptics.shared.success()
        }
    }
}

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
