import SwiftUI
import SwiftData

/// The Saga tab: on-device AI patch notes synthesized from the week's telemetry.
struct NarrativeView: View {
    @Environment(\.modelContext) private var modelContext

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

                    Text("Patch notes are synthesized entirely on-device. Your training telemetry never leaves this phone.")
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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "scroll.fill")
                    .foregroundStyle(Theme.gold)
                Text("WEEKLY PATCH NOTES")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textDim)
                    .kerning(1.5)
            }
            Text(notes)
                .font(.system(.subheadline, design: .monospaced))
                .lineSpacing(5)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.limitBreakGradient.opacity(0.5), lineWidth: 1)
        )
    }

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

    private func generate() {
        isGenerating = true
        Haptics.shared.tick()
        let snapshot = NarrativeEngine.weeklyTelemetry(context: modelContext)
        telemetry = snapshot
        Task { @MainActor in
            let notes = await NarrativeEngine.generatePatchNotes(from: snapshot)
            withAnimation(.spring(duration: 0.4)) {
                patchNotes = notes
                isGenerating = false
            }
            Haptics.shared.success()
        }
    }
}
