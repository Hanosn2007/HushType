import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import HushType

@MainActor
final class DictionaryEditorTests: XCTestCase {
    private let fileManager = FileManager.default
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("HushType-DictionaryEditorTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try fileManager.trashItem(at: temporaryDirectory, resultingItemURL: nil)
        }
        temporaryDirectory = nil
    }

    func testLegacyGrammarRoundTripsMixedLineEndingsAndUsesASCIIArrowFirst() {
        let contents = "# keep this comment\r\nlong phrase -> longest\nrepeat -> first\r\nrepeat -> second\nleft → middle -> ASCII wins\r\nunknown line\n"
        let document = DictionaryDocument(contents: contents)

        XCTAssertEqual(document.rules.map(\.source), ["long phrase", "repeat", "repeat", "left → middle"])
        XCTAssertEqual(document.rules.map(\.target), ["longest", "first", "second", "ASCII wins"])
        XCTAssertEqual(document.serialized(with: document.rules), contents)

        // This also proves mixed LF/CRLF input is parsed per line rather than
        // being collapsed into one rule by a global line-ending choice.
        XCTAssertEqual(
            DictionaryReplacer.apply(
                "LONG PHRASE repeat left → middle",
                rules: document.rules
            ),
            "longest first ASCII wins"
        )
    }

    func testReplacementUsesLongestCaseInsensitiveFileOrderAndSinglePass() {
        let rules = [
            DictionaryRule(source: "cloud", target: "C"),
            DictionaryRule(source: "cloud code", target: "Claude Code"),
            DictionaryRule(source: "repeat", target: "first"),
            DictionaryRule(source: "repeat", target: "second"),
            DictionaryRule(source: "walk", target: "move"),
            DictionaryRule(source: "move", target: "ran"),
            DictionaryRule(source: "delete me", target: ""),
        ]

        XCTAssertEqual(
            DictionaryReplacer.apply("CLOUD CODE cloud repeat WALK delete me", rules: rules),
            "Claude Code C first move "
        )
    }

    func testDraftPreviewDoesNotWriteUntilSaveThenReloads() throws {
        let url = dictionaryURL
        let editor = DictionaryEditorModel(fileURL: url)
        editor.loadIfNeeded()

        let id = editor.addRule()
        // Direct TXT parsing has always ignored padding around both columns;
        // preview and Save normalize it the same way rather than rejecting a
        // common pasted trailing space.
        editor.rules[0].source = "  cloud code  "
        editor.rules[0].target = " Claude Code "
        editor.previewInput = "CLOUD CODE is ready"

        XCTAssertEqual(id, editor.rules[0].id)
        XCTAssertEqual(editor.previewOutput, "Claude Code is ready")
        XCTAssertFalse(fileManager.fileExists(atPath: url.path))
        XCTAssertTrue(editor.canSave)

        editor.save()

        XCTAssertFalse(editor.hasChanges)
        XCTAssertNil(editor.errorMessage)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "cloud code -> Claude Code")

        let reloaded = DictionaryEditorModel(fileURL: url)
        reloaded.loadIfNeeded()
        XCTAssertEqual(reloaded.rules.map(\.source), ["cloud code"])
        XCTAssertEqual(reloaded.rules.map(\.target), ["Claude Code"])
    }

    func testSavingEditAndRemovalKeepsCommentsAndUnknownLines() throws {
        let url = dictionaryURL
        let contents = "# keep exactly\nremove -> old\nthis is an unknown note\nstay  ->  same\n"
        try contents.write(to: url, atomically: true, encoding: .utf8)
        let editor = DictionaryEditorModel(fileURL: url)
        editor.loadIfNeeded()

        editor.removeRule(id: try XCTUnwrap(editor.rules.first(where: { $0.source == "remove" })?.id))
        let stay = try XCTUnwrap(editor.rules.firstIndex(where: { $0.source == "stay" }))
        editor.rules[stay].target = "updated"
        editor.save()

        XCTAssertNil(editor.errorMessage)
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            "# keep exactly\n\nthis is an unknown note\nstay -> updated\n"
        )
    }

    func testExternalChangeKeepsDraftAndBlocksSaveUntilReload() throws {
        let url = dictionaryURL
        try "name -> saved\n".write(to: url, atomically: true, encoding: .utf8)
        let editor = DictionaryEditorModel(fileURL: url)
        editor.loadIfNeeded()
        editor.rules[0].target = "draft"

        try "name -> external\n".write(to: url, atomically: true, encoding: .utf8)
        editor.refreshIfUnchanged()
        editor.save()

        XCTAssertTrue(editor.hasChanges)
        XCTAssertEqual(editor.rules[0].target, "draft")
        XCTAssertFalse(editor.canSave)
        XCTAssertNotNil(editor.errorMessage)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "name -> external\n")

        editor.reload()
        XCTAssertEqual(editor.rules[0].target, "external")
        XCTAssertFalse(editor.hasChanges)
        XCTAssertNil(editor.errorMessage)
    }

    func testMissingUnreadableAndUnwritableFilesPresentErrorsWithoutOverwriting() throws {
        let missing = DictionaryEditorModel(fileURL: dictionaryURL)
        missing.loadIfNeeded()
        XCTAssertTrue(missing.rules.isEmpty)
        XCTAssertNil(missing.errorMessage)

        let unreadableURL = temporaryDirectory.appendingPathComponent("invalid-utf8.txt")
        try Data([0xFF]).write(to: unreadableURL)
        let unreadable = DictionaryEditorModel(fileURL: unreadableURL)
        unreadable.loadIfNeeded()
        XCTAssertTrue(unreadable.rules.isEmpty)
        XCTAssertNotNil(unreadable.errorMessage)

        let parentFile = temporaryDirectory.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: parentFile)
        let unwritable = DictionaryEditorModel(fileURL: parentFile.appendingPathComponent("dictionary.txt"))
        unwritable.loadIfNeeded()
        unwritable.rules = [DictionaryRule(source: "name", target: "value")]
        unwritable.save()
        XCTAssertTrue(unwritable.hasChanges)
        XCTAssertNotNil(unwritable.errorMessage)
    }

    func testValidationRejectsUnserializableRulesButAllowsRepeatedLegacySources() {
        let invalidRules = [
            DictionaryRule(source: "", target: "value"),
            DictionaryRule(source: "one\ntwo", target: "value"),
            DictionaryRule(source: "#comment", target: "value"),
            DictionaryRule(source: "one -> two", target: "value"),
            DictionaryRule(source: "name", target: "line\nbreak"),
        ]

        for rule in invalidRules {
            let editor = DictionaryEditorModel(fileURL: dictionaryURL)
            editor.loadIfNeeded()
            editor.rules = [rule]
            XCTAssertNotNil(editor.validationMessage, "Expected validation for \(rule.source)")
            XCTAssertFalse(editor.canSave)
        }

        let arrowInSource = DictionaryEditorModel(fileURL: dictionaryURL)
        arrowInSource.loadIfNeeded()
        arrowInSource.rules = [DictionaryRule(source: "left → middle", target: "right")]
        XCTAssertTrue(arrowInSource.canSave)

        let duplicate = DictionaryEditorModel(fileURL: dictionaryURL)
        duplicate.loadIfNeeded()
        duplicate.rules = [
            DictionaryRule(source: "Cloud Code", target: "first"),
            DictionaryRule(source: "cloud code", target: "second"),
        ]
        XCTAssertNotNil(duplicate.validationMessage)
        XCTAssertTrue(duplicate.canSave)
        XCTAssertEqual(duplicate.previewOutput, "")
        duplicate.previewInput = "CLOUD CODE"
        XCTAssertEqual(duplicate.previewOutput, "first")
    }

    func testStaleBindingsAfterRemovingOnlyUnsavedRuleDoNotReinsertIt() {
        let editor = DictionaryEditorModel(fileURL: dictionaryURL)
        editor.loadIfNeeded()
        _ = editor.addRule()
        let rule = editor.rules[0]
        let source = editor.textBinding(for: rule, field: \DictionaryRule.source)
        let target = editor.textBinding(for: rule, field: \DictionaryRule.target)

        source.wrappedValue = "draft source"
        target.wrappedValue = "draft target"
        editor.removeRule(id: rule.id)

        // These emulate delayed AppKit text-field reads/writes after SwiftUI
        // has removed the row. They must not access a stale array index or
        // recreate the deleted draft rule.
        XCTAssertEqual(source.wrappedValue, "")
        XCTAssertEqual(target.wrappedValue, "")
        source.wrappedValue = "must stay deleted"
        target.wrappedValue = "must stay deleted"
        XCTAssertTrue(editor.rules.isEmpty)
    }

    func testBindingsFollowIDsWhenRowsBeforeOrAtTheirRuleAreRemoved() {
        let editor = DictionaryEditorModel(fileURL: dictionaryURL)
        editor.loadIfNeeded()
        let first = DictionaryRule(source: "first", target: "one")
        let middle = DictionaryRule(source: "middle", target: "two")
        let last = DictionaryRule(source: "last", target: "three")
        editor.rules = [first, middle, last]

        let middleTarget = editor.textBinding(for: middle, field: \DictionaryRule.target)
        let lastTarget = editor.textBinding(for: last, field: \DictionaryRule.target)
        editor.removeRule(id: first.id)
        middleTarget.wrappedValue = "middle changed"

        XCTAssertEqual(editor.rules.map(\.id), [middle.id, last.id])
        XCTAssertEqual(editor.rules[0].target, "middle changed")
        XCTAssertEqual(editor.rules[1].target, "three")

        editor.removeRule(id: middle.id)
        middleTarget.wrappedValue = "must not overwrite last"
        lastTarget.wrappedValue = "last changed"

        XCTAssertEqual(editor.rules.map(\.id), [last.id])
        XCTAssertEqual(editor.rules[0].target, "last changed")
    }

    func testBindingsFromBeforeReloadCannotMutateReplacementRules() throws {
        let url = dictionaryURL
        try "old -> value\n".write(to: url, atomically: true, encoding: .utf8)
        let editor = DictionaryEditorModel(fileURL: url)
        editor.loadIfNeeded()
        let oldRule = try XCTUnwrap(editor.rules.first)
        let oldTarget = editor.textBinding(for: oldRule, field: \DictionaryRule.target)

        try "new -> replacement\n".write(to: url, atomically: true, encoding: .utf8)
        editor.reload()
        oldTarget.wrappedValue = "must not write into new"

        XCTAssertEqual(oldTarget.wrappedValue, "value")
        XCTAssertEqual(editor.rules.map(\.source), ["new"])
        XCTAssertEqual(editor.rules.map(\.target), ["replacement"])
        XCTAssertNotEqual(editor.rules[0].id, oldRule.id)
    }

    func testNativeTextFieldCanFinishEditingAfterItsUnsavedRowIsDeleted() async throws {
        let editor = DictionaryEditorModel(fileURL: dictionaryURL)
        editor.loadIfNeeded()
        let rule = DictionaryRule(source: "unsaved native field", target: "replacement")
        editor.rules = [rule]
        let hosting = NSHostingView(rootView: DictionaryRulesEditorView(editor: editor) { EmptyView() })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 650),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(180))
        hosting.layoutSubtreeIfNeeded()

        func editableFields(in view: NSView) -> [NSTextField] {
            let own = (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
            return own + view.subviews.flatMap(editableFields)
        }
        func editableTextViews(in view: NSView) -> [NSTextView] {
            let own = (view as? NSTextView).map { $0.isEditable ? [$0] : [] } ?? []
            return own + view.subviews.flatMap(editableTextViews)
        }
        // Check the native multiline preview input, not just its SwiftUI
        // declaration: it starts empty, aligns left, and updates the result.
        let preview = try XCTUnwrap(editableTextViews(in: hosting).first)
        XCTAssertEqual(preview.string, "")
        XCTAssertTrue(window.makeFirstResponder(preview))
        preview.insertText(rule.source, replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(editor.previewInput, rule.source)
        XCTAssertEqual(editor.previewOutput, rule.target)
        // SwiftUI may store .natural alignment. Verify the rendered caret
        // positions for LTR text rather than requiring one internal enum value.
        let firstCaret = preview.firstRect(
            forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil
        )
        let nextCaret = preview.firstRect(
            forCharacterRange: NSRange(location: 1, length: 0), actualRange: nil
        )
        let textBoundsOnScreen = window.convertToScreen(preview.convert(preview.bounds, to: nil))
        XCTAssertGreaterThanOrEqual(firstCaret.minX - textBoundsOnScreen.minX, 0)
        XCTAssertLessThan(firstCaret.minX - textBoundsOnScreen.minX, 24)
        XCTAssertGreaterThan(nextCaret.minX, firstCaret.minX)

        let field = try XCTUnwrap(editableFields(in: hosting).first {
            $0.stringValue == rule.source
        })
        XCTAssertTrue(window.makeFirstResponder(field))
        editor.removeRule(id: rule.id)
        // Exercise the actual AppKit field-editor teardown, where the crash
        // report showed SwiftUI trying to read a removed array element.
        window.makeFirstResponder(nil)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(editor.rules.isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: dictionaryURL.path))
    }

    private var dictionaryURL: URL {
        temporaryDirectory.appendingPathComponent("dictionary.txt")
    }
}
