import Foundation
import MirrorMeshCore

public actor ManifestWriter {
    private let url: URL
    private let signer: FrameSigner
    private var manifest: SessionManifest
    private var finalized = false

    public init(url: URL, signer: FrameSigner, manifest: SessionManifest) {
        self.url = url
        self.signer = signer
        self.manifest = manifest
    }

    public var currentManifest: SessionManifest { manifest }

    public func recordFrame(_ frame: WatermarkedFrame) {
        guard !finalized else { return }
        manifest.frame_count &+= 1
    }

    public func recordFrames(_ count: Int) {
        guard !finalized else { return }
        manifest.frame_count &+= count
    }

    public func updatePipeline(_ pipeline: PipelineConfig) {
        guard !finalized else { return }
        manifest.pipeline = pipeline
    }

    public func appendModel(_ model: ModelRef) {
        guard !finalized else { return }
        manifest.models.append(model)
    }

    public func finalize(at endTime: Date = Date()) async throws {
        guard !finalized else { return }
        manifest.ended_at = endTime
        manifest.manifest_signature_b64 = nil
        let canonical = try ManifestCodec.canonicalEncode(manifest)
        let signature = signer.signManifest(canonical)
        manifest.manifest_signature_b64 = signature.base64EncodedString()
        let pretty = try ManifestCodec.prettyEncode(manifest)
        try writeAtomic(data: pretty, to: url)
        finalized = true
    }

    private func writeAtomic(data: Data, to dest: URL) throws {
        let dir = dest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(dest.lastPathComponent + ".tmp")
        if FileManager.default.fileExists(atPath: tmp.path) {
            try FileManager.default.removeItem(at: tmp)
        }
        try data.write(to: tmp, options: [.atomic])
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: tmp, to: dest)
    }
}
