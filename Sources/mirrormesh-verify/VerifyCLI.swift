import Foundation
import MirrorMeshCore
import MirrorMeshWatermark

@main
struct VerifyCLI {
    static func main() {
        let args = CommandLine.arguments
        guard let manifestIdx = args.firstIndex(of: "--manifest"),
              manifestIdx + 1 < args.count else {
            printUsage()
            exit(2)
        }
        let path = args[manifestIdx + 1]
        let url = URL(fileURLWithPath: path)

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            FileHandle.standardError.write(Data("ERROR: cannot read manifest at \(path): \(error)\n".utf8))
            exit(3)
        }

        let manifest: SessionManifest
        do {
            manifest = try ManifestCodec.decode(data)
        } catch {
            FileHandle.standardError.write(Data("ERROR: manifest decoding failed: \(error)\n".utf8))
            exit(4)
        }

        guard manifest.manifest_version == MirrorMeshWatermark.manifestVersion else {
            FileHandle.standardError.write(Data("ERROR: unsupported manifest_version \(manifest.manifest_version)\n".utf8))
            exit(5)
        }
        guard manifest.manifest_signature_b64 != nil else {
            FileHandle.standardError.write(Data("ERROR: manifest has no signature (unfinalized?)\n".utf8))
            exit(6)
        }
        guard Verifier.verifyManifest(manifest) else {
            FileHandle.standardError.write(Data("ERROR: signature verification failed\n".utf8))
            exit(7)
        }

        print("OK")
        print("session_id: \(manifest.session_id)")
        print("frame_count: \(manifest.frame_count)")
        print("started_at: \(manifest.started_at)")
        if let ended = manifest.ended_at {
            print("ended_at: \(ended)")
        }
        exit(0)
    }

    static func printUsage() {
        FileHandle.standardError.write(Data("""
        mirrormesh-verify \(MirrorMeshCore.version)
        Usage: mirrormesh-verify --manifest <path>

        Verifies the Ed25519 signature on a MirrorMesh session manifest.
        Prints OK on success; non-zero exit on any failure.

        """.utf8))
    }
}
