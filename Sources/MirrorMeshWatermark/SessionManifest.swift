import Foundation

public struct SessionManifest: Codable, Sendable, Equatable {
    public var manifest_version: String
    public var session_id: String
    public var started_at: Date
    public var ended_at: Date?
    public var device: DeviceInfo
    public var pipeline: PipelineConfig
    public var models: [ModelRef]
    public var consent: ConsentRecord
    public var frame_count: Int
    public var public_key_b64: String
    public var manifest_signature_b64: String?

    public init(manifest_version: String = MirrorMeshWatermark.manifestVersion,
                session_id: String = UUID().uuidString,
                started_at: Date,
                ended_at: Date? = nil,
                device: DeviceInfo,
                pipeline: PipelineConfig,
                models: [ModelRef] = [],
                consent: ConsentRecord,
                frame_count: Int = 0,
                public_key_b64: String,
                manifest_signature_b64: String? = nil) {
        self.manifest_version = manifest_version
        self.session_id = session_id
        self.started_at = started_at
        self.ended_at = ended_at
        self.device = device
        self.pipeline = pipeline
        self.models = models
        self.consent = consent
        self.frame_count = frame_count
        self.public_key_b64 = public_key_b64
        self.manifest_signature_b64 = manifest_signature_b64
    }
}

// Canonical encoder/decoder so the bytes signed at finalize() match the bytes verified
// later. Without sortedKeys + .iso8601, two JSON encoders could emit semantically
// equal manifests with different byte sequences and fail signature checks.
public enum ManifestCodec {
    public static func encoder(sorted: Bool = true) -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        var opts: JSONEncoder.OutputFormatting = []
        if sorted { opts.insert(.sortedKeys) }
        enc.outputFormatting = opts
        return enc
    }

    public static func decoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    public static func canonicalEncode(_ manifest: SessionManifest) throws -> Data {
        try encoder(sorted: true).encode(manifest)
    }

    public static func prettyEncode(_ manifest: SessionManifest) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try enc.encode(manifest)
    }

    public static func decode(_ data: Data) throws -> SessionManifest {
        try decoder().decode(SessionManifest.self, from: data)
    }
}
