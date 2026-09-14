import AppKit
import AudioCommon
import XCTest
@testable import HushType

@MainActor
final class ProcessingProfileTests: XCTestCase {
    func testApplicationInputWithoutSelectionIsValidButHasNoCaptureSource() throws {
        var profile = ProcessingProfile(name: "No application yet")
        profile.input.kind = .application
        profile.input.bundleID = "   "
        profile.input.applicationName = "Stale display name"

        let validated = try profile.validated()

        XCTAssertEqual(validated.input.kind, .application)
        XCTAssertEqual(validated.input.bundleID, "")
        XCTAssertEqual(validated.input.applicationName, "")
        XCTAssertFalse(validated.input.hasCaptureSource)

        var microphone = ProcessingProfile.Input()
        XCTAssertTrue(microphone.hasCaptureSource)
        microphone.kind = .application
        microphone.bundleID = "example.audio"
        XCTAssertTrue(microphone.hasCaptureSource)
    }

    func testStoreSavesAndReloadsApplicationInputWithoutSelection() throws {
        let fixture = try ProfileFixture()
        defer { fixture.finish() }
        let original = try XCTUnwrap(fixture.store.selected(.dictation))
        fixture.store.edit(original)
        fixture.store.draft?.input.kind = .application
        fixture.store.draft?.input.bundleID = ""
        fixture.store.draft?.input.applicationName = ""

        XCTAssertTrue(fixture.store.save())
        XCTAssertNil(fixture.store.errorMessage)

        let reloaded = ProcessingProfileStore(directory: fixture.root, defaults: fixture.defaults)
        let saved = try XCTUnwrap(reloaded.profiles.first { $0.id == original.id })
        XCTAssertEqual(saved.input.kind, .application)
        XCTAssertEqual(saved.input.bundleID, "")
        XCTAssertFalse(saved.input.hasCaptureSource)
        XCTAssertNil(reloaded.errorMessage)
    }

    func testEmptyApplicationSourceStopsBeforeScreenCaptureSetup() async {
        do {
            try await SystemAudioSource(bundleID: "   ").start()
            XCTFail("An empty application source must not begin capture")
        } catch SystemAudioError.noApplicationSelected {
            // This error is thrown before the first ScreenCaptureKit call,
            // which also keeps the permission flow untouched.
        } catch {
            XCTFail("Unexpected empty-source error: \(error)")
        }
    }

    func testLegacyDictionaryBooleanMigratesAndNewJSONOnlyEncodesIDs() throws {
        let id = UUID()
        let trueJSON = profileJSON(id: id, dictionary: true)
        let falseJSON = profileJSON(id: id, dictionary: false)

        let enabled = try JSONDecoder().decode(ProcessingProfile.self, from: trueJSON)
        let disabled = try JSONDecoder().decode(ProcessingProfile.self, from: falseJSON)
        XCTAssertEqual(enabled.rules.dictionaryIDs, [DictionaryLibraryStore.defaultID])
        XCTAssertTrue(enabled.rules.dictionary)
        XCTAssertEqual(disabled.rules.dictionaryIDs, [])
        XCTAssertFalse(disabled.rules.dictionary)

        let encoded = try JSONEncoder().encode(enabled)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let rules = try XCTUnwrap(object["rules"] as? [String: Any])
        XCTAssertNil(rules["dictionary"])
        XCTAssertEqual(rules["dictionaryIDs"] as? [String], [DictionaryLibraryStore.defaultID.uuidString])
        XCTAssertEqual(try JSONDecoder().decode(ProcessingProfile.self, from: encoded), enabled)
    }

    func testZeroOneAndMultipleLibrariesUseCanonicalMergeOrder() throws {
        let fixture = try DictionarySnapshotFixture()
        defer { fixture.finish() }
        let store = fixture.store
        let first = try XCTUnwrap(store.create(name: "First"))
        let second = try XCTUnwrap(store.create(name: "Second"))
        try "same -> first\nshort -> one\n".write(to: store.fileURL(for: first.id), atomically: true, encoding: .utf8)
        try "same -> second\nshort phrase -> longest\nfirst -> cascaded\n".write(
            to: store.fileURL(for: second.id), atomically: true, encoding: .utf8
        )

        var profile = ProcessingProfile(name: "Libraries")
        profile.rules.dictionaryIDs = []
        XCTAssertEqual(fixture.snapshot(profile).applyRules("same short phrase"), "same short phrase")

        profile.rules.dictionaryIDs = [second.id]
        XCTAssertEqual(fixture.snapshot(profile).applyRules("same short phrase"), "second longest")

        // Selection order is intentionally reversed. Store creation order is
        // canonical, so First wins the equal-length duplicate; the longer rule
        // in Second still wins, and replacement output does not cascade.
        profile.rules.dictionaryIDs = [second.id, first.id]
        XCTAssertEqual(fixture.snapshot(profile).applyRules("same short phrase"), "first longest")
    }

    func testMultiLibrarySnapshotFreezesFilesAndSelection() throws {
        let fixture = try DictionarySnapshotFixture()
        defer { fixture.finish() }
        let store = fixture.store
        let first = try XCTUnwrap(store.create(name: "First"))
        let second = try XCTUnwrap(store.create(name: "Second"))
        try "alpha -> old\n".write(to: store.fileURL(for: first.id), atomically: true, encoding: .utf8)
        try "beta -> selected\n".write(to: store.fileURL(for: second.id), atomically: true, encoding: .utf8)
        var profile = ProcessingProfile(name: "Frozen")
        profile.rules.dictionaryIDs = [first.id]

        let snapshot = fixture.snapshot(profile)
        try "alpha -> new\n".write(to: store.fileURL(for: first.id), atomically: true, encoding: .utf8)
        profile.rules.dictionaryIDs = [second.id]

        XCTAssertEqual(snapshot.applyRules("alpha beta"), "old beta")
        XCTAssertEqual(fixture.snapshot(profile).applyRules("alpha beta"), "alpha selected")
    }

    func testDeletedLibraryReferenceIsRemovedWithoutChangingDraftOrRunningSnapshot() throws {
        let fixture = try ProfileFixture()
        defer { fixture.finish() }
        let original = try XCTUnwrap(fixture.store.selected(.dictation))
        let dictionary = fixture.root.appendingPathComponent("dictionary.txt")
        try "alpha -> frozen\n".write(to: dictionary, atomically: true, encoding: .utf8)
        let snapshot = ProcessingProfileSnapshot(profile: original, dictionaryURL: dictionary)
        fixture.store.edit(original)
        fixture.store.draft?.name = "Unsaved name"

        XCTAssertTrue(fixture.store.removeDictionaryReference(DictionaryLibraryStore.defaultID))

        XCTAssertEqual(fixture.store.draft?.name, "Unsaved name")
        XCTAssertFalse(fixture.store.draft?.rules.dictionaryIDs.contains(DictionaryLibraryStore.defaultID) == true)
        XCTAssertTrue(fixture.store.profiles.allSatisfy {
            !$0.rules.dictionaryIDs.contains(DictionaryLibraryStore.defaultID)
        })
        XCTAssertEqual(snapshot.applyRules("alpha"), "frozen")
        XCTAssertTrue(fixture.store.save())
        let reloaded = ProcessingProfileStore(directory: fixture.root, defaults: fixture.defaults)
        XCTAssertTrue(reloaded.profiles.allSatisfy {
            !$0.rules.dictionaryIDs.contains(DictionaryLibraryStore.defaultID)
        })
    }

    func testDictionaryReferenceCleanupPreservesExternalProfileConflict() throws {
        let fixture = try ProfileFixture()
        defer { fixture.finish() }
        let profile = try XCTUnwrap(fixture.store.profiles.first)
        var external = profile
        external.name = "External"
        let externalData = try JSONEncoder().encode(external)
        try externalData.write(to: fixture.file(profile.id), options: .atomic)

        XCTAssertFalse(fixture.store.removeDictionaryReference(DictionaryLibraryStore.defaultID))
        XCTAssertNotNil(fixture.store.errorMessage)
        XCTAssertEqual(try Data(contentsOf: fixture.file(profile.id)), externalData)
        XCTAssertTrue(fixture.store.profiles.allSatisfy {
            $0.rules.dictionaryIDs.contains(DictionaryLibraryStore.defaultID)
        })
    }

    func testSaveReloadAndIndependentSelections() throws {
        let fixture = try ProfileFixture()
        defer { fixture.finish() }
        let store = fixture.store
        let first = try XCTUnwrap(store.selected(.dictation))
        let second = try XCTUnwrap(store.selected(.captions))
        XCTAssertNotEqual(first.id, second.id)
        store.select(first.id, for: .captions)
        store.edit(first)
        store.draft?.name = "Edited configuration"
        store.draft?.llm.correction = .light
        store.draft?.llm.translate = true
        store.draft?.llm.target = "english"
        XCTAssertTrue(store.save())
        let reloaded = ProcessingProfileStore(directory: fixture.root, defaults: fixture.defaults)
        XCTAssertNil(reloaded.errorMessage)
        XCTAssertEqual(reloaded.selected(.dictation)?.name, "Edited configuration")
        XCTAssertEqual(reloaded.selected(.dictation), reloaded.selected(.captions))
        XCTAssertEqual(reloaded.selected(.dictation)?.llm.correction, .light)
        XCTAssertEqual(reloaded.selected(.dictation)?.llm.target, "english")
    }

    func testDraftNeverChangesRunningSnapshotOrSelectedSavedProfile() throws {
        let fixture = try ProfileFixture()
        defer { fixture.finish() }
        let original = try XCTUnwrap(fixture.store.selected(.dictation))
        let dictionary = fixture.root.appendingPathComponent("dictionary.txt")
        try "alpha -> beta\n".write(to: dictionary, atomically: true, encoding: .utf8)
        let snapshot = ProcessingProfileSnapshot(profile: original, dictionaryURL: dictionary)
        fixture.store.edit(original)
        fixture.store.draft?.name = "Future"
        fixture.store.draft?.rules.dictionary = false
        XCTAssertEqual(fixture.store.selected(.dictation)?.name, original.name)
        XCTAssertTrue(fixture.store.save())
        try "alpha -> gamma\n".write(to: dictionary, atomically: true, encoding: .utf8)
        XCTAssertEqual(snapshot.profile.name, original.name)
        XCTAssertEqual(snapshot.applyRules("alpha"), "beta")
        let next = ProcessingProfileSnapshot(profile: try XCTUnwrap(fixture.store.selected(.dictation)), dictionaryURL: dictionary)
        XCTAssertEqual(next.profile.name, "Future")
        XCTAssertEqual(next.applyRules("alpha"), "alpha")
    }

    func testDuplicateGetsNewIdentityAndDeletionUsesTrash() throws {
        let fixture = try ProfileFixture()
        defer { fixture.finish() }
        let original = try XCTUnwrap(fixture.store.selected(.dictation))
        fixture.store.delete(original)
        XCTAssertNil(fixture.store.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file(original.id).path))
        fixture.store.create(copying: original)
        let copy = try XCTUnwrap(fixture.store.draft)
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.rules, original.rules)
        XCTAssertTrue(fixture.store.save())
        fixture.store.cancelEditing()
        fixture.store.delete(copy)
        XCTAssertNil(fixture.store.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file(copy.id).path))
        let trashed = fixture.root.appendingPathComponent("trash/" + copy.id.uuidString + ".json")
        XCTAssertEqual(try JSONDecoder().decode(ProcessingProfile.self, from: Data(contentsOf: trashed)).id, copy.id)
    }

    func testExternalEditConflictDoesNotOverwriteFile() throws {
        let fixture = try ProfileFixture()
        defer { fixture.finish() }
        let original = try XCTUnwrap(fixture.store.selected(.dictation))
        fixture.store.edit(original)
        fixture.store.draft?.name = "Local edit"
        var external = original; external.name = "External edit"
        let data = try JSONEncoder().encode(external)
        try data.write(to: fixture.file(original.id), options: .atomic)
        XCTAssertFalse(fixture.store.save())
        XCTAssertEqual(try Data(contentsOf: fixture.file(original.id)), data)
        fixture.store.cancelEditing()
        fixture.store.edit(original)
        XCTAssertEqual(fixture.store.draft?.name, "External edit")
        XCTAssertEqual(fixture.store.selected(.dictation)?.name, "External edit")
    }

    func testCorruptFileIsPreservedAndInvalidDraftIsNotSaved() throws {
        let fixture = try ProfileFixture()
        defer { fixture.finish() }
        let corrupt = fixture.root.appendingPathComponent("broken.json")
        let bytes = Data("broken".utf8)
        try bytes.write(to: corrupt)
        let reloaded = ProcessingProfileStore(directory: fixture.root, defaults: fixture.defaults)
        XCTAssertNotNil(reloaded.errorMessage)
        XCTAssertEqual(try Data(contentsOf: corrupt), bytes)
        fixture.store.create()
        fixture.store.draft?.name = "   "
        let id = try XCTUnwrap(fixture.store.draft?.id)
        XCTAssertFalse(fixture.store.save())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file(id).path))
    }

    func testRuleCleanupThenConfiguredPolishThenTranslation() async throws {
        let fixture = try ProfileFixture()
        defer { fixture.finish() }
        let dictionary = fixture.root.appendingPathComponent("dictionary.txt")
        try "alpha -> beta\n".write(to: dictionary, atomically: true, encoding: .utf8)
        var profile = try XCTUnwrap(fixture.store.selected(.dictation))
        profile.llm.polish = true; profile.llm.correction = .light
        profile.llm.translate = true; profile.llm.target = "english"
        let requests = ProfileRequestRecorder()
        let snapshot = ProcessingProfileSnapshot(profile: profile, dictionaryURL: dictionary)
        let output = try await snapshot.process("alpha") { request in await requests.run(request) }
        XCTAssertEqual(output, "translated")
        let recorded = await requests.requests
        XCTAssertEqual(recorded, [.polish("beta", level: .light), .translate("polished", target: .english)])
        profile.llm.polish = false; profile.llm.translate = false
        let off = ProcessingProfileSnapshot(profile: profile, dictionaryURL: dictionary)
        let plain = try await off.process("alpha") { _ in XCTFail("Disabled LLM must not run"); return "" }
        XCTAssertEqual(plain, "beta")
    }

    func testDifferentProfilesWithSameAppSourceReuseCaptureOwnership() {
        var first = ProcessingProfile.Input(); first.kind = .application; first.bundleID = "example.audio.one"
        var second = first; second.applicationName = "A different display label"
        XCTAssertTrue(AudioCaptureService.shared(for: first) === AudioCaptureService.shared(for: second))
        second.bundleID = "example.audio.two"
        XCTAssertFalse(AudioCaptureService.shared(for: first) === AudioCaptureService.shared(for: second))
    }

    func testProfileRuntimeWithCachedSpeechAndTextModels() async throws {
        guard let path = ProcessInfo.processInfo.environment["HUSHTYPE_PROFILE_RUNTIME_WAV"] else {
            throw XCTSkip("Set HUSHTYPE_PROFILE_RUNTIME_WAV for the opt-in local runtime test")
        }
        guard let descriptor = LocalModelCatalog.descriptor(for: AppConfig.shared.modelId), LocalModelCatalog.isInstalled(descriptor) else {
            throw XCTSkip("Cached speech weights are required")
        }
        let service = try LocalTextResources.service.get()
        guard case .installed = await service.status().installation else { throw XCTSkip("Cached text weights are required") }
        let (samples, rate) = try AudioFileLoader.loadWAV(url: URL(fileURLWithPath: path))
        let audio = rate == 16000 ? samples : AudioFileLoader.resample(samples, from: rate, to: 16000)
        let engine = Qwen3TranscriptionEngine()
        try await engine.load(progressHandler: nil)
        do {
            let raw = try await engine.transcribeRaw(audio: audio, language: "english", client: .dictation)
            var profile = ProcessingProfile(name: "Runtime")
            profile.input.kind = .application; profile.input.bundleID = "example.fixture"
            profile.llm.polish = true; profile.llm.correction = .light; profile.llm.translate = true
            let output = try await ProcessingProfileSnapshot(profile: profile).process(raw)
            XCTAssertFalse(raw.isEmpty); XCTAssertFalse(output.isEmpty)
            XCTAssertNotNil(output.range(of: "\\p{Han}", options: .regularExpression))
            print("Profile runtime source: \(raw)\nProfile runtime translated result: \(output)")
        } catch {
            await engine.unloadAndWait(); await service.unload(); throw error
        }
        await engine.unloadAndWait(); await service.unload()
    }

    private func profileJSON(id: UUID, dictionary: Bool) -> Data {
        Data("""
        {
          "schemaVersion": 1,
          "id": "\(id.uuidString)",
          "name": "Legacy",
          "input": {
            "kind": "microphone",
            "device": "followSystem",
            "bundleID": "",
            "applicationName": ""
          },
          "modelID": "\(AppConfig.defaultModelId)",
          "language": "auto",
          "rules": {
            "numbers": true,
            "traditionalChinese": false,
            "dictionary": \(dictionary),
            "punctuation": "soft"
          },
          "llm": {
            "polish": false,
            "polishBackend": "qwen",
            "correction": "standard",
            "translate": false,
            "translationBackend": "qwen",
            "target": "simplifiedChinese"
          }
        }
        """.utf8)
    }
}

private actor ProfileRequestRecorder {
    var requests: [LocalTextRequest] = []
    func run(_ request: LocalTextRequest) -> String {
        requests.append(request)
        if case .polish = request { return "polished" }
        return "translated"
    }
}

@MainActor
private final class ProfileFixture {
    let root: URL
    let defaults: UserDefaults
    let suite = "HushType.ProfileTests." + UUID().uuidString
    let store: ProcessingProfileStore
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("HushType.Profiles." + UUID().uuidString)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        var first = ProcessingProfile(name: "First")
        first.input.kind = .application; first.input.bundleID = "example.test.audio"
        var second = first; second.id = UUID(); second.name = "Second"
        let trashDirectory = root.appendingPathComponent("trash")
        store = ProcessingProfileStore(directory: root, defaults: defaults, seedProfiles: [first, second], trash: { file in
            try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file, to: trashDirectory.appendingPathComponent(file.lastPathComponent))
        })
        XCTAssertNil(store.errorMessage)
    }
    func file(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".json") }
    func finish() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.trashItem(at: root, resultingItemURL: nil)
    }
}

@MainActor
private final class DictionarySnapshotFixture {
    let root: URL
    let legacyURL: URL
    let libraryDirectory: URL
    let store: DictionaryLibraryStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HushType.DictionarySnapshots." + UUID().uuidString, isDirectory: true)
        legacyURL = root.appendingPathComponent("dictionary.txt")
        libraryDirectory = root.appendingPathComponent("dictionaries", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = DictionaryLibraryStore(
            directory: libraryDirectory,
            legacyDictionaryURL: legacyURL,
            trash: { _ in XCTFail("Snapshot tests do not delete libraries") }
        )
        XCTAssertNil(store.errorMessage)
    }

    func snapshot(_ profile: ProcessingProfile) -> ProcessingProfileSnapshot {
        ProcessingProfileSnapshot(
            profile: profile,
            dictionaryURL: legacyURL,
            dictionaryLibraryDirectory: libraryDirectory
        )
    }

    func finish() {
        try? FileManager.default.trashItem(at: root, resultingItemURL: nil)
    }
}
