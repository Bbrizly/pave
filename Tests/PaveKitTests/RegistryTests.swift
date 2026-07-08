import XCTest
@testable import PaveKit

final class RegistryTests: XCTestCase {
    private let cmdShift = ModMask.command | ModMask.shift

    private func macro(_ name: String, context: String? = nil,
                       key: String = "r", mods: [String] = ["cmd", "shift"],
                       enabled: Bool = true, steps: [Step] = [.delay(ms: 1)]) -> Macro {
        Macro(name: name, enabled: enabled, context: context,
              hotkey: Hotkey(key: key, mods: mods), steps: steps)
    }

    func testGlobalMatch() {
        let reg = Registry(macros: [macro("G")])
        let hit = reg.match(keyCode: 15, mods: cmdShift, frontApp: "com.apple.Safari")
        XCTAssertEqual(hit?.name, "G")
    }

    func testAppContextBeatsGlobal() {
        let reg = Registry(macros: [
            macro("G"),
            macro("X", context: "com.apple.dt.Xcode"),
        ])
        XCTAssertEqual(reg.match(keyCode: 15, mods: cmdShift, frontApp: "com.apple.dt.Xcode")?.name, "X")
        XCTAssertEqual(reg.match(keyCode: 15, mods: cmdShift, frontApp: "com.apple.Safari")?.name, "G")
        XCTAssertEqual(reg.match(keyCode: 15, mods: cmdShift, frontApp: nil)?.name, "G")
    }

    func testNoMatchOnDifferentMods() {
        let reg = Registry(macros: [macro("G")])
        XCTAssertNil(reg.match(keyCode: 15, mods: ModMask.command, frontApp: nil))
        XCTAssertNil(reg.match(keyCode: 15, mods: 0, frontApp: nil))
    }

    func testDisabledExcluded() {
        let reg = Registry(macros: [macro("G", enabled: false)])
        XCTAssertNil(reg.match(keyCode: 15, mods: cmdShift, frontApp: nil))
    }

    func testUnknownStepsExcluded() {
        let reg = Registry(macros: [macro("G", steps: [.unknown(type: "teleport")])])
        XCTAssertNil(reg.match(keyCode: 15, mods: cmdShift, frontApp: nil))
    }

    func testConflictDetected() {
        let reg = Registry(macros: [macro("A"), macro("B")])
        XCTAssertEqual(reg.conflicts.count, 1)
        XCTAssertTrue(reg.conflicts[0].contains("A") || reg.conflicts[0].contains("B"))
        // First one in still fires.
        XCTAssertNotNil(reg.match(keyCode: 15, mods: cmdShift, frontApp: nil))
    }

    func testNoConflictAcrossContexts() {
        let reg = Registry(macros: [macro("G"), macro("X", context: "com.apple.dt.Xcode")])
        XCTAssertTrue(reg.conflicts.isEmpty)
    }

    func testLookupIsFast() {
        var macros: [Macro] = []
        for i in 0 ..< 200 {
            macros.append(macro("M\(i)", context: "app.\(i)", key: "k"))
        }
        let reg = Registry(macros: macros)
        measure {
            for _ in 0 ..< 100_000 {
                _ = reg.match(keyCode: 40, mods: cmdShift, frontApp: "app.7")
            }
        }
    }
}
