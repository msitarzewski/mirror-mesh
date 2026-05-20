import Testing
import Foundation
@testable import MirrorMeshTranslate

@Suite("OllamaClient")
struct OllamaClientTests {

    // MARK: - Mock transport

    /// Records the URL/body/timeout that the actor pushed and replays a canned response.
    final class MockTransport: OllamaTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [(Data, Int)] = []
        private var error: OllamaTranslatorError?
        private(set) var lastURL: URL?
        private(set) var lastBody: Data?
        private(set) var lastTimeout: TimeInterval = 0

        func enqueue(body: Data, status: Int) {
            lock.lock(); defer { lock.unlock() }
            responses.append((body, status))
        }
        func failWith(_ e: OllamaTranslatorError) {
            lock.lock(); defer { lock.unlock() }
            error = e
        }

        func post(url: URL, body: Data, timeoutSeconds: TimeInterval) async throws -> (Data, Int) {
            lock.lock()
            lastURL = url; lastBody = body; lastTimeout = timeoutSeconds
            let e = error
            let r = responses.isEmpty ? nil : responses.removeFirst()
            lock.unlock()
            if let e { throw e }
            guard let r else {
                throw OllamaTranslatorError.transport("MockTransport: no response queued")
            }
            return r
        }
    }

    // MARK: - request payload

    @Test func buildRequestBodyHasExpectedShape() async throws {
        let translator = OllamaTranslator(
            config: OllamaConfig(model: "llama3.2:3b", temperature: 0.3),
            transport: MockTransport()
        )
        let body = try await translator.buildRequestBody(
            text: "Hello.",
            source: Locale(identifier: "en-US"),
            target: Locale(identifier: "fr-FR")
        )
        let obj = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(obj["model"] as? String == "llama3.2:3b")
        #expect(obj["stream"] as? Bool == true)
        let prompt = try #require(obj["prompt"] as? String)
        #expect(prompt.contains("Hello."))
        #expect(prompt.lowercased().contains("translate"))
        // Temperature flows through options.
        let opts = try #require(obj["options"] as? [String: Any])
        let temp = opts["temperature"] as? Double ?? -1
        #expect(abs(temp - 0.3) < 1e-6)
    }

    @Test func promptIncludesBothLanguageNames() {
        let prompt = OllamaTranslator.translationPrompt(
            text: "Good morning.",
            source: Locale(identifier: "en-US"),
            target: Locale(identifier: "es-ES")
        )
        // Both human-readable language names should appear somewhere in the prompt.
        // We assert on the language *codes*' descriptions resolved via Locale.current — the
        // exact phrasing depends on the test runner's locale, so we check that *some* form
        // of "English" / "Spanish" rendering is present by re-resolving the names.
        let en = OllamaTranslator.humanReadableLanguageName(for: Locale(identifier: "en-US"))
        let es = OllamaTranslator.humanReadableLanguageName(for: Locale(identifier: "es-ES"))
        #expect(prompt.contains(en))
        #expect(prompt.contains(es))
        #expect(prompt.contains("no explanation"))
        #expect(prompt.contains("Good morning."))
    }

    // MARK: - happy-path NDJSON streaming

    @Test func translateAssemblesNDJSONChunks() async throws {
        let transport = MockTransport()
        let lines = [
            "{\"response\":\"Hola\",\"done\":false}",
            "{\"response\":\", \",\"done\":false}",
            "{\"response\":\"mundo.\",\"done\":false}",
            "{\"response\":\"\",\"done\":true,\"total_duration\":1234}",
        ]
        let body = Data(lines.joined(separator: "\n").utf8)
        transport.enqueue(body: body, status: 200)

        let translator = OllamaTranslator(config: OllamaConfig(), transport: transport)
        let result = try await translator.translate(
            "Hello, world.",
            from: Locale(identifier: "en-US"),
            to: Locale(identifier: "es-ES")
        )
        #expect(result == "Hola, mundo.")
        // Verify the URL the transport saw.
        #expect(transport.lastURL?.absoluteString == "http://localhost:11434/api/generate")
    }

    @Test func translateStreamYieldsPartialThenFinal() async throws {
        let transport = MockTransport()
        let lines = [
            "{\"response\":\"Bon\",\"done\":false}",
            "{\"response\":\"jour\",\"done\":false}",
            "{\"response\":\"\",\"done\":true}",
        ]
        transport.enqueue(body: Data(lines.joined(separator: "\n").utf8), status: 200)
        let translator = OllamaTranslator(config: OllamaConfig(), transport: transport)

        var partials: [String] = []
        var sawFinal = false
        for try await chunk in translator.translateStream(
            "Hello",
            from: Locale(identifier: "en-US"),
            to: Locale(identifier: "fr-FR")
        ) {
            if chunk.isFinal { sawFinal = true } else { partials.append(chunk.partial) }
        }
        #expect(sawFinal)
        #expect(partials == ["Bon", "jour"])
    }

    // MARK: - error classification

    @Test func connectionRefusedMapsCleanly() async {
        let transport = MockTransport()
        let url = URL(string: "http://localhost:11434")!
        transport.failWith(.connectionRefused(url))
        let translator = OllamaTranslator(transport: transport)
        do {
            _ = try await translator.translate(
                "Hi",
                from: Locale(identifier: "en-US"),
                to: Locale(identifier: "es-ES")
            )
            Issue.record("expected throw")
        } catch let err as OllamaTranslatorError {
            #expect(err == .connectionRefused(url))
            #expect(err.description.contains("ollama serve"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func modelNotPulledMapsCleanly() async {
        let transport = MockTransport()
        transport.enqueue(body: Data("not found".utf8), status: 404)
        let translator = OllamaTranslator(
            config: OllamaConfig(model: "doesnotexist:13b"),
            transport: transport
        )
        do {
            _ = try await translator.translate("Hi", from: Locale(identifier: "en-US"), to: Locale(identifier: "es-ES"))
            Issue.record("expected throw")
        } catch let err as OllamaTranslatorError {
            #expect(err == .modelNotPulled("doesnotexist:13b"))
            #expect(err.description.contains("ollama pull"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func serverErrorMapsToFiveHundred() async {
        let transport = MockTransport()
        transport.enqueue(body: Data("upstream is on fire".utf8), status: 503)
        let translator = OllamaTranslator(transport: transport)
        do {
            _ = try await translator.translate("Hi", from: Locale(identifier: "en-US"), to: Locale(identifier: "es-ES"))
            Issue.record("expected throw")
        } catch let err as OllamaTranslatorError {
            if case let .serverError(code, body) = err {
                #expect(code == 503)
                #expect(body.contains("upstream is on fire"))
            } else {
                Issue.record("unexpected case: \(err)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func emptyResponseSurfacesAsDedicatedError() async {
        let transport = MockTransport()
        transport.enqueue(body: Data(), status: 200)
        let translator = OllamaTranslator(transport: transport)
        do {
            _ = try await translator.translate("Hi", from: Locale(identifier: "en-US"), to: Locale(identifier: "es-ES"))
            Issue.record("expected throw")
        } catch let err as OllamaTranslatorError {
            #expect(err == .emptyResponse)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func timeoutPropagatesAsDistinctCase() async {
        let transport = MockTransport()
        transport.failWith(.timeout(seconds: 5))
        let translator = OllamaTranslator(transport: transport)
        do {
            _ = try await translator.translate("Hi", from: Locale(identifier: "en-US"), to: Locale(identifier: "es-ES"))
            Issue.record("expected throw")
        } catch let err as OllamaTranslatorError {
            #expect(err == .timeout(seconds: 5))
            #expect(err.description.contains("5"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - the live-server smoke test (disabled by default)

    @Test(.disabled("Requires a running local Ollama with llama3.2:3b pulled. Run manually."))
    func liveOllamaSmoke() async throws {
        let translator = OllamaTranslator()
        let translated = try await translator.translate(
            "Hello, world.",
            from: Locale(identifier: "en-US"),
            to: Locale(identifier: "es-ES")
        )
        // We don't pin the exact string — different model versions translate differently.
        // Sanity: a Spanish translation contains at least one of these tokens.
        let lower = translated.lowercased()
        #expect(lower.contains("hola") || lower.contains("mundo"))
    }
}
