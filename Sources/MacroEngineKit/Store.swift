import Foundation

/// Plain JSON on disk in Application Support. Human-readable, git-friendly.
/// One macro per file. The agent hot-reloads on directory changes.
public final class Store {
    public let root: URL

    public var macrosDir: URL { root.appendingPathComponent("macros") }
    public var ringsURL: URL { root.appendingPathComponent("rings.json") }
    public var settingsURL: URL { root.appendingPathComponent("settings.json") }

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = base.appendingPathComponent("Macro Studio")
        }
        try? FileManager.default.createDirectory(at: macrosDir, withIntermediateDirectories: true)
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    // MARK: Macros

    public func loadMacros() -> [Macro] {
        let files = (try? FileManager.default.contentsOfDirectory(at: macrosDir, includingPropertiesForKeys: nil)) ?? []
        var out: [Macro] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f) else { continue }
            if let m = try? JSONDecoder().decode(Macro.self, from: data) {
                out.append(m)
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func save(_ macro: Macro) throws {
        let url = macrosDir.appendingPathComponent("\(macro.id.uuidString).json")
        try Store.encoder().encode(macro).write(to: url, options: .atomic)
    }

    public func delete(_ id: UUID) {
        let url = macrosDir.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Rings

    public func loadRings() -> [String: [RingSlice]] {
        guard let data = try? Data(contentsOf: ringsURL),
              let rings = try? JSONDecoder().decode([String: [RingSlice]].self, from: data)
        else { return [:] }
        return rings
    }

    public func saveRings(_ rings: [String: [RingSlice]]) throws {
        try Store.encoder().encode(rings).write(to: ringsURL, options: .atomic)
    }

    // MARK: Settings

    public func loadSettings() -> Settings {
        guard let data = try? Data(contentsOf: settingsURL),
              let s = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        return s
    }

    public func saveSettings(_ s: Settings) throws {
        try Store.encoder().encode(s).write(to: settingsURL, options: .atomic)
    }

    // MARK: Import / export (.macrostudio = one JSON document)

    struct ExportDoc: Codable {
        var macros: [Macro]
        var rings: [String: [RingSlice]]
    }

    public func exportAll(to url: URL) throws {
        let doc = ExportDoc(macros: loadMacros(), rings: loadRings())
        try Store.encoder().encode(doc).write(to: url, options: .atomic)
    }

    /// Imported macros get fresh ids. Any macro containing a shell step
    /// arrives disabled and is listed in needsReview: inspect before approve.
    public func importFile(at url: URL) throws -> (imported: Int, needsReview: [String]) {
        let doc = try JSONDecoder().decode(ExportDoc.self, from: Data(contentsOf: url))
        var needsReview: [String] = []
        for var m in doc.macros {
            m.id = UUID()
            let hasShell = m.steps.contains {
                if case .shell = $0 { return true }
                return false
            }
            if hasShell {
                m.enabled = false
                needsReview.append(m.name)
            }
            try save(m)
        }
        var rings = loadRings()
        for (ctx, ring) in doc.rings where rings[ctx] == nil {
            rings[ctx] = ring
        }
        try saveRings(rings)
        return (doc.macros.count, needsReview)
    }
}
