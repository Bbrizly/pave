import Foundation

public struct HotkeyKey: Hashable {
    public let keyCode: Int
    public let mods: UInt64
    public let context: String?

    public init(keyCode: Int, mods: UInt64, context: String?) {
        self.keyCode = keyCode
        self.mods = mods
        self.context = context
    }
}

/// Flat O(1) lookup from (keycode, mods, front app) to macro.
/// Rebuilt whole on reload; the tap callback only ever reads.
public final class Registry {
    private var map: [HotkeyKey: Macro] = [:]
    public private(set) var conflicts: [String] = []

    public init() {}

    public init(macros: [Macro]) {
        rebuild(from: macros)
    }

    public func rebuild(from macros: [Macro]) {
        map = [:]
        conflicts = []
        for m in macros where m.enabled && !m.hasUnknownSteps {
            guard let hk = m.hotkey, let code = KeyCodes.code(for: hk.key) else { continue }
            let key = HotkeyKey(keyCode: code, mods: ModMask.mask(from: hk.mods), context: m.context)
            if let existing = map[key] {
                let scope = m.context ?? "global"
                conflicts.append("\(m.name) and \(existing.name) both bind \(hk.display) (\(scope))")
            } else {
                map[key] = m
            }
        }
    }

    public func match(keyCode: Int, mods: UInt64, frontApp: String?) -> Macro? {
        if let app = frontApp,
           let m = map[HotkeyKey(keyCode: keyCode, mods: mods, context: app)] {
            return m
        }
        return map[HotkeyKey(keyCode: keyCode, mods: mods, context: nil)]
    }
}
