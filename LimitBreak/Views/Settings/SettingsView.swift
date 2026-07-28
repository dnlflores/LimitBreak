import SwiftUI
import SwiftData

/// Training profile and AI configuration. Everything here is editable at any
/// time — the same choices the first-launch flow asks for, plus the API key.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [TrainingProfile]

    @State private var keyDraft = ""
    @State private var isVerifying = false
    @State private var verification: Verification = .untested
    @State private var showKeyField = false
    @State private var showOdysseusSettings = false

    private enum Verification: Equatable {
        case untested
        case working
        case failed(String)
    }

    private var profile: TrainingProfile? { profiles.first }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let profile {
                        goalSection(profile)
                        experienceSection(profile)
                        frequencySection(profile)
                        aiSection(profile)
                    }
                }
                .padding()
            }
            .obsidianBackground()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .sheet(isPresented: $showOdysseusSettings) {
            OdysseusSettingsView()
        }
        .onAppear {
            if KeychainStore.hasKey { verification = .working }
        }
    }

    // MARK: - Profile

    private func goalSection(_ profile: TrainingProfile) -> some View {
        section("WHAT ARE YOU TRAINING FOR?") {
            VStack(spacing: 8) {
                ForEach(TrainingGoal.allCases) { goal in
                    choiceRow(
                        title: goal.rawValue,
                        blurb: goal.blurb,
                        icon: goal.icon,
                        isSelected: profile.goal == goal
                    ) {
                        profile.goal = goal
                        try? modelContext.save()
                    }
                }
            }
        }
    }

    private func experienceSection(_ profile: TrainingProfile) -> some View {
        section("EXPERIENCE") {
            VStack(spacing: 8) {
                ForEach(ExperienceLevel.allCases) { level in
                    choiceRow(
                        title: level.rawValue,
                        blurb: level.blurb,
                        icon: nil,
                        isSelected: profile.experience == level
                    ) {
                        profile.experience = level
                        try? modelContext.save()
                    }
                }
            }
        }
    }

    private func frequencySection(_ profile: TrainingProfile) -> some View {
        section("DAYS PER WEEK") {
            HStack(spacing: 8) {
                ForEach(2...6, id: \.self) { days in
                    let selected = profile.daysPerWeek == days
                    Button {
                        profile.daysPerWeek = days
                        try? modelContext.save()
                        Haptics.shared.tick()
                    } label: {
                        Text("\(days)")
                            .font(.headline)
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundStyle(selected ? .black : .white)
                            .background(
                                selected ? AnyShapeStyle(Theme.emerald) : AnyShapeStyle(Theme.surfaceRaised),
                                in: RoundedRectangle(cornerRadius: 12)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Tells the coach how much recovery to assume between sessions.")
                .font(.caption2)
                .foregroundStyle(Theme.textDim)
        }
    }

    // MARK: - AI

    private func aiSection(_ profile: TrainingProfile) -> some View {
        section("AI FEATURES") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { profile.cloudAIEnabled },
                    set: { profile.cloudAIEnabled = $0; try? modelContext.save(); Haptics.shared.tick() }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Smarter AI features")
                            .font(.subheadline.weight(.semibold))
                        Text("Powers fatigue-aware workout plans and your weekly Saga patch notes, tuned to your goal and recent training.")
                            .font(.caption)
                            .foregroundStyle(Theme.textDim)
                    }
                }
                .tint(Theme.emerald)

                if profile.cloudAIEnabled {
                    providerPicker(profile)
                    privacyNote(profile.aiProvider)

                    switch profile.aiProvider {
                    case .claude:   keyControls
                    case .odysseus: odysseusControls
                    }
                }
            }
            .cardStyle()
        }
    }

    private func providerPicker(_ profile: TrainingProfile) -> some View {
        VStack(spacing: 8) {
            ForEach(AIProvider.allCases) { provider in
                choiceRow(
                    title: provider.displayName,
                    blurb: provider.blurb,
                    icon: provider.icon,
                    isSelected: profile.aiProvider == provider
                ) {
                    profile.aiProvider = provider
                    try? modelContext.save()
                }
            }
        }
    }

    /// Says where the data actually goes — which is the whole point of letting
    /// the lifter choose a backend, so it changes with the selection.
    private func privacyNote(_ provider: AIProvider) -> some View {
        let destination = provider == .claude
            ? "sent to Anthropic"
            : "sent to your own Odysseus server over your tailnet"
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(Theme.teal)
            Text("When this is on, your training data — muscle fatigue, recent sessions, "
                 + "and recorded lifts — is \(destination) to generate a plan. Nothing else "
                 + "leaves your device, and everything keeps working offline without it.")
                .font(.caption2)
                .foregroundStyle(Theme.textDim)
        }
        .padding(10)
        .background(Theme.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    /// The self-hosted path has enough setup to warrant its own screen; this is
    /// the doorway plus a one-glance summary of what's configured.
    private var odysseusControls: some View {
        Button {
            showOdysseusSettings = true
            Haptics.shared.tick()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Server setup")
                        .font(.subheadline.weight(.semibold))
                    Text(odysseusSummary)
                        .font(.caption2)
                        .foregroundStyle(OdysseusConfig.isConfigured ? Theme.emerald : Theme.textDim)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textDim)
            }
            .padding(12)
            .foregroundStyle(.white)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var odysseusSummary: String {
        if OdysseusConfig.isConfigured, let model = OdysseusConfig.modelDisplayName {
            return "Ready — \(model)"
        }
        if OdysseusConfig.needsModelSelection {
            return "Connected, but no model picked yet."
        }
        return "Add your server URL and API token."
    }

    @ViewBuilder
    private var keyControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ANTHROPIC API KEY")
                    .font(.caption2.weight(.bold))
                    .kerning(1)
                    .foregroundStyle(Theme.textDim)
                Spacer()
                statusBadge
            }

            if let stored = KeychainStore.apiKey, !showKeyField {
                HStack {
                    Text(stored.maskedAPIKey)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.textDim)
                    Spacer()
                    Button("Replace") {
                        keyDraft = ""
                        showKeyField = true
                        Haptics.shared.tick()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.emerald)

                    Button("Remove", role: .destructive) {
                        KeychainStore.deleteAPIKey()
                        verification = .untested
                        Haptics.shared.tick()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.crimson)
                }
            } else {
                SecureField("sk-ant-...", text: $keyDraft)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.caption.monospaced())
                    .padding(12)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))

                Button {
                    Task { await saveAndVerify() }
                } label: {
                    HStack(spacing: 8) {
                        if isVerifying {
                            ProgressView().tint(.white)
                            Text("VERIFYING\u{2026}")
                        } else {
                            Image(systemName: "checkmark.shield")
                            Text("SAVE & VERIFY")
                        }
                    }
                    .font(.subheadline.weight(.bold))
                    .kerning(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(.white)
                    .glassCTA(tint: Theme.emerald.opacity(0.85))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isVerifying || keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if case .failed(let message) = verification {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(Theme.crimson)
            }

            Link(destination: URL(string: "https://console.anthropic.com/settings/keys")!) {
                Label("Get a key from the Anthropic Console", systemImage: "arrow.up.right.square")
                    .font(.caption2)
                    .foregroundStyle(Theme.violet)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch verification {
        case .working:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.emerald)
        case .failed:
            Label("Not working", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.crimson)
        case .untested:
            EmptyView()
        }
    }

    private func saveAndVerify() async {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isVerifying = true
        defer { isVerifying = false }

        guard KeychainStore.setAPIKey(trimmed) else {
            verification = .failed("Couldn't save the key to the Keychain.")
            return
        }

        switch await ClaudeClient.verifyKey() {
        case .success:
            verification = .working
            keyDraft = ""
            showKeyField = false
            Haptics.shared.success()
        case .failure(let error):
            // Keep the key saved so a network blip doesn't force a re-paste —
            // the badge tells them it isn't working.
            verification = .failed(error.errorDescription ?? "Verification failed.")
            Haptics.shared.tick()
        }
    }

    // MARK: - Building blocks

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.bold))
                .kerning(1)
                .foregroundStyle(Theme.textDim)
            content()
        }
    }

    private func choiceRow(
        title: String,
        blurb: String,
        icon: String?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            Haptics.shared.tick()
        } label: {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .font(.subheadline)
                        .foregroundStyle(isSelected ? .black : Theme.emerald)
                        .frame(width: 24)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(blurb)
                        .font(.caption2)
                        .foregroundStyle(isSelected ? .black.opacity(0.7) : Theme.textDim)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.black)
                }
            }
            .padding(12)
            .foregroundStyle(isSelected ? .black : .white)
            .background(
                isSelected ? AnyShapeStyle(Theme.emerald) : AnyShapeStyle(Theme.surfaceRaised),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
