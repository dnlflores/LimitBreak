import SwiftUI
import SwiftData

/// Logs a non-lifting activity — basketball, volleyball, a swim — with time
/// played converting straight into XP.
struct ActivityLogView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// The activity being corrected, or nil when logging a fresh one.
    private let editing: Activity?

    @State private var sport: SportType
    @State private var minutes: Double
    @State private var date: Date

    init(activity: Activity? = nil) {
        self.editing = activity
        _sport = State(initialValue: activity?.sport ?? .basketball)
        _minutes = State(initialValue: Double(activity?.durationMinutes ?? 60))
        _date = State(initialValue: activity?.date ?? Date())
    }

    private var earnedXP: Int {
        XPEngine.xpForActivity(minutes: Int(minutes))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                sectionLabel("SPORT")
                sportCard

                sectionLabel("TIME PLAYED")
                durationCard

                sectionLabel("WHEN")
                dateCard

                xpPreview

                logButton
                    .padding(.top, 8)
            }
            .padding()
        }
        .obsidianBackground()
        .presentationDragIndicator(.visible)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(editing == nil ? "Log Activity" : "Edit Activity")
                    .font(.title.bold())
                Text(editing == nil
                     ? "Cross-training earns XP too."
                     : "Fix the sport, the time played, or when it happened.")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .glassCircle()
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .kerning(1.5)
            .foregroundStyle(Theme.textDim)
            .padding(.top, 6)
    }

    // MARK: Sport picker

    private var sportCard: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
            ForEach(SportType.allCases) { type in
                let isSelected = sport == type
                Button {
                    sport = type
                    Haptics.shared.tick()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: type.icon)
                            .font(.title3)
                            .foregroundStyle(isSelected ? Color.black : Theme.coral)
                        Text(type.rawValue)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        isSelected ? AnyShapeStyle(Theme.coral) : AnyShapeStyle(Theme.surfaceRaised),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(isSelected ? AnyShapeStyle(.clear) : AnyShapeStyle(Theme.glassBorder), lineWidth: 1)
                    )
                    .foregroundStyle(isSelected ? .black : .primary)
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
        .cardStyle()
    }

    // MARK: Duration

    private var durationCard: some View {
        VStack(spacing: 10) {
            HapticDial(label: "MINUTES", value: $minutes, step: 5, unit: "min")

            HStack(spacing: 8) {
                ForEach([30.0, 45, 60, 90, 120], id: \.self) { preset in
                    let isSelected = minutes == preset
                    Button("\(Int(preset))m") {
                        minutes = preset
                        Haptics.shared.tick()
                    }
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        isSelected ? AnyShapeStyle(Theme.coral) : AnyShapeStyle(Theme.surfaceRaised),
                        in: Capsule()
                    )
                    .foregroundStyle(isSelected ? .black : .primary)
                    .buttonStyle(.plain)
                }
            }
        }
        .cardStyle()
    }

    // MARK: Date

    private var dateCard: some View {
        DatePicker(
            "Played on",
            selection: $date,
            in: ...Date(),
            displayedComponents: [.date, .hourAndMinute]
        )
        .font(.subheadline)
        .tint(Theme.coral)
        .cardStyle()
    }

    // MARK: XP preview

    private var xpPreview: some View {
        HStack(spacing: 10) {
            Image(systemName: "star.circle.fill")
                .font(.title3)
                .foregroundStyle(Theme.limitBreakGradient)
            Text("You\u{2019}ll earn")
                .font(.subheadline)
                .foregroundStyle(Theme.textDim)
            Text("+\(earnedXP) XP")
                .font(.system(.title3, design: .rounded, weight: .black))
                .monospacedDigit()
                .foregroundStyle(Theme.gold)
                .contentTransition(.numericText())
                .animation(.snappy, value: earnedXP)
            Spacer()
        }
        .cardStyle()
    }

    // MARK: Save

    private var logButton: some View {
        Button {
            log()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: sport.icon)
                Text(editing == nil ? "LOG ACTIVITY" : "SAVE CHANGES")
                    .kerning(1.5)
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(.white)
            .glassCTA(tint: Theme.coral.opacity(0.85))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(minutes <= 0)
    }

    private func log() {
        if let editing {
            editing.sportRaw = sport.rawValue
            editing.date = date
            editing.durationMinutes = Int(minutes)
        } else {
            modelContext.insert(Activity(sport: sport, date: date, durationMinutes: Int(minutes)))
        }
        try? modelContext.save()
        Haptics.shared.success()
        WidgetSnapshotter.shared.refresh()
        StepGoalMonitor.shared.refreshStreakReminder()
        dismiss()
    }
}
