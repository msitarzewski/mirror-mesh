import Foundation

/// Append-only JSONL sink. One line per event. Used by `mirrormesh-bench` to produce the
/// canonical paper-grade trace format.
public final class JSONLLogger: TelemetrySink, @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let encoder: JSONEncoder

    public init(url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        self.handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let enc = JSONEncoder()
        enc.outputFormatting = []  // single line per record
        self.encoder = enc
    }

    deinit {
        try? handle.close()
    }

    public func consume(_ event: TelemetryEvent) {
        guard let line = encode(event) else { return }
        lock.lock(); defer { lock.unlock() }
        handle.write(line)
    }

    public func flush() {
        lock.lock(); defer { lock.unlock() }
        try? handle.synchronize()
    }

    // MARK: - encoding

    private struct StageEvent: Encodable {
        let t: String
        let frame: UInt64
        let stage: String
        let host_time_ns: UInt64
    }
    private struct FrameEvent: Encodable {
        let t: String
        let frame: UInt64
        let per_stage_ms: [String: Double]
        let e2e_ms: Double
    }
    private struct MetaEvent: Encodable {
        let t: String
        let session: String
        let device: String
        let os: String
        let commit: String?
    }
    private struct WarnEvent: Encodable {
        let t: String
        let stage: String
        let message: String
    }
    private struct AnnotationEvent: Encodable {
        let t: String
        let key: String
        let value: String
    }
    private struct TranscriptEvent: Encodable {
        let t: String
        let start_ms: Double
        let end_ms: Double
        let text: String
        let confidence: Float
    }
    private struct CoefficientEvent: Encodable {
        let t: String
        let frame: UInt64
        let values: [String: Float]
    }

    private func encode(_ event: TelemetryEvent) -> Data? {
        do {
            let json: Data
            switch event {
            case let .meta(s, dev, osv, c):
                json = try encoder.encode(MetaEvent(t: "meta", session: s, device: dev, os: osv, commit: c))
            case let .stageStart(st, fr, t):
                json = try encoder.encode(StageEvent(t: "stage_start",
                                                    frame: fr.value,
                                                    stage: st.rawValue,
                                                    host_time_ns: t))
            case let .stageEnd(st, fr, t):
                json = try encoder.encode(StageEvent(t: "stage_end",
                                                    frame: fr.value,
                                                    stage: st.rawValue,
                                                    host_time_ns: t))
            case let .frame(fr, per, e2e):
                var dict: [String: Double] = [:]
                for (k, v) in per { dict[k.rawValue] = v }
                json = try encoder.encode(FrameEvent(t: "frame",
                                                    frame: fr.value,
                                                    per_stage_ms: dict,
                                                    e2e_ms: e2e))
            case let .warning(st, msg):
                json = try encoder.encode(WarnEvent(t: "warning", stage: st.rawValue, message: msg))
            case let .error(st, msg):
                json = try encoder.encode(WarnEvent(t: "error", stage: st.rawValue, message: msg))
            case let .annotation(k, v):
                json = try encoder.encode(AnnotationEvent(t: "annotation", key: k, value: v))
            case let .transcript(tf):
                json = try encoder.encode(TranscriptEvent(t: "transcript",
                                                          start_ms: tf.startMs,
                                                          end_ms: tf.endMs,
                                                          text: tf.text,
                                                          confidence: tf.confidence))
            case let .coefficients(fr, vals):
                json = try encoder.encode(CoefficientEvent(t: "coefficients",
                                                            frame: fr.value,
                                                            values: vals))
            }
            var out = json
            out.append(0x0A)  // newline
            return out
        } catch {
            return nil
        }
    }
}
