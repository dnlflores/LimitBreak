import SwiftUI

/// Connects LimitBreak to Apple Health and shows today's activity pulled
/// from HealthKit once connected.
struct HealthKitSheet: View {
    @Environment(\.dismiss) private var dismiss

    private var health: HealthKitManager { HealthKitManager.shared }

    var body: some View {
        @Bindable var health = HealthKitManager.shared

        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "heart.text.square.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Theme.crimson)
                        .padding(.top, 12)

                    if health.isConnected {
                        connectedContent
                    } else {
                        disconnectedContent
                    }

                    if let error = health.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Theme.crimson)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
            }
            .obsidianBackground()
            .navigationTitle("Apple Health")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await HealthKitManager.shared.refreshTodayStats()
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Disconnected

    private var disconnectedContent: some View {
        VStack(spacing: 14) {
            Text("Connect to Apple Health")
                .font(.title3.weight(.bold))

            Text("LimitBreak will save your strength sessions and walks (with routes) to Health, and show your daily steps and active energy here.")
                .font(.subheadline)
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)

            Button {
                Task { await HealthKitManager.shared.connect() }
            } label: {
                Text("CONNECT")
                    .font(.headline)
                    .kerning(1.5)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(.white)
                    .glassCTA(tint: Theme.crimson.opacity(0.85))
            }
            .buttonStyle(.plain)
            .disabled(!health.isAvailable)

            if !health.isAvailable {
                Text("Health data isn't available on this device.")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }
        }
    }

    // MARK: - Connected

    @ViewBuilder
    private var connectedContent: some View {
        @Bindable var health = HealthKitManager.shared

        Label("Connected", systemImage: "checkmark.seal.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.emerald)

        HStack(spacing: 12) {
            todayTile(
                value: health.todaySteps.map { Int($0).formatted() } ?? "—",
                label: "Steps Today",
                icon: "shoeprints.fill",
                color: Theme.emerald
            )
            todayTile(
                value: health.todayActiveEnergy.map { "\(Int($0))" } ?? "—",
                label: "Active kcal",
                icon: "flame.fill",
                color: Theme.gold
            )
        }

        Toggle(isOn: $health.autoSync) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Auto-sync workouts")
                    .font(.subheadline.weight(.semibold))
                Text("Save finished sessions and walks to Health automatically.")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }
        }
        .tint(Theme.emerald)
        .cardStyle()

        Button {
            Task { await HealthKitManager.shared.refreshTodayStats() }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(Theme.emerald)
    }

    private func todayTile(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .statNumberStyle()
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity)
        .cardStyle()
    }
}
