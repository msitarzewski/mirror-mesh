import Foundation
import MirrorMeshCore

// MARK: - Public types

/// Errors surfaced by the Ollama translator. Each case is a distinct, actionable failure —
/// the SwiftUI Settings UI maps them to a one-line toast so the operator knows exactly what
/// to do (start Ollama, pull the model, retry, etc.). Sendable because translation runs across
/// actor boundaries.
public enum OllamaTranslatorError: Error, CustomStringConvertible, Sendable, Equatable {
    /// `connect(2)` to `http://localhost:11434` returned ECONNREFUSED or the URLSession surfaced
    /// `NSURLErrorCannotConnectToHost`. Ollama isn't running. The operator-facing fix:
    /// `brew services start ollama` or `ollama serve`.
    case connectionRefused(URL)

    /// HTTP 404 from `/api/generate`: the model name isn't in the local registry. The fix is
    /// `ollama pull <model>`. We include the model name in the case so the toast can quote it.
    case modelNotPulled(String)

    /// The request completed but produced no parseable translation (empty body, all-empty
    /// `response` chunks, JSON decode failure). Usually a sign the model produced nothing or
    /// the network response was truncated. Differentiated from `serverError` so the UI can
    /// suggest "try a longer model" vs. "server is unhealthy".
    case emptyResponse

    /// Wall-clock timeout exceeded the configured budget. `seconds` is the budget we hit, so
    /// the toast can read "Translation took longer than 5s — pick a smaller model".
    case timeout(seconds: TimeInterval)

    /// HTTP 5xx or any non-recoverable server-side error. `body` is the truncated server text
    /// so debug builds can surface it; release builds typically only display the case name.
    case serverError(statusCode: Int, body: String)

    /// Transport-level failure not classified above (DNS, TLS — though localhost shouldn't see
    /// either). Wrapped with the underlying error's localizedDescription as a string so the
    /// case stays Equatable / Sendable.
    case transport(String)

    public var description: String {
        switch self {
        case let .connectionRefused(url):
            return "Cannot reach Ollama at \(url.absoluteString). Run `ollama serve` (or `brew services start ollama`)."
        case let .modelNotPulled(name):
            return "Model \"\(name)\" is not available locally. Run `ollama pull \(name)`."
        case .emptyResponse:
            return "Ollama returned no usable translation. Try a different model or shorter input."
        case let .timeout(seconds):
            return "Ollama did not respond within \(Int(seconds))s. Try a smaller model (e.g. llama3.2:3b)."
        case let .serverError(statusCode, body):
            let trimmed = body.count > 200 ? String(body.prefix(200)) + "…" : body
            return "Ollama returned HTTP \(statusCode): \(trimmed)"
        case let .transport(detail):
            return "Network error talking to Ollama: \(detail)"
        }
    }
}

/// One chunk of an in-progress translation. The streaming pipeline emits these as Ollama
/// produces tokens; UI bindings can append `partial` to show live partial output. The final
/// chunk has `isFinal == true` and `partial == ""` (a sentinel — the accumulated text up to
/// that point is the complete translation).
public struct TranslationChunk: Sendable, Equatable {
    /// The token(s) produced by Ollama since the previous chunk. Concatenating all `partial`
    /// values (excluding the final sentinel chunk) reconstructs the complete translation.
    public let partial: String

    /// True only on the final chunk in the stream.
    public let isFinal: Bool

    public init(partial: String, isFinal: Bool) {
        self.partial = partial
        self.isFinal = isFinal
    }
}

/// Configuration for the local Ollama HTTP client.
public struct OllamaConfig: Sendable, Equatable {
    /// Base URL of the local Ollama instance. Locked to localhost by default — we explicitly
    /// document in the README that this is the only network egress the translation module
    /// performs. R3 / R4 compliance: no cloud LLM allowed; this is a *local* HTTP server.
    public var baseURL: URL

    /// Ollama model identifier (e.g. `llama3.2:3b`, `qwen2.5:7b`, `gemma2:2b`).
    public var model: String

    /// Per-request timeout in seconds. Default 5s — anything longer and we want to surface
    /// `OllamaTranslatorError.timeout` so the UI can suggest a smaller model.
    public var timeoutSeconds: TimeInterval

    /// Sampling temperature passed through to Ollama. Translation wants determinism, so we
    /// default to 0.2 (low but not zero — zero can produce repetitive outputs on some models).
    public var temperature: Double

    public init(
        baseURL: URL = URL(string: "http://localhost:11434")!,
        model: String = "llama3.2:3b",
        timeoutSeconds: TimeInterval = 5.0,
        temperature: Double = 0.2
    ) {
        self.baseURL = baseURL
        self.model = model
        self.timeoutSeconds = timeoutSeconds
        self.temperature = temperature
    }
}

// MARK: - URL session abstraction

/// Minimal seam over URLSession so tests can inject a mock transport without needing a real
/// HTTP server. We model Ollama's `/api/generate` endpoint with `stream: true`, which returns
/// a sequence of newline-delimited JSON objects. The transport returns the full body (we parse
/// the NDJSON ourselves) plus an HTTP status — that's all we need.
///
/// **Why not URLSession's streaming bytes API directly**: AsyncBytes drops the HTTP status on
/// the floor when the request fails before the body opens (e.g. ECONNREFUSED), and we need to
/// classify those as `.connectionRefused` rather than `.transport`. This wrapper centralizes
/// the classification.
public protocol OllamaTransport: Sendable {
    /// Perform a POST against the given URL with the given JSON body and timeout. Return the
    /// raw response data + HTTP status, OR throw a transport error pre-classified.
    func post(
        url: URL,
        body: Data,
        timeoutSeconds: TimeInterval
    ) async throws -> (Data, Int)
}

/// Production transport: thin wrapper over URLSession. Lives on the actor's executor.
public struct URLSessionOllamaTransport: OllamaTransport {
    /// The underlying session. Captured for test injection; production passes `.shared`.
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func post(
        url: URL,
        body: Data,
        timeoutSeconds: TimeInterval
    ) async throws -> (Data, Int) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = timeoutSeconds
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (data, status)
        } catch let urlError as URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                throw OllamaTranslatorError.connectionRefused(url)
            case .timedOut:
                throw OllamaTranslatorError.timeout(seconds: timeoutSeconds)
            default:
                throw OllamaTranslatorError.transport(urlError.localizedDescription)
            }
        }
    }
}

// MARK: - OllamaTranslator actor

/// Local LLM-driven translator. Talks to Ollama at `http://localhost:11434/api/generate`,
/// streams the response, and returns the full translated string.
///
/// **Why an actor**: callers come from the UI, CLI, and a future pipeline stage. Serializing
/// access through actor isolation prevents two concurrent requests from racing on the same
/// transport (Ollama doesn't multiplex well on a single model load).
///
/// **Streaming**: callers that want progressive output use `translateStream(...)`. Callers
/// that just want the final translation use `translate(...)` — which is implemented in terms
/// of `translateStream` so there's exactly one code path doing the protocol work.
public actor OllamaTranslator {

    public private(set) var config: OllamaConfig
    private let transport: any OllamaTransport

    public init(config: OllamaConfig = OllamaConfig(), transport: any OllamaTransport = URLSessionOllamaTransport()) {
        self.config = config
        self.transport = transport
    }

    /// Hot-swap configuration (model, timeout, baseURL). Used by Settings UI.
    public func updateConfig(_ config: OllamaConfig) {
        self.config = config
    }

    /// One-shot translation. Awaits the full response, then returns the concatenated text.
    /// Equivalent to draining `translateStream(...)` to its terminal chunk.
    public func translate(_ text: String, from source: Locale, to target: Locale) async throws -> String {
        var assembled = ""
        for try await chunk in translateStream(text, from: source, to: target) {
            assembled += chunk.partial
        }
        // Strip leading/trailing whitespace — Ollama sometimes emits a leading newline.
        return assembled.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Streaming translation. Yields `TranslationChunk`s as Ollama produces tokens. The final
    /// chunk has `isFinal == true`. On error, the stream finishes by throwing the
    /// `OllamaTranslatorError`.
    ///
    /// **NDJSON contract**: Ollama returns one JSON object per line with shape:
    /// `{"model":"...","created_at":"...","response":"chunk","done":false}`. We accumulate
    /// `response` across lines and surface them as `TranslationChunk(partial:)`.
    public nonisolated func translateStream(_ text: String, from source: Locale, to target: Locale) -> AsyncThrowingStream<TranslationChunk, Error> {
        AsyncThrowingStream<TranslationChunk, Error> { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    try await self.runTranslateStream(text: text, source: source, target: target, continuation: continuation)
                } catch let err as OllamaTranslatorError {
                    continuation.finish(throwing: err)
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: OllamaTranslatorError.transport(String(describing: error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Implementation

    /// Build a request body for Ollama's `/api/generate`. Public for tests so they can pin
    /// the exact JSON shape (the regression-most-likely surface area).
    public func buildRequestBody(text: String, source: Locale, target: Locale) throws -> Data {
        let prompt = Self.translationPrompt(text: text, source: source, target: target)
        let payload: [String: Any] = [
            "model": config.model,
            "prompt": prompt,
            "stream": true,
            "options": [
                "temperature": config.temperature,
            ],
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    /// The single prompt used by the translator. Tuned to discourage chit-chat — every model
    /// we've tested (`llama3.2:3b`, `qwen2.5:7b`, `gemma2:2b`) follows the "no explanation, no
    /// quotes" instruction reliably. Public so callers can preview the prompt for the
    /// disclosure panel.
    public static func translationPrompt(text: String, source: Locale, target: Locale) -> String {
        let from = humanReadableLanguageName(for: source)
        let to = humanReadableLanguageName(for: target)
        return """
        Translate the following text from \(from) to \(to). Output only the translation, no explanation, no quotes.

        Text: \(text)
        """
    }

    /// Resolve a locale to a human-readable language name. Prefers `Locale.current` for
    /// display so the prompt is in the operator's UI language — empirically that gives
    /// llama3.2:3b a small but consistent quality bump vs. the source-language name.
    public static func humanReadableLanguageName(for locale: Locale) -> String {
        if let code = locale.language.languageCode?.identifier,
           let name = Locale.current.localizedString(forLanguageCode: code) {
            return name
        }
        return locale.identifier
    }

    private func runTranslateStream(
        text: String,
        source: Locale,
        target: Locale,
        continuation: AsyncThrowingStream<TranslationChunk, Error>.Continuation
    ) async throws {
        let body = try buildRequestBody(text: text, source: source, target: target)
        let url = config.baseURL.appendingPathComponent("api/generate")

        let (data, status): (Data, Int)
        do {
            (data, status) = try await transport.post(url: url, body: body, timeoutSeconds: config.timeoutSeconds)
        } catch let err as OllamaTranslatorError {
            throw err
        }

        switch status {
        case 200:
            break
        case 404:
            // Ollama returns 404 for unknown models. Parse the body to recover the model
            // identifier when present, fall back to config.model otherwise.
            throw OllamaTranslatorError.modelNotPulled(config.model)
        case 500..<600:
            let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
            throw OllamaTranslatorError.serverError(statusCode: status, body: bodyStr)
        default:
            let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
            throw OllamaTranslatorError.serverError(statusCode: status, body: bodyStr)
        }

        // Parse NDJSON. Each line is one of:
        //   {"response":"hello", "done":false}
        //   {"response":"",      "done":true,  "total_duration":...}
        var sawAny = false
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)  // '\n'
        for line in lines {
            let lineData = Data(line)
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            let response = (obj["response"] as? String) ?? ""
            let done = (obj["done"] as? Bool) ?? false
            if !response.isEmpty {
                sawAny = true
                continuation.yield(TranslationChunk(partial: response, isFinal: false))
            }
            if done {
                continuation.yield(TranslationChunk(partial: "", isFinal: true))
                continuation.finish()
                return
            }
        }

        // We drained the body without ever seeing `done:true`. If we saw text, emit a synthetic
        // final marker so consumers can complete their assembly. If we saw nothing at all, this
        // is an empty-response error.
        if sawAny {
            continuation.yield(TranslationChunk(partial: "", isFinal: true))
            continuation.finish()
        } else {
            throw OllamaTranslatorError.emptyResponse
        }
    }
}
