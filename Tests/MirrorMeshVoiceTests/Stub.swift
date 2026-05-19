import Testing
@testable import MirrorMeshVoice

@Suite("MirrorMeshVoice (stub)")
struct MirrorMeshVoiceStubTests {
    @Test func moduleNameIsStable() {
        #expect(MirrorMeshVoice.moduleName == "MirrorMeshVoice")
    }
}
