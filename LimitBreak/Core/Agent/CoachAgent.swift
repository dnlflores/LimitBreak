import Foundation
import FoundationModels
import SwiftData

/// Why a conversation couldn't proceed, in words the lifter can act on.
enum CoachAgentError: LocalizedError {
    case noBackend
    case onDeviceUnavailable
    case exhausted

    var errorDescription: String? {
        switch self {
        case .noBackend:
            return "No coach is set up. Turn on AI coaching in Settings, or wait for "
                + "Apple Intelligence to finish setting up on this device."
        case .onDeviceUnavailable:
            return "The on-device model isn't available right now."
        case .exhausted:
            return "The coach took too many steps without finishing. Try asking for one thing at a time."
        }
    }
}

/// Drives the conversation: picks a backend, runs the tool loop, and holds the
/// approval gate open while the lifter decides on a change.
///
/// The loop is the whole feature. A backend proposes tool calls; every call is
/// executed by `CoachToolRunner`; results go back as the next turn; repeat
/// until the coach answers in prose. Reads run straight through — a mutation
/// suspends the loop on a continuation until the lifter taps Apply or Discard,
/// which is what makes "confirm writes" a property of the agent rather than a
/// convention each backend has to honour separately.
@MainActor
@Observable
final class CoachAgent {

    /// A staged change waiting on the lifter, paired with the continuation that
    /// resumes the tool call once they decide.
    struct PendingApproval: Identifiable {
        var id: UUID { change.id }
        let change: CoachToolRunner.PendingChange
        fileprivate let decide: @Sendable (Bool) -> Void
    }

    /// Everything said so far, including the tool traffic the UI hides. This is
    /// the conversation's source of truth — backends may cache a server-side
    /// session, but all of them can rebuild from here.
    private(set) var messages: [CoachMessage] = []
    /// Whether a turn is in flight.
    private(set) var isWorking = false
    /// What the coach is doing right now, e.g. "Searching the movement library".
    private(set) var activity: String?
    /// The change awaiting approval, if any.
    private(set) var pendingApproval: PendingApproval?
    /// The last failure, shown as a retryable banner rather than a chat bubble
    /// so it never becomes part of what the model reads back.
    private(set) var failure: String?
    /// Set when an approved change started a live workout, so the chat can get
    /// out of the way and let the logging screen take over.
    private(set) var didStartWorkout = false
    /// Which tier answered, for the footer under the conversation.
    private(set) var backendName: String?
    /// The screen the lifter opened the chat from. Told to the coach once, so
    /// "add another set to this" has something to resolve against.
    var currentScreen: String?

    /// The recent conversations, newest first — the source the history list
    /// renders. Kept in sync with the on-disk store: loaded once at startup,
    /// rewritten whenever the current chat advances or one is deleted.
    private(set) var history: [CoachConversation] = []
    /// Which conversation the live transcript belongs to. A fresh id until the
    /// first message lands, so a brand-new chat and a resumed one persist under
    /// the right entry rather than colliding.
    private var currentID = UUID()

    /// How many tool rounds one message may take before the agent gives up.
    /// High enough for read → decide → write → confirm, low enough that a model
    /// stuck in a loop can't run up a bill or drain a battery.
    private let maxRounds = 8

    private let context: ModelContext
    private let workout: WorkoutManager
    @ObservationIgnored private var runner: CoachToolRunner!

    // Backends are created once and reused so their server-side sessions and
    // on-device transcripts survive across turns. None of them is observable
    // state — the UI reads the transcript, never the tier's internals.
    @ObservationIgnored private lazy var claude = ClaudeCoachBackend()
    @ObservationIgnored private lazy var odysseus = OdysseusCoachBackend()
    @ObservationIgnored private lazy var onDevice = OnDeviceCoachBackend()

    init(context: ModelContext, workout: WorkoutManager) {
        self.context = context
        self.workout = workout
        self.runner = CoachToolRunner(context: context, workout: workout) { [weak self] change in
            guard let self else { return false }
            return await self.requestApproval(for: change)
        }
        // Pull the recent chats off disk once the object exists. The list is
        // small and the read is off the main actor, so the UI shows an empty
        // history for the instant before it lands rather than blocking on it.
        Task { @MainActor [weak self] in
            let loaded = await CoachHistoryStore.shared.load()
            self?.history = loaded
        }
    }

    var isEmpty: Bool { messages.allSatisfy { !$0.isVisible } }

    /// Whether any tier can answer at all — drives the empty state's copy.
    var hasBackend: Bool { (try? selectBackend()) != nil }

    // MARK: - Conversation

    /// Sends a message and runs the loop until the coach answers in prose.
    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isWorking else { return }

        // The situation block opens the conversation as a user turn rather than
        // living in the system prompt: it carries today's date and the live
        // session, and volatile bytes in the cached prefix would cost a full
        // re-read of every earlier turn. Two consecutive user turns are fine —
        // the API merges them — so it needs no synthetic assistant reply to
        // separate it from the lifter's actual first message.
        if messages.isEmpty {
            messages.append(CoachMessage(
                role: .user,
                text: CoachPrompt.situation(
                    profile: TrainingProfile.current(in: context),
                    activeSessionName: workout.activeSession?.name,
                    routineCount: routineCount(),
                    screen: currentScreen
                ),
                isPlumbing: true
            ))
        }

        messages.append(CoachMessage(role: .user, text: trimmed))
        await run()
    }

    /// Re-runs the loop after a failure, without the lifter retyping.
    func retry() async {
        guard !isWorking, !messages.isEmpty else { return }
        await run()
    }

    // MARK: - History

    /// Archives the current chat and starts an empty one. The old conversation
    /// stays in history — "new chat" sets it aside rather than discarding it.
    func startNewChat() {
        persistCurrent()
        clearLiveState()
        messages.removeAll()
        currentID = UUID()
    }

    /// Reopens a saved conversation to keep talking. The current chat is
    /// archived first, and the backends are rebuilt so they replay the loaded
    /// transcript from scratch — the transcript is the source of truth, so a
    /// chat started on one tier resumes cleanly on whichever tier is active now.
    func openConversation(_ conversation: CoachConversation) {
        guard conversation.id != currentID else { return }
        persistCurrent()
        clearLiveState()
        messages = conversation.messages
        currentID = conversation.id
    }

    /// Forgets a saved conversation. Deleting the one that's open clears the
    /// screen and starts fresh, so the lifter is never left looking at a chat
    /// that no longer exists.
    func deleteConversation(_ id: UUID) {
        history.removeAll { $0.id == id }
        saveHistory()
        if id == currentID {
            clearLiveState()
            messages.removeAll()
            currentID = UUID()
        }
    }

    /// Folds the live transcript into `history` under its id, newest first and
    /// capped, then writes it out. A chat with nothing said yet isn't saved —
    /// there's nothing to reopen, and it would clutter the list with blanks.
    private func persistCurrent() {
        guard !isEmpty else { return }
        let conversation = CoachConversation(
            id: currentID,
            title: CoachConversation.title(from: messages),
            updatedAt: Date(),
            messages: messages
        )
        if let index = history.firstIndex(where: { $0.id == currentID }) {
            history[index] = conversation
        } else {
            history.insert(conversation, at: 0)
        }
        history.sort { $0.updatedAt > $1.updatedAt }
        if history.count > CoachHistoryStore.limit {
            history = Array(history.prefix(CoachHistoryStore.limit))
        }
        saveHistory()
    }

    private func saveHistory() {
        let snapshot = history
        Task { await CoachHistoryStore.shared.save(snapshot) }
    }

    /// Drops every transient bit of the live conversation — the approval gate,
    /// banners, activity, and each backend's cached session — without touching
    /// the transcript or the history. The callers set those.
    private func clearLiveState() {
        cancelPendingApproval()
        failure = nil
        activity = nil
        didStartWorkout = false
        backendName = nil
        claude = ClaudeCoachBackend()
        odysseus = OdysseusCoachBackend()
        onDevice = OnDeviceCoachBackend()
    }

    // MARK: - The loop

    private func run() async {
        failure = nil
        isWorking = true
        defer {
            isWorking = false
            activity = nil
            // Save whatever the turn produced — success or failure — so the
            // history survives a force-quit and reopens where it left off.
            persistCurrent()
        }

        let backend: CoachBackend
        do {
            backend = try selectBackend()
        } catch {
            failure = error.localizedDescription
            return
        }
        backendName = backend.displayName

        // Every distinct call already run this message, keyed by name and
        // arguments. A smaller model — the on-device tier especially — will
        // otherwise re-issue the same read every round, never getting to an
        // answer, and burn the whole round budget on one repeated lookup.
        var executedCalls: Set<String> = []
        // Whether the previous round did nothing but repeat itself. One such
        // round earns a nudge; two in a row is a loop, not progress.
        var stalled = false

        for _ in 0..<maxRounds {
            let turn: CoachTurn
            do {
                activity = "Thinking"
                turn = try await backend.nextTurn(
                    system: CoachPrompt.instructions,
                    transcript: messages,
                    tools: CoachTool.catalog
                )
            } catch {
                failure = Self.message(for: error)
                return
            }

            guard !turn.isEmpty else {
                failure = "The coach didn't answer. Try asking again."
                return
            }

            messages.append(CoachMessage(
                role: .assistant,
                text: turn.reply?.message ?? "",
                suggestions: turn.reply?.suggestions ?? [],
                toolCalls: turn.toolCalls,
                rawContent: turn.rawContent
            ))

            // A spoken reply with no calls means the coach is done for this
            // message. Tool calls mean another round; the reply, if any, was
            // just the model thinking out loud on the way there.
            guard !turn.toolCalls.isEmpty else { return }

            // Every call in a turn is answered, in one user turn. Splitting
            // results across messages is accepted by the API but teaches the
            // model to stop batching, which costs a round trip per call.
            var results: [CoachToolResult] = []
            var ranSomethingNew = false
            for call in turn.toolCalls {
                let signature = call.name + "|" + JSONValue.object(call.arguments).jsonText
                // A call this message already made returns the same thing it did
                // the first time. Don't run it again — hand back a correction
                // that tells the model to answer from what it already has.
                guard executedCalls.insert(signature).inserted else {
                    results.append(CoachToolResult(
                        callID: call.id,
                        text: "You already called \(call.name) and its result is above. "
                            + "Don't call it again — answer the lifter now with what you have.",
                        isError: true
                    ))
                    continue
                }
                ranSomethingNew = true
                activity = call.activityLabel
                // A declined change is a successful call that changed nothing,
                // so the result alone can't say whether a session actually
                // started. Compare the live session across the call instead —
                // that's true only when one really began.
                let sessionBefore = workout.activeSession?.id
                let result = await runner.run(call)
                if let started = workout.activeSession?.id, started != sessionBefore {
                    didStartWorkout = true
                }
                results.append(result)
            }
            activity = "Thinking"
            messages.append(CoachMessage(role: .user, toolResults: results))

            // A round that only repeated earlier calls made no progress. Give
            // the model one round to take the correction and answer; if the
            // next round stalls too, it's looping — stop rather than spin out
            // the remaining budget on the same call.
            if ranSomethingNew {
                stalled = false
            } else if stalled {
                failure = CoachAgentError.exhausted.localizedDescription
                return
            } else {
                stalled = true
            }
        }

        failure = CoachAgentError.exhausted.localizedDescription
    }

    // MARK: - Approval gate

    /// Suspends the calling tool until the lifter decides. Returning `false`
    /// means the change is simply never applied — there is nothing to undo.
    private func requestApproval(for change: CoachToolRunner.PendingChange) async -> Bool {
        await withCheckedContinuation { continuation in
            // `resume` must run exactly once. Every path out of `pendingApproval`
            // goes through `resolve`, which clears it first.
            let box = ContinuationBox(continuation)
            pendingApproval = PendingApproval(change: change) { approved in
                box.resume(approved)
            }
        }
    }

    func approvePendingChange() { resolve(true) }
    func declinePendingChange() { resolve(false) }

    /// Clears the workout-started signal once the chat has stepped aside. It's
    /// a one-shot event, not a state: left latched, a *second* workout started
    /// later in the same conversation would change nothing and the chat would
    /// sit on top of the logging screen.
    func acknowledgeWorkoutStart() { didStartWorkout = false }

    /// Declines anything still waiting — called when the chat goes away, so a
    /// suspended tool call can never strand the loop.
    func cancelPendingApproval() { resolve(false) }

    private func resolve(_ approved: Bool) {
        guard let approval = pendingApproval else { return }
        pendingApproval = nil
        approval.decide(approved)
    }

    // MARK: - Backend selection

    /// Picks the tier the lifter configured, honouring the same network opt-in
    /// the workout generator uses: without `cloudAIEnabled` nothing leaves the
    /// device, and the on-device model answers or nothing does.
    private func selectBackend() throws -> CoachBackend {
        let profile = TrainingProfile.current(in: context)
        if profile.cloudAIEnabled {
            switch profile.aiProvider {
            case .claude where ClaudeCoachBackend.isConfigured:
                return claude
            case .odysseus where OdysseusCoachBackend.isConfigured:
                return odysseus
            default:
                break
            }
        }
        if OnDeviceCoachBackend.isConfigured { return onDevice }
        throw CoachAgentError.noBackend
    }

    private func routineCount() -> Int {
        let routines = (try? context.fetch(FetchDescriptor<Routine>())) ?? []
        return routines.filter { !$0.isPlanDay }.count
    }

    /// Each client writes better copy for its own failures than
    /// `localizedDescription` does — particularly for a rejected credential,
    /// which has to read as "your key is wrong", not "the request failed".
    private static func message(for error: Error) -> String {
        if let error = error as? ClaudeClient.ClientError {
            return error.errorDescription ?? error.localizedDescription
        }
        if let error = error as? OdysseusClient.OdysseusError {
            return error.errorDescription ?? error.localizedDescription
        }
        if let error = error as? CoachAgentError {
            return error.errorDescription ?? error.localizedDescription
        }
        // FoundationModels reports most failures as an opaque `GenerationError`
        // whose `localizedDescription` is "(null)" wrapped in domain noise —
        // useless to the lifter and alarming to read. Its failures share one
        // remedy, so they share one message.
        if error is LanguageModelSession.GenerationError {
            return "The on-device coach couldn't answer. It needs Apple Intelligence "
                + "switched on and finished setting up — and it doesn't run in the "
                + "Simulator. Turning on AI coaching in Settings uses Claude or your "
                + "own server instead."
        }
        return error.localizedDescription
    }
}

/// Guarantees a continuation resumes exactly once, however many times the UI
/// manages to call back. Resuming twice traps at runtime.
private final class ContinuationBox: @unchecked Sendable {
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        guard let stored = continuation else { return }
        continuation = nil
        stored.resume(returning: value)
    }
}
