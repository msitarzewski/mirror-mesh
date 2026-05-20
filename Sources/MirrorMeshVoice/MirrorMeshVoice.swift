import Foundation

/// Module marker for `MirrorMeshVoice` (M28). Holds the version stamp the voice
/// pipeline emits as a meta annotation so JSONL traces tell us which build wrote them.
public enum MirrorMeshVoice {
    public static let version: String = "0.7.0-voice"
    /// Module marker shared by the stub test in `Tests/MirrorMeshVoiceTests`.
    public static let moduleName: String = "MirrorMeshVoice"
}
