import SwiftUI

/// The coach conversation.
///
/// Three things share the screen and the priority between them is deliberate:
/// the transcript, a staged change waiting on approval, and the composer. When
/// a change is pending it pins above the composer and the composer goes quiet —
/// the lifter has exactly one decision to make, and burying it above a scroll
/// of chat would be the easiest way to make them miss it.
struct CoachChatView: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable var agent: CoachAgent

    @State private var draft = ""
    @State private var showingHistory = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if agent.isEmpty {
                            emptyState
                        } else {
                            ForEach(agent.messages) { message in
                                if message.isVisible {
                                    CoachMessageRow(
                                        message: message,
                                        // Chips are a "what next" prompt, so they
                                        // belong only under the freshest reply, and
                                        // only while it's the lifter's turn to act —
                                        // not mid-think or behind an approval card.
                                        showsSuggestions: message.id == latestReplyID
                                            && !agent.isWorking
                                            && agent.pendingApproval == nil,
                                        onSuggestion: send
                                    )
                                    .id(message.id)
                                }
                            }
                        }
                        if agent.isWorking { workingRow }
                        if let failure = agent.failure { failureRow(failure) }
                        // Anchors the auto-scroll: scrolling to the last bubble
                        // stops short whenever the approval card is showing.
                        Color.clear.frame(height: 1).id(Self.bottomAnchor)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: agent.messages.count) { scrollToBottom(proxy) }
                .onChange(of: agent.isWorking) { scrollToBottom(proxy) }
                .onChange(of: agent.pendingApproval?.id) { scrollToBottom(proxy) }
            }
            .obsidianBackground()
            .navigationTitle("Coach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Recent chats", systemImage: "clock.arrow.circlepath") {
                        Haptics.shared.tick()
                        showingHistory = true
                    }
                    .labelStyle(.iconOnly)
                    .disabled(agent.history.isEmpty)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("New chat", systemImage: "square.and.pencil") {
                        agent.startNewChat()
                        draft = ""
                        Haptics.shared.tick()
                    }
                    .labelStyle(.iconOnly)
                    .disabled(agent.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showingHistory) {
                CoachHistoryView(agent: agent)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if let approval = agent.pendingApproval {
                        CoachApprovalCard(
                            change: approval.change,
                            onApply: {
                                Haptics.shared.success()
                                agent.approvePendingChange()
                            },
                            onDiscard: {
                                Haptics.shared.tick()
                                agent.declinePendingChange()
                            }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    composer
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .background(.ultraThinMaterial)
                .animation(.spring(duration: 0.3), value: agent.pendingApproval?.id)
            }
        }
        // The logging screen takes over once a workout starts; leaving the chat
        // in front of it would hide the thing the lifter just asked for.
        .onChange(of: agent.didStartWorkout) { _, started in
            guard started else { return }
            agent.acknowledgeWorkoutStart()
            dismiss()
        }
        .onDisappear {
            // A tool call suspended on the approval gate would otherwise wait
            // forever behind a dismissed sheet.
            agent.cancelPendingApproval()
        }
    }

    private static let bottomAnchor = "coach.bottom"

    /// The most recent turn that carries follow-up chips. Only this turn shows
    /// them, so a scroll back through the history isn't littered with stale
    /// "what next" prompts from turns the lifter already moved past.
    private var latestReplyID: CoachMessage.ID? {
        agent.messages.last { !$0.suggestions.isEmpty }?.id
    }

    /// Sends a tapped suggestion as the lifter's next message, verbatim — the
    /// chips are written in their voice for exactly this.
    private func send(_ text: String) {
        Haptics.shared.tick()
        Task { await agent.send(text) }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask your coach…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .focused($composerFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.stroke, lineWidth: 1))
                .disabled(isComposerDisabled)

            Button {
                submit()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(canSend ? .black : Theme.textDim)
                    .frame(width: 38, height: 38)
                    .background(
                        canSend ? AnyShapeStyle(Theme.emerald) : AnyShapeStyle(Theme.surfaceRaised),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.top, 8)
    }

    private var isComposerDisabled: Bool {
        agent.isWorking || agent.pendingApproval != nil
    }

    private var canSend: Bool {
        !isComposerDisabled && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        let text = draft
        draft = ""
        Haptics.shared.tick()
        Task { await agent.send(text) }
    }

    // MARK: - States

    private var workingRow: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(Theme.emerald)
            Text(agent.activity ?? "Thinking")
                .font(.footnote)
                .foregroundStyle(Theme.textDim)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func failureRow(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(Theme.coral)
            if agent.hasBackend {
                Button("Try again") {
                    Task { await agent.retry() }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.emerald)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.title)
                    .foregroundStyle(Theme.limitBreakGradient)
                Text("Ask for a workout, or tell me what to change.")
                    .font(.title3.weight(.semibold))
                Text(agent.hasBackend
                     ? "I can read your routines, history, and recovery — and build or edit them for you. Anything I change, you approve first."
                     : (CoachAgentError.noBackend.errorDescription ?? ""))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
            }
            .padding(.top, 20)

            if agent.hasBackend {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Self.prompts, id: \.self) { prompt in
                        Button {
                            Haptics.shared.tick()
                            Task { await agent.send(prompt) }
                        } label: {
                            HStack {
                                Text(prompt)
                                    .font(.subheadline)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textDim)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private static let prompts = [
        "Build me a push workout for today",
        "What haven't I trained this week?",
        "Add face pulls to my pull routine",
        "How's my bench press trending?",
    ]
}

// MARK: - Message row

/// One turn. Assistant prose sits left in glass; the lifter's own words sit
/// right in accent. Tool calls render as their own quiet rows beneath the
/// prose, so the lifter can always see what the coach actually did — an agent
/// whose actions are invisible is one you can't sanity-check.
private struct CoachMessageRow: View {
    let message: CoachMessage
    /// Whether this turn's follow-up chips should render. Only the latest reply
    /// sets this; see `CoachChatView.latestReplyID`.
    var showsSuggestions = false
    var onSuggestion: (String) -> Void = { _ in }

    var body: some View {
        switch message.role {
        case .user:
            Text(message.text)
                .font(.subheadline)
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.emerald, in: RoundedRectangle(cornerRadius: 18))
                .frame(maxWidth: .infinity, alignment: .trailing)

        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .strokeBorder(Theme.glassBorder, lineWidth: 1)
                        )
                }
                ForEach(message.toolCalls) { call in
                    HStack(spacing: 8) {
                        Image(systemName: "wrench.adjustable")
                            .font(.caption2)
                        Text(call.activityLabel)
                            .font(.caption)
                    }
                    .foregroundStyle(Theme.textDim)
                    .padding(.leading, 4)
                }
                if showsSuggestions && !message.suggestions.isEmpty {
                    suggestionChips
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The follow-up chips, stacked under the reply. Each is written in the
    /// lifter's voice and, when tapped, sends itself as their next message.
    private var suggestionChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(message.suggestions, id: \.self) { suggestion in
                Button {
                    onSuggestion(suggestion)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.up.right")
                            .font(.caption2)
                        Text(suggestion)
                            .font(.caption)
                            .multilineTextAlignment(.leading)
                    }
                    .foregroundStyle(Theme.emerald)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.surfaceRaised, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.emerald.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - Approval card

/// The gate every write passes through. It states what will change in the
/// lifter's own vocabulary — routine and movement names, sets and reps — rather
/// than the tool that produced it, because approving "Create routine
/// “Push Day A”" is a decision and approving `create_routine` is not.
private struct CoachApprovalCard: View {
    let change: CoachToolRunner.PendingChange
    let onApply: () -> Void
    let onDiscard: () -> Void

    private var tint: Color { change.isDestructive ? Theme.crimson : Theme.emerald }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: change.isDestructive ? "trash.fill" : "sparkles")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(tint)
                Text(change.title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !change.detail.isEmpty {
                // A generated week can run to a dozen lines. Scrolling inside
                // the card keeps Apply and Discard on screen no matter how long
                // the change is — the decision must never be below the fold.
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(change.detail.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(Theme.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 190)
                .scrollBounceBehavior(.basedOnSize)
            }

            HStack(spacing: 10) {
                Button(action: onDiscard) {
                    Text("Discard")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .glassControl()

                Button(action: onApply) {
                    Text(change.isDestructive ? "Delete" : "Apply")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black)
                .glassCTA(tint: tint)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(tint.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }
}

// MARK: - History

/// The recent conversations, newest first. Tapping one resumes it; swiping
/// deletes it. The list is capped to the last ten by the agent, so this never
/// grows into something the lifter has to scroll far through.
private struct CoachHistoryView: View {
    @Bindable var agent: CoachAgent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if agent.history.isEmpty {
                    ContentUnavailableView(
                        "No past chats",
                        systemImage: "clock",
                        description: Text("Conversations with your coach show up here.")
                    )
                } else {
                    List {
                        ForEach(agent.history) { conversation in
                            Button {
                                Haptics.shared.tick()
                                agent.openConversation(conversation)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(conversation.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text(conversation.updatedAt, format: .relative(presentation: .named))
                                        .font(.caption)
                                        .foregroundStyle(Theme.textDim)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Theme.surfaceRaised)
                        }
                        .onDelete { offsets in
                            Haptics.shared.tick()
                            for index in offsets {
                                agent.deleteConversation(agent.history[index].id)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .obsidianBackground()
            .navigationTitle("Recent chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }
}
