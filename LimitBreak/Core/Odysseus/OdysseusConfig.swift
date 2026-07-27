import Foundation

/// Where the Odysseus server lives and which model to talk to.
///
/// The token is the one piece that never lands here — it's a long-lived
/// credential, so it lives in the Keychain (`KeychainStore.odysseusToken`).
/// Everything in this file is non-secret configuration and sits in
/// `UserDefaults`.
///
/// No chat session is persisted: each workout generation creates a fresh
/// server session and discards it (see `OdysseusWorkoutAI`). The coach's
/// awareness of past training comes from the recent-session history in the
/// prompt, so there is no server-side conversation state to hold onto.
enum OdysseusConfig {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let baseURL = "odysseus.baseURL"
        static let endpointID = "odysseus.endpointID"
        static let endpointName = "odysseus.endpointName"
        static let model = "odysseus.model"
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

    /// The configured model as a human-readable name rather than the full
    /// server-side file path the weights are served from.
    static var modelDisplayName: String? {
        model.map(displayName(forModel:))
    }

    /// Strips the directory path and any weight-file extension from a model
    /// identifier so it reads as a name, not the file it's served from
    /// (e.g. `/…/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf` becomes `Qwen3.6-35B-A3B-UD-Q4_K_M`).
    /// A model id with no recognized extension is left untouched, since these
    /// ids often carry dots of their own.
    nonisolated static func displayName(forModel model: String) -> String {
        let file = model.split(separator: "/").last.map(String.init) ?? model
        let weightExtensions: Set<String> = ["gguf", "bin", "safetensors", "ggml", "pt", "onnx"]
        if let dot = file.lastIndex(of: "."),
           weightExtensions.contains(file[file.index(after: dot)...].lowercased()) {
            return String(file[..<dot])
        }
        return file
    }

    /// Records a picked endpoint and model.
    static func select(endpointID: String, endpointName: String?, model: String) {
        self.endpointID = endpointID
        self.endpointName = endpointName
        self.model = model
    }

    // MARK: - Readiness

    /// A URL, a token, and a model are all required before a request can be
    /// attempted.
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
        [Key.baseURL, Key.endpointID, Key.endpointName, Key.model]
            .forEach(defaults.removeObject(forKey:))
        KeychainStore.deleteOdysseusToken()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
