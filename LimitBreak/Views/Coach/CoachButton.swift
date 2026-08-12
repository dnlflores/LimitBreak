import SwiftUI
import SwiftData

/// The floating coach button and the conversation behind it.
///
/// Applied once to the whole tab view rather than per-screen, so the coach is
/// reachable from anywhere without every tab having to opt in. The agent is
/// owned here and outlives the sheet, so dismissing the chat pauses the
/// conversation instead of discarding it.
struct CoachOverlay: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    @Environment(WorkoutManager.self) private var workout

    /// The screen the lifter is looking at, passed to the coach as context.
    let screen: String
    /// Extra bottom padding so the button clears whatever bar the current
    /// layout puts at the bottom.
    var bottomInset: CGFloat

    @State private var agent: CoachAgent?
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                Button {
                    Haptics.shared.tick()
                    agent?.currentScreen = screen
                    isPresented = true
                } label: {
                    Image(systemName: "bubble.left.and.text.bubble.right.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.emerald)
                        .glassCircle(diameter: 52)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 16)
                .padding(.bottom, bottomInset)
                .accessibilityLabel("Ask your coach")
                // Nothing competes with a Limit Break.
                .opacity(workout.limitBreakEvent == nil ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: workout.limitBreakEvent == nil)
            }
            .task {
                // Built once the environment is available, and kept for the
                // lifetime of the app so the transcript survives dismissal.
                if agent == nil {
                    agent = CoachAgent(context: modelContext, workout: workout)
                }
            }
            .sheet(isPresented: $isPresented) {
                if let agent {
                    CoachChatView(agent: agent)
                }
            }
    }
}

extension View {
    /// Floats the coach button above this view.
    ///
    /// - Parameters:
    ///   - screen: What the lifter is looking at, told to the coach once per
    ///     conversation so a request like "add a set to this" has a referent.
    ///   - bottomInset: Clearance for the bottom bar. The phone's tab bar sits
    ///     at the bottom; on iPad it floats at the top, so the button can sit
    ///     lower.
    func coachButton(screen: String, bottomInset: CGFloat) -> some View {
        modifier(CoachOverlay(screen: screen, bottomInset: bottomInset))
    }
}
