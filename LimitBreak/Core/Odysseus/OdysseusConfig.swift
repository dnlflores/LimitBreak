import Foundation

/// Where the Odysseus server lives and which model to talk to.
///
/// The token is the one piece that never lands here — it's a long-lived
/// credential, so it lives in the Keychain (`KeychainStore.odysseusToken`).
/// Everything in this file is non-secret configuration and sits in
/// `UserDefaults`.
///
/// `sessionID` is the reason this type persists at all. The server holds
/// conversation history against a session, so reusing one id across launches
/// gives the coach continuity between generations. It's only cleared when the
/// server says the session is gone, or when the model selection changes out
/// from under it.
enum OdysseusConfig {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let baseURL = "odysseus.baseURL"
        static let endpointID = "odysseus.endpointID"
        static let endpointName = "odysseus.endpointName"
        static let model = "odysseus.model"
        static let sessionID = "odysseus.sessionID"
    }

    // MARK: - Connection

    static var baseURL: String {
        get { defaults.string(forKey: Key.baseURL) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.baseURL) }
    }

    // MARK: - Model selection

    static var endpointID: String? {
        get { defaults.string(forKey: Key.endpointID)?.nilIfEmpty }
        set { defaults.set(newValue, forKey: Key.endpointID) }
    }

    /// Display name for the chosen endpoint, so Settings can show it without a
    /// round trip on every appearance.
    static var endpointName: String? {
        get { defaults.string(forKey: Key.endpointName)?.nilIfEmpty }
        set { defaults.set(newValue, forKey: Key.endpointName) }
    }

    static var model: String? {
        get { defaults.string(forKey: Key.model)?.nilIfEmpty }
        set { defaults.set(newValue, forKey: Key.model) }
    }

    /// Records a picked endpoint and model. Changing either invalidates the
    /// session: its history belongs to the old model, and the server binds a
    /// session to the model it was created with.
    static func select(endpointID: String, endpointName: String?, model: String) {
        if self.endpointID != endpointID || self.model != model {
            clearSession()
        }
        self.endpointID = endpointID
        self.endpointName = endpointName
        self.model = model
    }

    // MARK: - Session

    static var sessionID: String? {
        get { defaults.string(forKey: Key.sessionID)?.nilIfEmpty }
        set { defaults.set(newValue, forKey: Key.sessionID) }
    }

    static func clearSession() {
        defaults.removeObject(forKey: Key.sessionID)
    }

    // MARK: - Readiness

    /// A URL, a token, and a model are all required before a request can be
    /// attempted. The session id is not — it's created on demand.
    static var isConfigured: Bool {
        !baseURL.isEmpty
            && KeychainStore.hasOdysseusToken
            && endpointID != nil
            && model != nil
    }

    /// URL and token present, but no model picked yet — the state the first-run
    /// picker exists to resolve.
    static var needsModelSelection: Bool {
        !baseURL.isEmpty && KeychainStore.hasOdysseusToken && (endpointID == nil || model == nil)
    }

    /// Forgets everything, including the token. Used by "Disconnect".
    static func reset() {
        [Key.baseURL, Key.endpointID, Key.endpointName, Key.model, Key.sessionID]
            .forEach(defaults.removeObject(forKey:))
        KeychainStore.deleteOdysseusToken()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
