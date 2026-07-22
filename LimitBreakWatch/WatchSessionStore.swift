import Foundation
import Observation
import WatchConnectivity
import WatchKit

/// Watch side of the link: mirrors the phone's session state and sends
/// commands. The phone is the single source of truth; every command's reply
/// (and every application-context push) refreshes the mirror.
@Observable
final class WatchSessionStore: NSObject, WCSessionDelegate {
    var state: WatchStateSnapshot = .idle
    var routines: [WatchRoutineSummary] = []
    var isBusy = false
    var isReachable = false
    var hasReceivedState = false

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - Commands

    func send(_ kind: WatchCommandKind, routineID: UUID? = nil, haptic: WKHapticType? = .click) {
        guard !isBusy else { return }
        isBusy = true
        if let haptic { WKInterfaceDevice.current().play(haptic) }

        let command = WatchCommand(kind: kind, routineID: routineID)
        var message: [String: Any] = [:]
        if let data = WatchLink.encode(command) {
            message[WatchLink.commandKey] = data
        }

        WCSession.default.sendMessage(message) { [weak self] reply in
            Task { @MainActor in
                self?.apply(reply: reply)
                self?.isBusy = false
            }
        } errorHandler: { [weak self] _ in
            Task { @MainActor in
                self?.isBusy = false
            }
        }
    }

    @MainActor
    private func apply(reply: [String: Any]) {
        if let snapshot = WatchLink.decode(WatchStateSnapshot.self, from: reply[WatchLink.stateKey] as? Data) {
            state = snapshot
            hasReceivedState = true
        }
        if let summaries = WatchLink.decode([WatchRoutineSummary].self, from: reply[WatchLink.routinesKey] as? Data) {
            routines = summaries
        }
    }

    // MARK: - Derived

    var currentExercise: WatchExerciseSnapshot? {
        guard let id = state.currentExerciseID else { return nil }
        return state.exercises.first { $0.id == id }
    }

    var totalDone: Int {
        state.exercises.filter { !$0.isSkipped }.reduce(0) { $0 + min($1.done, $1.target) }
    }

    var totalTarget: Int {
        state.exercises.filter { !$0.isSkipped }.reduce(0) { $0 + $1.target }
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated else { return }
        Task { @MainActor in
            self.isReachable = session.isReachable
            // Whatever the phone last pushed is the starting picture.
            self.consume(context: session.receivedApplicationContext)
            self.send(.requestState, haptic: nil)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            if session.isReachable { self.send(.requestState, haptic: nil) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            self.consume(context: applicationContext)
        }
    }

    @MainActor
    private func consume(context: [String: Any]) {
        if let snapshot = WatchLink.decode(WatchStateSnapshot.self, from: context[WatchLink.stateKey] as? Data) {
            state = snapshot
            hasReceivedState = true
        }
        if let summaries = WatchLink.decode([WatchRoutineSummary].self, from: context[WatchLink.routinesKey] as? Data) {
            routines = summaries
        }
    }
}
