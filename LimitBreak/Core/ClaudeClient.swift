import Foundation

/// Minimal Anthropic Messages API client.
///
/// There's no official Anthropic SDK for Swift, so this talks to
/// `POST /v1/messages` directly. It covers exactly what LimitBreak needs:
/// a cached system prefix, a JSON-schema-constrained response, and enough
/// error detail to tell the lifter what went wrong.
enum ClaudeClient {

    // MARK: - Configuration

    /// The model behind every AI feature. Opus 5 is the strongest option; swap
    /// to `claude-sonnet-5` here to trade some quality for cost and latency.
    static let model = "claude-opus-5"

    /// How hard the model works before answering. `medium` keeps a phone-side
    /// generation responsive (a lifter is standing in a gym waiting on it)
    /// while still producing well-reasoned plans. Raise to `high` or `xhigh`
    /// for more considered programming at the cost of latency.
    static let effort = "medium"

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"
    /// Opus 5 can decline a request outright; `fallbacks: "default"` lets the
    /// API re-serve it on Anthropic's recommended fallback model instead of
    /// handing us an empty response.
    private static let fallbackBeta = "server-side-fallback-2026-07-01"

    // MARK: - Errors

    enum ClientError: LocalizedError, Equatable {
        case missingKey
        case invalidKey
        case rateLimited
        case refused(String?)
        case server(status: Int, message: String?)
        case offline
        case timedOut
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return "No API key saved. Add one in Settings to use cloud AI."
            case .invalidKey:
                return "That API key was rejected. Check it in Settings."
            case .rateLimited:
                return "Anthropic is rate-limiting this key. Try again shortly."
            case .refused(let explanation):
                return explanation.map { "The request was declined: \($0)" }
                    ?? "The request was declined."
            case .server(let status, let message):
                return message ?? "Anthropic returned an error (HTTP \(status))."
            case .offline:
                return "No internet connection."
            case .timedOut:
                return "The request timed out."
            case .malformedResponse:
                return "Couldn't read the response from Anthropic."
            }
        }
    }

    // MARK: - Request

    /// One block of the system prompt. Marking the last stable block cacheable
    /// means the movement catalog is billed at ~10% on repeat generations.
    struct SystemBlock {
        let text: String
        var cacheable: Bool = false
    }

    /// Sends a single-turn request whose response is constrained to `schema`,
    /// and decodes it as `Output`.
    ///
    /// - Parameters:
    ///   - system: Stable instruction blocks, rendered before the user turn.
    ///     Put volatile content in `userMessage`, never here — a byte change in
    ///     the system prefix invalidates the cache for everything after it.
    ///   - userMessage: The per-request content (goal, fatigue, focus).
    ///   - schema: JSON Schema the response must satisfy.
    static func structuredRequest<Output: Decodable>(
        system: [SystemBlock],
        userMessage: String,
        schema: [String: Any],
        as _: Output.Type,
        maxTokens: Int = 16_000
    ) async throws -> Output {
        guard let apiKey = KeychainStore.apiKey else { throw ClientError.missingKey }

        let systemPayload: [[String: Any]] = system.map { block in
            var entry: [String: Any] = ["type": "text", "text": block.text]
            if block.cacheable {
                entry["cache_control"] = ["type": "ephemeral"]
            }
            return entry
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPayload,
            "messages": [["role": "user", "content": userMessage]],
            "output_config": [
                "effort": effort,
                "format": ["type": "json_schema", "schema": schema],
            ],
            "fallbacks": "default",
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // Thinking is on by default on Opus 5, so a considered plan can take a
        // while — well past URLSession's 60s default.
        request.timeoutInterval = 120

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw ClientError.offline
            case .timedOut:
                throw ClientError.timedOut
            default:
                throw ClientError.server(status: error.code.rawValue, message: error.localizedDescription)
            }
        }

        guard let http = response as? HTTPURLResponse else { throw ClientError.malformedResponse }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard (200..<300).contains(http.statusCode) else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String
            switch http.statusCode {
            case 401, 403: throw ClientError.invalidKey
            case 429:      throw ClientError.rateLimited
            default:       throw ClientError.server(status: http.statusCode, message: message)
            }
        }

        guard let json else { throw ClientError.malformedResponse }

        // A refusal is a successful HTTP 200 with an empty or partial body —
        // check it before reading content, or we'd decode nothing and report a
        // parse failure for what is really a policy decline.
        if json["stop_reason"] as? String == "refusal" {
            let details = json["stop_details"] as? [String: Any]
            throw ClientError.refused(details?["explanation"] as? String)
        }

        guard let content = json["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let payload = text.data(using: .utf8)
        else { throw ClientError.malformedResponse }

        do {
            return try JSONDecoder().decode(Output.self, from: payload)
        } catch {
            throw ClientError.malformedResponse
        }
    }

    // MARK: - Key verification

    /// Cheapest possible round trip, used by Settings to tell the lifter
    /// whether the key they pasted actually works.
    static func verifyKey() async -> Result<Void, ClientError> {
        guard let apiKey = KeychainStore.apiKey else { return .failure(.missingKey) }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "Hi"]],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.malformedResponse) }
            switch http.statusCode {
            case 200..<300: return .success(())
            case 401, 403:  return .failure(.invalidKey)
            case 429:       return .failure(.rateLimited)
            default:
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let message = (json?["error"] as? [String: Any])?["message"] as? String
                return .failure(.server(status: http.statusCode, message: message))
            }
        } catch let error as URLError where error.code == .notConnectedToInternet {
            return .failure(.offline)
        } catch {
            return .failure(.server(status: -1, message: error.localizedDescription))
        }
    }
}
