import Foundation

/// One saved conversation with the coach.
///
/// The transcript is stored whole — tool traffic and all — because reopening a
/// chat means *continuing* it, and every backend rebuilds its own session from
/// the transcript alone (see `CoachBackend`). A lighter summary would read fine
/// but couldn't be resumed.
struct CoachConversation: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    /// A short label for the history list, taken from the opening question.
    var title: String
    /// When the conversation was last touched — the sort key and what the row
    /// shows. Newest first, and the oldest falls off once there are more than
    /// `CoachHistoryStore.limit`.
    var updatedAt: Date
    var messages: [CoachMessage]

    /// Derives a one-line title from the first thing the lifter actually said.
    /// Plumbing and tool turns are skipped; a chat with nothing said yet is
    /// "New chat" rather than blank.
    static func title(from messages: [CoachMessage]) -> String {
        let opening = messages.first { $0.role == .user && !$0.isPlumbing && !$0.text.isEmpty }
        guard let text = opening?.text else { return "New chat" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= 48 ? trimmed : String(trimmed.prefix(47)) + "…"
    }
}

/// Reads and writes the recent-chats file: the last `limit` conversations, as
/// plain JSON in Application Support.
///
/// An actor so the file is never read and written from two turns at once. It
/// only persists — the in-memory list of record lives on `CoachAgent`, which
/// is what the UI observes; the store is the durable copy behind it.
actor CoachHistoryStore {
    static let shared = CoachHistoryStore()

    /// How many conversations are kept. Older ones are dropped on save.
    static let limit = 10

    private var fileURL: URL? {
        guard let directory = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return directory.appendingPathComponent("coach-history.json")
    }

    /// The saved conversations, newest first and capped. Any read error — no
    /// file yet, a format from an older build — yields an empty history rather
    /// than a failure the lifter would see.
    func load() -> [CoachConversation] {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([CoachConversation].self, from: data)
        else { return [] }
        return capped(decoded)
    }

    /// Writes the conversations, capped and newest-first. Atomic so a crash
    /// mid-write can't leave a half-written file that fails to load next launch.
    func save(_ conversations: [CoachConversation]) {
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(capped(conversations))
        else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private func capped(_ conversations: [CoachConversation]) -> [CoachConversation] {
        Array(conversations.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.limit))
    }
}
