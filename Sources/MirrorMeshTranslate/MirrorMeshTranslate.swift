import Foundation

/// Module marker for `MirrorMeshTranslate` (v0.8.0 accessibility WOW feature).
///
/// **Disclosure**: this module talks to a *local* Ollama instance at
/// `http://localhost:11434/`. We do NOT ship Ollama; the operator must install it
/// separately (`brew install ollama`) and pull the desired model (e.g.
/// `ollama pull llama3.2:3b`). The CLI (`mirrormesh-translate`) prints a one-line
/// disclosure at startup. R3 / R4 compliance: no cloud LLM. R2: when this module is
/// active, the pipeline's watermark records "voice_transformed: true" (see the
/// orchestrator integration notes in `LipSyncDriver.swift`).
public enum MirrorMeshTranslate {
    public static let version: String = "0.8.0-translate"
    public static let moduleName: String = "MirrorMeshTranslate"

    /// One-line disclosure printed by the CLI on startup. The Settings UI shows the same
    /// line verbatim so the operator always sees the same wording. Stable; do not vary.
    public static let localOllamaDisclosure: String =
        "Translation provided by local Ollama instance at http://localhost:11434/"
}
