import Foundation

public enum WindowAction: String, Codable, CaseIterable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case thirdLeft, thirdCenter, thirdRight
    case maximize, nextDisplay
}

public enum SystemAction: String, Codable, CaseIterable {
    case volumeUp, volumeDown, muteToggle, micMuteToggle
    case brightnessUp, brightnessDown, darkModeToggle, screenRecordToggle
}

public enum Step: Equatable {
    case app(bundleId: String)
    case open(target: String)
    case text(string: String, restoreClipboard: Bool)
    case keys(key: String, mods: [String])
    case shell(script: String, timeoutSec: Double, toast: Bool)
    case window(WindowAction)
    case system(SystemAction)
    case delay(ms: Int)
    case unknown(type: String)

    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }
}

extension Step: Codable {
    enum K: String, CodingKey {
        case type, bundleId, target, string, restoreClipboard
        case key, mods, script, timeoutSec, toast, action, ms
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let t = try c.decode(String.self, forKey: .type)
        switch t {
        case "app":
            self = .app(bundleId: try c.decode(String.self, forKey: .bundleId))
        case "open":
            self = .open(target: try c.decode(String.self, forKey: .target))
        case "text":
            self = .text(
                string: try c.decode(String.self, forKey: .string),
                restoreClipboard: try c.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? true)
        case "keys":
            self = .keys(
                key: try c.decode(String.self, forKey: .key),
                mods: try c.decodeIfPresent([String].self, forKey: .mods) ?? [])
        case "shell":
            self = .shell(
                script: try c.decode(String.self, forKey: .script),
                timeoutSec: try c.decodeIfPresent(Double.self, forKey: .timeoutSec) ?? 10,
                toast: try c.decodeIfPresent(Bool.self, forKey: .toast) ?? true)
        case "window":
            if let raw = try c.decodeIfPresent(String.self, forKey: .action),
               let a = WindowAction(rawValue: raw) {
                self = .window(a)
            } else {
                self = .unknown(type: "window:bad-action")
            }
        case "system":
            if let raw = try c.decodeIfPresent(String.self, forKey: .action),
               let a = SystemAction(rawValue: raw) {
                self = .system(a)
            } else {
                self = .unknown(type: "system:bad-action")
            }
        case "delay":
            self = .delay(ms: try c.decode(Int.self, forKey: .ms))
        default:
            self = .unknown(type: t)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .app(let b):
            try c.encode("app", forKey: .type)
            try c.encode(b, forKey: .bundleId)
        case .open(let t):
            try c.encode("open", forKey: .type)
            try c.encode(t, forKey: .target)
        case .text(let s, let r):
            try c.encode("text", forKey: .type)
            try c.encode(s, forKey: .string)
            try c.encode(r, forKey: .restoreClipboard)
        case .keys(let k, let m):
            try c.encode("keys", forKey: .type)
            try c.encode(k, forKey: .key)
            try c.encode(m, forKey: .mods)
        case .shell(let s, let t, let toast):
            try c.encode("shell", forKey: .type)
            try c.encode(s, forKey: .script)
            try c.encode(t, forKey: .timeoutSec)
            try c.encode(toast, forKey: .toast)
        case .window(let a):
            try c.encode("window", forKey: .type)
            try c.encode(a.rawValue, forKey: .action)
        case .system(let a):
            try c.encode("system", forKey: .type)
            try c.encode(a.rawValue, forKey: .action)
        case .delay(let ms):
            try c.encode("delay", forKey: .type)
            try c.encode(ms, forKey: .ms)
        case .unknown(let t):
            try c.encode(t, forKey: .type)
        }
    }
}

public struct Hotkey: Codable, Equatable {
    public var key: String
    public var mods: [String]

    public init(key: String, mods: [String]) {
        self.key = key
        self.mods = mods
    }

    public var display: String {
        let symbols = mods.map { m -> String in
            switch m.lowercased() {
            case "cmd", "command": return "\u{2318}"
            case "shift": return "\u{21E7}"
            case "opt", "option", "alt": return "\u{2325}"
            case "ctrl", "control": return "\u{2303}"
            default: return "?"
            }
        }.joined()
        return symbols + key.uppercased()
    }
}

public struct Macro: Codable, Identifiable, Equatable {
    public var v: Int
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var context: String?
    public var hotkey: Hotkey?
    public var steps: [Step]

    public init(id: UUID = UUID(), name: String, enabled: Bool = true,
                context: String? = nil, hotkey: Hotkey? = nil, steps: [Step] = []) {
        self.v = 1
        self.id = id
        self.name = name
        self.enabled = enabled
        self.context = context
        self.hotkey = hotkey
        self.steps = steps
    }

    enum CodingKeys: String, CodingKey { case v, id, name, enabled, context, hotkey, steps }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        context = try c.decodeIfPresent(String.self, forKey: .context)
        hotkey = try c.decodeIfPresent(Hotkey.self, forKey: .hotkey)
        steps = try c.decodeIfPresent([Step].self, forKey: .steps) ?? []
    }

    public var hasUnknownSteps: Bool { steps.contains { $0.isUnknown } }
}

public struct RingSlice: Codable, Equatable {
    public var label: String
    public var macro: UUID?
    public var submenu: [RingSlice]?
    /// SF Symbol name. Nil = agent derives one from the macro's first step.
    public var icon: String?

    public init(label: String, macro: UUID? = nil, submenu: [RingSlice]? = nil, icon: String? = nil) {
        self.label = label
        self.macro = macro
        self.submenu = submenu
        self.icon = icon
    }

    enum CodingKeys: String, CodingKey { case label, macro, submenu, icon }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        macro = try c.decodeIfPresent(UUID.self, forKey: .macro)
        submenu = try c.decodeIfPresent([RingSlice].self, forKey: .submenu)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
    }
}

public struct Settings: Codable, Equatable {
    public var holdKeyCode: Int
    public var releaseToFire: Bool
    public var tickSound: Bool

    public init(holdKeyCode: Int = 54, releaseToFire: Bool = true, tickSound: Bool = true) {
        self.holdKeyCode = holdKeyCode
        self.releaseToFire = releaseToFire
        self.tickSound = tickSound
    }

    enum CodingKeys: String, CodingKey { case holdKeyCode, releaseToFire, tickSound }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        holdKeyCode = try c.decodeIfPresent(Int.self, forKey: .holdKeyCode) ?? 54
        releaseToFire = try c.decodeIfPresent(Bool.self, forKey: .releaseToFire) ?? true
        tickSound = try c.decodeIfPresent(Bool.self, forKey: .tickSound) ?? true
    }
}
