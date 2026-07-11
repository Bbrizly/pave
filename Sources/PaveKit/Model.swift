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
    case moveFile(matcher: FileMatcher, destination: String, overwrite: Bool)
    case renameFile(matcher: FileMatcher, nameTemplate: String)
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
        case matcher, destination, overwrite, nameTemplate
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
        case "moveFile":
            // Missing matcher or destination means a malformed variant. Load as
            // .unknown so the macro disables instead of running a half step.
            guard let matcher = try? c.decode(FileMatcher.self, forKey: .matcher),
                  let destination = try? c.decode(String.self, forKey: .destination) else {
                self = .unknown(type: "moveFile:malformed")
                break
            }
            self = .moveFile(
                matcher: matcher,
                destination: destination,
                overwrite: try c.decodeIfPresent(Bool.self, forKey: .overwrite) ?? false)
        case "renameFile":
            guard let matcher = try? c.decode(FileMatcher.self, forKey: .matcher),
                  let nameTemplate = try? c.decode(String.self, forKey: .nameTemplate) else {
                self = .unknown(type: "renameFile:malformed")
                break
            }
            self = .renameFile(matcher: matcher, nameTemplate: nameTemplate)
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
        case .moveFile(let matcher, let destination, let overwrite):
            try c.encode("moveFile", forKey: .type)
            try c.encode(matcher, forKey: .matcher)
            try c.encode(destination, forKey: .destination)
            try c.encode(overwrite, forKey: .overwrite)
        case .renameFile(let matcher, let nameTemplate):
            try c.encode("renameFile", forKey: .type)
            try c.encode(matcher, forKey: .matcher)
            try c.encode(nameTemplate, forKey: .nameTemplate)
        case .unknown(let t):
            try c.encode(t, forKey: .type)
        }
    }
}

/// Picks one file out of a folder. v1 only knows "newest", but `which` encodes
/// as a string so a future build can add cases without breaking old files.
public struct FileMatcher: Equatable {
    public enum Which: String, Codable { case newest }

    /// Tilde path to the folder to look in. One level, no recursion.
    public var folder: String
    /// Extension filter without the dot ("pdf"). Nil or empty means any file.
    public var ext: String?
    public var which: Which

    public init(folder: String, ext: String? = nil, which: Which = .newest) {
        self.folder = folder
        self.ext = ext
        self.which = which
    }
}

extension FileMatcher: Codable {
    enum K: String, CodingKey { case folder, ext = "extension", which }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        ext = try c.decodeIfPresent(String.self, forKey: .ext)
        let raw = try c.decodeIfPresent(String.self, forKey: .which) ?? "newest"
        which = Which(rawValue: raw) ?? .newest
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(folder, forKey: .folder)
        try c.encodeIfPresent(ext, forKey: .ext)
        try c.encode(which.rawValue, forKey: .which)
    }
}

/// Pure file-ritual logic for the moveFile and renameFile steps. Foundation
/// only, no AppKit, so it runs and tests on Linux too. It never deletes a
/// folder and never clobbers a file unless the caller opted into overwrite.
public enum FileOps {
    /// Expand a leading ~ to the home dir. Everything else is left alone.
    public static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Newest matching regular file (by modification date) directly inside the
    /// matcher's folder. One level, no recursion. Nil if nothing matches.
    public static func resolveNewest(_ matcher: FileMatcher) -> URL? {
        let dir = URL(fileURLWithPath: expand(matcher.folder))
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return nil }
        let wantExt = matcher.ext?
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            .lowercased()
        let files = items.filter { url in
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard vals?.isRegularFile == true else { return false }
            if let wantExt, !wantExt.isEmpty {
                return url.pathExtension.lowercased() == wantExt
            }
            return true
        }
        return files.max { mtime($0) < mtime($1) }
    }

    private static func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    /// "no .pdf in ~/Downloads" style tail for a clean error string.
    private static func matchLabel(_ matcher: FileMatcher) -> String {
        guard let e = matcher.ext, !e.isEmpty else { return "file" }
        return e.hasPrefix(".") ? e : "." + e
    }

    /// Move the matched file to `destination` (a tilde path). If destination is
    /// an existing folder the file keeps its name inside it. Fails cleanly on no
    /// match or a collision unless overwrite is true. Never replaces a folder.
    public static func runMove(_ matcher: FileMatcher, destination: String, overwrite: Bool) throws {
        guard let src = resolveNewest(matcher) else {
            throw RunError("moveFile: no \(matchLabel(matcher)) in \(matcher.folder)")
        }
        let fm = FileManager.default
        var dest = URL(fileURLWithPath: expand(destination))
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dest.path, isDirectory: &isDir), isDir.boolValue {
            dest = dest.appendingPathComponent(src.lastPathComponent)
        }
        if fm.fileExists(atPath: dest.path) {
            guard overwrite else {
                throw RunError("moveFile: \(dest.lastPathComponent) already exists in destination")
            }
            var destIsDir: ObjCBool = false
            _ = fm.fileExists(atPath: dest.path, isDirectory: &destIsDir)
            guard !destIsDir.boolValue else {
                throw RunError("moveFile: destination is a folder, refusing to replace it")
            }
            try fm.removeItem(at: dest)
        } else {
            try fm.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try fm.moveItem(at: src, to: dest)
        guard fm.fileExists(atPath: dest.path), !fm.fileExists(atPath: src.path) else {
            throw RunError("moveFile: move did not complete")
        }
    }

    /// Rename the matched file in place using the template. Fails cleanly on no
    /// match, or on a name collision when {n} was not part of the template.
    /// `now` feeds {date}/{month}; it is injectable so tests are deterministic.
    public static func runRename(_ matcher: FileMatcher, nameTemplate: String,
                                 now: Date = Date()) throws {
        guard let src = resolveNewest(matcher) else {
            throw RunError("renameFile: no \(matchLabel(matcher)) in \(matcher.folder)")
        }
        let fm = FileManager.default
        let dir = src.deletingLastPathComponent()
        let stem = src.deletingPathExtension().lastPathComponent
        let ext = src.pathExtension
        let (name, usedN) = renderTemplate(nameTemplate, stem: stem, ext: ext, dir: dir, today: now)
        let dest = dir.appendingPathComponent(name)
        if dest.path == src.path { return } // name unchanged, nothing to do
        if fm.fileExists(atPath: dest.path), !usedN {
            throw RunError("renameFile: \(name) already exists in \(matcher.folder)")
        }
        try fm.moveItem(at: src, to: dest)
        guard fm.fileExists(atPath: dest.path), !fm.fileExists(atPath: src.path) else {
            throw RunError("renameFile: rename did not complete")
        }
    }

    /// Resolve template tokens. {name} stem, {ext} extension, {date} yyyy-MM-dd,
    /// {month} MMMM yyyy, {n} smallest positive int that makes the name unique in
    /// dir. Unknown tokens are left literally. Returns (name, whether {n} ran).
    public static func renderTemplate(_ template: String, stem: String, ext: String,
                                      dir: URL, today: Date = Date()) -> (String, Bool) {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let date = df.string(from: today)
        df.dateFormat = "MMMM yyyy"
        let month = df.string(from: today)

        var s = template
        s = s.replacingOccurrences(of: "{name}", with: stem)
        s = s.replacingOccurrences(of: "{ext}", with: ext)
        s = s.replacingOccurrences(of: "{date}", with: date)
        s = s.replacingOccurrences(of: "{month}", with: month)

        guard s.contains("{n}") else { return (s, false) }
        let fm = FileManager.default
        // Bounded so a pathological folder cannot spin here. If every number in
        // range is taken, hand back the last try with usedN false: the caller's
        // collision guard then fails closed instead of moving onto a taken name.
        for n in 1...100_000 {
            let candidate = s.replacingOccurrences(of: "{n}", with: String(n))
            if !fm.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
                return (candidate, true)
            }
        }
        return (s.replacingOccurrences(of: "{n}", with: "100000"), false)
    }
}

/// Anchor metadata on a macro: "remind me when this trigger appears". It is
/// not a step, just a match rule the recall layer reads later. `kind` is a
/// PaveEventKind rawValue stored as a string so an older build tolerates a
/// kind it does not know. A malformed anchor decodes as nil, never a crash and
/// never a disabled macro, because an anchor is metadata not a step.
public struct AnchorSpec: Codable, Equatable, Sendable {
    /// PaveEventKind rawValue. String, not the enum, for forward compat.
    public var kind: String
    public var bundleID: String?
    /// Tilde path. Compared with tilde-expansion on both sides.
    public var folder: String?
    /// Extension without the dot. Compared case-insensitively.
    public var fileExtension: String?

    public init(kind: String, bundleID: String? = nil,
                folder: String? = nil, fileExtension: String? = nil) {
        self.kind = kind
        self.bundleID = bundleID
        self.folder = folder
        self.fileExtension = fileExtension
    }

    enum K: String, CodingKey { case kind, bundleID, folder, fileExtension }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        fileExtension = try c.decodeIfPresent(String.self, forKey: .fileExtension)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(bundleID, forKey: .bundleID)
        try c.encodeIfPresent(folder, forKey: .folder)
        try c.encodeIfPresent(fileExtension, forKey: .fileExtension)
    }

    /// True when the event matches this anchor. Kind must equal the event's
    /// kind rawValue. Each non-nil field must match its event counterpart; a
    /// nil field is a wildcard. Folders compare tilde-expanded, extension
    /// compares case-insensitively.
    public func matches(_ event: PaveEvent) -> Bool {
        guard kind == event.kind.rawValue else { return false }
        if let bundleID { guard bundleID == event.bundleID else { return false } }
        if let folder {
            let a = FileOps.expand(folder)
            let b = event.folder.map(FileOps.expand)
            guard a == b else { return false }
        }
        if let fileExtension {
            guard fileExtension.lowercased() == event.fileExtension?.lowercased() else { return false }
        }
        return true
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
    /// "Remind me when this trigger appears". Metadata, not a step. A bad
    /// anchor decodes as nil and never disables the macro.
    public var anchor: AnchorSpec?
    /// Opaque path key set by Pave's run-to-macro converter. Used later for
    /// run counting. Nil for hand-authored macros.
    public var paveOrigin: String?

    public init(id: UUID = UUID(), name: String, enabled: Bool = true,
                context: String? = nil, hotkey: Hotkey? = nil, steps: [Step] = [],
                anchor: AnchorSpec? = nil, paveOrigin: String? = nil) {
        self.v = 1
        self.id = id
        self.name = name
        self.enabled = enabled
        self.context = context
        self.hotkey = hotkey
        self.steps = steps
        self.anchor = anchor
        self.paveOrigin = paveOrigin
    }

    enum CodingKeys: String, CodingKey {
        case v, id, name, enabled, context, hotkey, steps, anchor, paveOrigin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        context = try c.decodeIfPresent(String.self, forKey: .context)
        hotkey = try c.decodeIfPresent(Hotkey.self, forKey: .hotkey)
        steps = try c.decodeIfPresent([Step].self, forKey: .steps) ?? []
        // A malformed anchor must never brick the macro. try? swallows a bad
        // shape and leaves the anchor nil; the rest of the macro loads fine.
        anchor = try? c.decodeIfPresent(AnchorSpec.self, forKey: .anchor)
        paveOrigin = try c.decodeIfPresent(String.self, forKey: .paveOrigin)
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

/// Menu-bar hand animation. Every knob is editable in the Settings pane; the
/// agent reads these live on reload. Idle/alert are static (minimal), working
/// animates the 12 hand frames. Mirrors the spec's §21b icon config.
public struct IconConfig: Codable, Equatable {
    /// Master switch. Off = fall back to the plain SF Symbol status icon.
    public var enabled: Bool
    /// Working-loop frame rate. Clamped 6...24 in the UI.
    public var workingFPS: Double
    /// If false, "working" shows a single static frame instead of animating.
    public var animateWorking: Bool
    /// On a state change mid-loop, finish the current loop before switching.
    public var finishFullLoop: Bool
    /// Draw a small badge dot on the alert (attention) state.
    public var showAlertDot: Bool
    /// "template" (monochrome, adapts to light/dark) or "color" (exact artwork).
    public var renderStyle: String
    /// Rendered icon height in points. Clamped 14...22 in the UI.
    public var pointHeight: Double
    /// Which frame the static idle/alert states show (0-based).
    public var idleFrameIndex: Int
    /// How long the Settings "Test" button plays working before settling to idle.
    public var testDurationSec: Double

    public init(enabled: Bool = true,
                workingFPS: Double = 15,
                animateWorking: Bool = true,
                finishFullLoop: Bool = true,
                showAlertDot: Bool = true,
                renderStyle: String = "template",
                pointHeight: Double = 18,
                idleFrameIndex: Int = 0,
                testDurationSec: Double = 3) {
        self.enabled = enabled
        self.workingFPS = workingFPS
        self.animateWorking = animateWorking
        self.finishFullLoop = finishFullLoop
        self.showAlertDot = showAlertDot
        self.renderStyle = renderStyle
        self.pointHeight = pointHeight
        self.idleFrameIndex = idleFrameIndex
        self.testDurationSec = testDurationSec
    }

    enum CodingKeys: String, CodingKey {
        case enabled, workingFPS, animateWorking, finishFullLoop, showAlertDot
        case renderStyle, pointHeight, idleFrameIndex, testDurationSec
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = IconConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        workingFPS = try c.decodeIfPresent(Double.self, forKey: .workingFPS) ?? d.workingFPS
        animateWorking = try c.decodeIfPresent(Bool.self, forKey: .animateWorking) ?? d.animateWorking
        finishFullLoop = try c.decodeIfPresent(Bool.self, forKey: .finishFullLoop) ?? d.finishFullLoop
        showAlertDot = try c.decodeIfPresent(Bool.self, forKey: .showAlertDot) ?? d.showAlertDot
        renderStyle = try c.decodeIfPresent(String.self, forKey: .renderStyle) ?? d.renderStyle
        pointHeight = try c.decodeIfPresent(Double.self, forKey: .pointHeight) ?? d.pointHeight
        idleFrameIndex = try c.decodeIfPresent(Int.self, forKey: .idleFrameIndex) ?? d.idleFrameIndex
        testDurationSec = try c.decodeIfPresent(Double.self, forKey: .testDurationSec) ?? d.testDurationSec
    }
}

public struct Settings: Codable, Equatable {
    public var holdKeyCode: Int
    public var releaseToFire: Bool
    public var tickSound: Bool

    /// How long the hold key must be held before the wheel appears, in ms.
    public var holdDelayMs: Int
    /// Wheel size multiplier. 1.0 = base 380pt canvas. Clamped 0.6...1.2 in UI.
    public var radialScale: Double
    /// Animation speed multiplier. Higher = snappier. Clamped 0.5...2.0 in UI.
    public var radialAnimSpeed: Double
    /// Staggered spring bloom on show. Off = instant fade, fastest.
    public var radialBloom: Bool
    /// Accent glow around the selected slice.
    public var radialGlow: Bool

    /// Menu-bar hand animation config.
    public var icon: IconConfig

    public init(holdKeyCode: Int = 54,
                releaseToFire: Bool = true,
                tickSound: Bool = true,
                holdDelayMs: Int = 150,
                radialScale: Double = 0.85,
                radialAnimSpeed: Double = 1.35,
                radialBloom: Bool = true,
                radialGlow: Bool = true,
                icon: IconConfig = IconConfig()) {
        self.holdKeyCode = holdKeyCode
        self.releaseToFire = releaseToFire
        self.tickSound = tickSound
        self.holdDelayMs = holdDelayMs
        self.radialScale = radialScale
        self.radialAnimSpeed = radialAnimSpeed
        self.radialBloom = radialBloom
        self.radialGlow = radialGlow
        self.icon = icon
    }

    enum CodingKeys: String, CodingKey {
        case holdKeyCode, releaseToFire, tickSound
        case holdDelayMs, radialScale, radialAnimSpeed, radialBloom, radialGlow
        case icon
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        holdKeyCode = try c.decodeIfPresent(Int.self, forKey: .holdKeyCode) ?? 54
        releaseToFire = try c.decodeIfPresent(Bool.self, forKey: .releaseToFire) ?? true
        tickSound = try c.decodeIfPresent(Bool.self, forKey: .tickSound) ?? true
        holdDelayMs = try c.decodeIfPresent(Int.self, forKey: .holdDelayMs) ?? 150
        radialScale = try c.decodeIfPresent(Double.self, forKey: .radialScale) ?? 0.85
        radialAnimSpeed = try c.decodeIfPresent(Double.self, forKey: .radialAnimSpeed) ?? 1.35
        radialBloom = try c.decodeIfPresent(Bool.self, forKey: .radialBloom) ?? true
        radialGlow = try c.decodeIfPresent(Bool.self, forKey: .radialGlow) ?? true
        icon = try c.decodeIfPresent(IconConfig.self, forKey: .icon) ?? IconConfig()
    }
}
