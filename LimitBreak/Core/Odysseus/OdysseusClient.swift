import Foundation

/// Client for a self-hosted Odysseus server running a local LLM.
///
/// The server is reachable over Tailscale and presents a real Let's Encrypt
/// certificate, so this needs no App Transport Security exception — do not add
/// one. If a request fails to connect, the tailnet is down, not TLS.
///
/// Two things about this API are easy to get wrong and expensive to debug:
///
/// 1. **Encoding differs per route.** `POST /api/session` is form-encoded;
///    `POST /api/chat` is JSON. That is the server's actual contract, not an
///    oversight here.
/// 2. **`/api/chat` blocks for the whole generation.** It is not streaming, and
///    a local model can think for minutes without sending a byte. URLSession's
///    60s default is an inactivity timer, so it fires mid-generation. Hence
///    `requestTimeout` below, applied on both the configuration and every
///    request (a `URLRequest` carries its own 60s default otherwise).
///
/// `/api/chat_stream` is deliberately unused: it is form-encoded and escalates a
/// turn into agent mode when the message matches a tool-intent pattern, which
/// would hand the model tool access this app doesn't want. `/api/chat` is
/// deterministic prompt-in, response-out.
enum OdysseusClient {

    // MARK: - Configuration

    /// Long enough for a local model to finish a full plan. The spec floor is
    /// 180s; the extra headroom costs nothing when generation is quick.
    static let requestTimeout: TimeInterval = 240

    /// Ping and the model list return immediately, so they fail fast instead of
    /// hanging for four minutes when the tailnet is down.
    static let quickTimeout: TimeInterval = 20

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout * 2
        return URLSession(configuration: config)
    }()

    // MARK: - Responses

    struct Ping: Decodable {
        let ok: Bool
        let name: String?
        let version: String?
        let auth: String?

        /// What the Settings screen shows after a successful test.
        var summary: String {
            let server = name ?? "server"
            guard let version else { return "Connected to \(server)." }
            return "Connected to \(server) \(version)."
        }
    }

    struct ModelList: Decodable {
        let endpoints: [Endpoint]
    }

    /// One model endpoint this token is allowed to use.
    struct Endpoint: Decodable, Identifiable, Hashable {
        let endpointId: String
        let name: String?
        /// Returned by the server for display only. Never send it back: token
        /// callers that pass a raw `endpoint_url` are rejected with 403 by
        /// design. Always identify an endpoint by `endpointId`.
        let endpointUrl: String?
        let models: [String]
        let supportsTools: Bool?

        var id: String { endpointId }
        var displayName: String { name ?? endpointId }
    }

    struct Session: Decodable {
        let id: String
        let name: String?
        let model: String?
        let rag: Bool?
        let archived: Bool?
    }

    struct ChatReply: Decodable {
        let response: String
    }

    // MARK: - Errors

    enum OdysseusError: LocalizedError, Equatable {
        case notConfigured
        case invalidBaseURL(String)
        /// 401/403 — bad, revoked, or insufficiently privileged token.
        case unauthorized(String?)
        /// 404 for a session id we were reusing. Recoverable: make a new one.
        case sessionNotFound
        case server(status: Int, message: String?)
        case offline
        case timedOut
        /// The HTTP body wasn't the shape this route promises — a problem with
        /// the *server*, not the model's reply.
        case malformedResponse
        case emptyReply
        // The three below are all "the model's text didn't yield a plan", kept
        // separate because each has a different fix and collapsing them into
        // one message makes the failure undiagnosable from the phone.
        /// Model replied in prose; it ignored the format instruction.
        case replyNotJSON(snippet: String)
        /// JSON opened and never closed — the reply hit an output-token cap.
        case replyTruncated(snippet: String)
        /// Valid JSON, but nothing in it looks like a plan.
        case planShapeUnexpected(snippet: String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Odysseus isn't set up yet. Add your server URL and token in Settings."
            case .invalidBaseURL(let raw):
                return "\"\(raw)\" isn't a valid server URL."
            case .unauthorized(let message):
                // The server's own wording first — it distinguishes an invalid
                // token from a valid one lacking access to an endpoint.
                return message.map { "Authentication failed: \($0)" }
                    ?? "Authentication failed. Check your API token in Settings."
            case .sessionNotFound:
                return "That chat session no longer exists on the server."
            case .server(let status, let message):
                return message ?? "Odysseus returned an error (HTTP \(status))."
            case .offline:
                return "Can't reach Odysseus. Check that you're connected to your tailnet."
            case .timedOut:
                return "Odysseus took too long to respond."
            case .malformedResponse:
                return "Couldn't read the response from Odysseus."
            case .emptyReply:
                return "Odysseus returned an empty reply."
            case .replyNotJSON(let snippet):
                return "The model replied in prose instead of JSON. It said: \(snippet)"
            case .replyTruncated(let snippet):
                return "The model's reply was cut off mid-JSON — raise the output token "
                    + "limit on your server. It ended: \(snippet)"
            case .planShapeUnexpected(let snippet):
                return "The model returned JSON, but no workout in it. It said: \(snippet)"
            }
        }
    }

    /// A short, log-safe excerpt of a model reply, for putting in an error the
    /// lifter actually sees. Long enough to recognise the problem, short enough
    /// to fit on a phone screen.
    static func snippet(_ text: String, limit: Int = 180) -> String {
        let collapsed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard collapsed.count > limit else { return collapsed }
        return collapsed.prefix(limit) + "…"
    }

    /// The server reports failures under two different keys depending on which
    /// layer rejected the request: the auth middleware uses `error`, the routes
    /// use `detail`. FastAPI can also make `detail` an array of validation
    /// objects, so that shape is folded in rather than left to surface as a
    /// generic parse failure.
    struct ErrorBody: Decodable {
        let message: String?

        private enum CodingKeys: String, CodingKey { case error, detail }

        private struct ValidationItem: Decodable {
            let msg: String?
        }

        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                message = nil
                return
            }
            if let error = try? container.decode(String.self, forKey: .error) {
                message = error
            } else if let detail = try? container.decode(String.self, forKey: .detail) {
                message = detail
            } else if let items = try? container.decode([ValidationItem].self, forKey: .detail) {
                let joined = items.compactMap(\.msg).joined(separator: "; ")
                message = joined.isEmpty ? nil : joined
            } else {
                message = nil
            }
        }

        /// Best-effort extraction; never throws, because an error path should
        /// never fail on top of the error it's reporting.
        static func message(from data: Data) -> String? {
            let parsed = try? JSONDecoder().decode(ErrorBody.self, from: data)
            guard let message = parsed?.message?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !message.isEmpty
            else { return nil }
            return message
        }
    }

    // MARK: - Endpoints

    /// Health and credential check. Cheapest possible round trip, used by
    /// Settings to tell the lifter whether what they pasted actually works.
    static func ping(baseURL: String, token: String) async throws -> Ping {
        let request = try get("/api/companion/ping", baseURL: baseURL, token: token, timeout: quickTimeout)
        return try await send(request, as: Ping.self)
    }

    /// The model endpoints this token may use.
    static func models(baseURL: String, token: String) async throws -> [Endpoint] {
        let request = try get("/api/companion/models", baseURL: baseURL, token: token, timeout: quickTimeout)
        return try await send(request, as: ModelList.self).endpoints
    }

    /// Creates a chat session. Form-encoded — this route rejects a JSON body.
    static func createSession(
        baseURL: String,
        token: String,
        endpointID: String,
        model: String,
        name: String? = nil
    ) async throws -> Session {
        var fields = ["endpoint_id": endpointID, "model": model]
        if let name, !name.isEmpty { fields["name"] = name }

        var request = try base("/api/session", baseURL: baseURL, token: token, timeout: quickTimeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncode(fields).data(using: .utf8)
        return try await send(request, as: Session.self)
    }

    /// Sends a prompt and waits for the complete reply. JSON-encoded — this
    /// route rejects a form body. Blocks for the whole generation.
    static func chat(
        baseURL: String,
        token: String,
        sessionID: String,
        message: String,
        presetID: String? = nil
    ) async throws -> String {
        // The server trims and bounds the message at 1...50000 chars;
        // clipping here turns a 422 into a still-useful (if truncated) request.
        let trimmed = String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(50_000))
        guard !trimmed.isEmpty else { throw OdysseusError.malformedResponse }

        var body: [String: String] = ["message": trimmed, "session": sessionID]
        if let presetID, !presetID.isEmpty { body["preset_id"] = presetID }

        var request = try base("/api/chat", baseURL: baseURL, token: token, timeout: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let reply = try await send(request, as: ChatReply.self, sessionScoped: true)
        guard !reply.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OdysseusError.emptyReply
        }
        return reply.response
    }

    // MARK: - Request building

    static func normalizedBaseURL(_ raw: String) throws -> URL {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OdysseusError.notConfigured }
        // A pasted host with no scheme is the common slip; assume TLS, since the
        // server has a real certificate.
        if !trimmed.lowercased().hasPrefix("http://"), !trimmed.lowercased().hasPrefix("https://") {
            trimmed = "https://" + trimmed
        }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }

        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            throw OdysseusError.invalidBaseURL(raw)
        }
        return url
    }

    private static func base(
        _ path: String,
        baseURL: String,
        token: String,
        timeout: TimeInterval
    ) throws -> URLRequest {
        let root = try normalizedBaseURL(baseURL)
        guard let url = URL(string: root.absoluteString + path) else {
            throw OdysseusError.invalidBaseURL(baseURL)
        }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { throw OdysseusError.notConfigured }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Set explicitly: URLRequest ships its own 60s default, which would
        // otherwise undercut the session configuration on long generations.
        request.timeoutInterval = timeout
        return request
    }

    private static func get(
        _ path: String,
        baseURL: String,
        token: String,
        timeout: TimeInterval
    ) throws -> URLRequest {
        var request = try base(path, baseURL: baseURL, token: token, timeout: timeout)
        request.httpMethod = "GET"
        return request
    }

    /// Percent-encodes to unreserved characters only. `.urlQueryAllowed` is
    /// wrong for a form body — it permits `&` and `+`, which would corrupt
    /// field boundaries and silently turn a `+` in a value into a space.
    static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
    }

    // MARK: - Transport

    private static func send<T: Decodable>(
        _ request: URLRequest,
        as _: T.Type,
        sessionScoped: Bool = false
    ) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed:
                throw OdysseusError.offline
            case .timedOut:
                throw OdysseusError.timedOut
            default:
                throw OdysseusError.server(status: error.code.rawValue, message: error.localizedDescription)
            }
        }

        guard let http = response as? HTTPURLResponse else { throw OdysseusError.malformedResponse }

        guard (200..<300).contains(http.statusCode) else {
            let message = ErrorBody.message(from: data)
            switch http.statusCode {
            case 401, 403:
                throw OdysseusError.unauthorized(message)
            case 404 where sessionScoped:
                // The persisted session id has been pruned server-side. The
                // caller recreates and retries rather than surfacing this.
                throw OdysseusError.sessionNotFound
            default:
                throw OdysseusError.server(status: http.statusCode, message: message)
            }
        }

        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(T.self, from: data)
        } catch {
            throw OdysseusError.malformedResponse
        }
    }
}
