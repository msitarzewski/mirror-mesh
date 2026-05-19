import Testing
import Foundation
import os.signpost
@testable import MirrorMeshCore

@Suite("Signpost")
struct SignpostTests {
    @Test func beginReturnsNonNullSignpostID() {
        let id = Signpost.begin(Signpost.capture, frame: FrameID(42))
        // OSSignpostID.null is the documented "invalid" sentinel; a fresh id must not equal it.
        #expect(id != .null)
        Signpost.end(Signpost.capture, frame: FrameID(42), id: id)
    }

    @Test func intervalHelperDoesNotThrowAndReturnsBodyResult() {
        let value = Signpost.interval("test", FrameID(7)) { 99 }
        #expect(value == 99)
    }

    @Test func allStageNamesAreUnique() {
        // Pull each as String for set-equality; StaticString isn't Hashable.
        let names: [String] = [
            "\(Signpost.capture)", "\(Signpost.vision)", "\(Signpost.solver)",
            "\(Signpost.render)", "\(Signpost.watermark)", "\(Signpost.pipeline)",
        ]
        #expect(Set(names).count == names.count)
    }

    @Test func eventDoesNotThrow() {
        Signpost.event("test-event", frame: FrameID(1), message: "hello")
    }
}
