import XCTest
@testable import HushType

@MainActor
final class DictionaryLibraryEditorSessionTests: XCTestCase {
    func testLegacyEditorDraftStaysInSession() throws {
        let editor = DictionaryEditorModel(fileURL: URL(fileURLWithPath: "/unused-dictionary-test.txt"))
        let session = DictionaryLibraryEditorSession(defaultEditor: editor)
        XCTAssertNil(session.selectedID)
        editor.rules = [DictionaryRule(source: "heard", target: "intended")]
        let otherID = UUID()
        let otherURL = URL(fileURLWithPath: "/unused-other-dictionary-test.txt")
        session.selectedID = otherID
        let other = session.editor(for: otherID, fileURL: otherURL)
        other.rules = [DictionaryRule(source: "second", target: "library")]
        session.selectedID = DictionaryLibraryStore.defaultID
        let restored = session.editor(for: try XCTUnwrap(session.selectedID), fileURL: otherURL)
        XCTAssertTrue(restored === editor)
        XCTAssertEqual(restored.rules.first?.target, "intended")
        XCTAssertTrue(restored.hasChanges)
        XCTAssertTrue(session.editor(for: otherID, fileURL: otherURL) === other)
        XCTAssertEqual(other.rules.first?.target, "library")
        session.forget(otherID)
        XCTAssertFalse(session.editor(for: otherID, fileURL: otherURL) === other)
    }
}
