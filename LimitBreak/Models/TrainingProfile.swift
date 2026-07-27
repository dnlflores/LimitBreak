import Foundation
import SwiftData

// MARK: - Goal

/// What the lifter is training *for*. Drives rep ranges, rest, exercise
/// selection, and how hard the AI pushes loads.
enum TrainingGoal: String, Codable, CaseIterable, Identifiable {
    case loseFat = "Lose Fat"
    case buildMuscle = "Build Muscle"
    case getToned = "Get Toned"
    case getStronger = "Get Stronger"
    case endurance = "Improve Endurance"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .loseFat:     return "flame.fill"
        case .buildMuscle: return "figure.strengthtraining.traditional"
        case .getToned:    return "figure.cooldown"
        case .getStronger: return "dumbbell.fill"
        case .endurance:   return "figure.run"
        }
    }

    /// One-line description shown under the goal in onboarding and settings.
    var blurb: String {
        switch self {
        case .loseFat:     return "Higher volume, shorter rest, more calories burned per session."
        case .buildMuscle: return "Moderate reps near failure, enough rest to keep loads high."
        case .getToned:    return "Full-body balance at moderate loads — definition without bulk."
        case .getStronger: return "Heavy compounds, low reps, long rest between sets."
        case .endurance:   return "Light loads, high reps, minimal rest to build work capacity."
        }
    }

    /// The prescription the coach should follow for this goal. Written for the
    /// model, not the user — it lands verbatim in the request.
    var coachingBrief: String {
        switch self {
        case .loseFat:
            return """
                Prioritize total work done and calories burned. Favor compound, \
                multi-joint movements and supersets-friendly ordering. Rep range \
                12-20, rest 45-60s, loads around 60-70% of the lifter's ceiling.
                """
        case .buildMuscle:
            return """
                Prioritize mechanical tension and volume per muscle group. Rep \
                range 6-12 taken close to failure, rest 90-150s, loads around \
                70-80% of the lifter's ceiling. Include at least one heavy \
                compound per session before isolation work.
                """
        case .getToned:
            return """
                Balance the whole body rather than specializing. Rep range 10-15, \
                rest 60-90s, loads around 60-70% of the lifter's ceiling. Mix \
                compound and isolation work; avoid pure powerlifting rep schemes.
                """
        case .getStronger:
            return """
                Prioritize maximal force production. Lead with heavy barbell \
                compounds. Rep range 3-6, rest 180-240s, loads around 82-90% of \
                the lifter's ceiling. Keep accessory volume low so the main lifts \
                stay heavy.
                """
        case .endurance:
            return """
                Prioritize sustained work capacity. Rep range 15-25, rest 30-45s, \
                loads around 50-60% of the lifter's ceiling. Favor movements that \
                can be cycled continuously without technical breakdown.
                """
        }
    }
}

// MARK: - Experience

enum ExperienceLevel: String, Codable, CaseIterable, Identifiable {
    case beginner = "Beginner"
    case intermediate = "Intermediate"
    case advanced = "Advanced"

    var id: String { rawValue }

    var blurb: String {
        switch self {
        case .beginner:     return "New to lifting, or back after a long break."
        case .intermediate: return "Comfortable with the main lifts, training consistently."
        case .advanced:     return "Years under the bar, chasing specific numbers."
        }
    }

    /// How the coach should pitch complexity and volume.
    var coachingBrief: String {
        switch self {
        case .beginner:
            return "Favor machines, dumbbells, and stable movement patterns. Keep sessions to a handful of movements. Avoid technically demanding lifts like snatch-grip work or Zercher squats."
        case .intermediate:
            return "The full catalog is fair game. Assume solid technique on the main barbell lifts."
        case .advanced:
            return "Assume advanced technique. Specialty bars, tempo work, and demanding variations are all appropriate."
        }
    }
}

// MARK: - AI provider

/// Which backend answers when cloud coaching is on.
///
/// Both tiers send the same curated prompts (`PromptBuilder`) — they differ in
/// where the model runs and what it costs. Claude is hosted and billed per
/// token; Odysseus is the lifter's own machine, free but only reachable on
/// their tailnet.
enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case claude = "Claude"
    case odysseus = "Odysseus"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude:   return "Claude"
        case .odysseus: return "My own server"
        }
    }

    var blurb: String {
        switch self {
        case .claude:
            return "Anthropic's hosted model. Works anywhere, billed to your API key."
        case .odysseus:
            return "Your Odysseus server. Free and private."
        }
    }

    var icon: String {
        switch self {
        case .claude:   return "cloud.fill"
        case .odysseus: return "desktopcomputer"
        }
    }
}

// MARK: - Profile

/// The lifter's training preferences. Captured once at first launch and
/// editable in Settings afterward. Exactly one of these exists per install —
/// `TrainingProfile.current(in:)` creates it on demand.
@Model
final class TrainingProfile {
    @Attribute(.unique) var id: UUID
    var goalRaw: String
    var experienceRaw: String
    /// Target training days per week — context for how much recovery the coach
    /// can assume between sessions.
    var daysPerWeek: Int
    /// Whether the lifter has opted into sending training data to a model.
    /// Off until they explicitly turn it on; the on-device generator is used
    /// until then.
    var cloudAIEnabled: Bool
    /// Which backend coaches when `cloudAIEnabled` is on. Defaults to Claude so
    /// existing installs keep the behaviour they were set up with — SwiftData
    /// backfills this value on the lightweight migration.
    var aiProviderRaw: String = AIProvider.claude.rawValue
    /// Set once the first-launch flow has been completed or skipped, so it
    /// never reappears.
    var hasCompletedOnboarding: Bool
    var updatedAt: Date

    init(
        goal: TrainingGoal = .buildMuscle,
        experience: ExperienceLevel = .intermediate,
        daysPerWeek: Int = 4,
        cloudAIEnabled: Bool = false,
        hasCompletedOnboarding: Bool = false
    ) {
        self.id = UUID()
        self.goalRaw = goal.rawValue
        self.experienceRaw = experience.rawValue
        self.daysPerWeek = daysPerWeek
        self.cloudAIEnabled = cloudAIEnabled
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.updatedAt = Date()
    }

    var goal: TrainingGoal {
        get { TrainingGoal(rawValue: goalRaw) ?? .buildMuscle }
        set { goalRaw = newValue.rawValue; updatedAt = Date() }
    }

    var experience: ExperienceLevel {
        get { ExperienceLevel(rawValue: experienceRaw) ?? .intermediate }
        set { experienceRaw = newValue.rawValue; updatedAt = Date() }
    }

    var aiProvider: AIProvider {
        get { AIProvider(rawValue: aiProviderRaw) ?? .claude }
        set { aiProviderRaw = newValue.rawValue; updatedAt = Date() }
    }

    /// The single profile for this install, created on first access.
    @MainActor
    static func current(in context: ModelContext) -> TrainingProfile {
        let existing = (try? context.fetch(FetchDescriptor<TrainingProfile>())) ?? []
        if let profile = existing.first { return profile }
        let profile = TrainingProfile()
        context.insert(profile)
        try? context.save()
        return profile
    }
}
