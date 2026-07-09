import Foundation

/// One semantic desktop event. Never keystrokes, never file contents.
/// Raw filenames are hashed into `subjectHash` for identity, never stored raw here.
public struct PaveEvent: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let kind: PaveEventKind
    public let origin: PaveEventOrigin
    public let bundleID: String?
    public let folder: String?
    public let fileExtension: String?
    public let subjectHash: String?      // hashed filename identity, never the raw name
    public let reliability: Double        // 0…1, 1.0 direct, 0.75 inferred
    public let sessionID: UUID?
    /// Raw current filename for file events, kept only when a watched folder is
    /// opted-in evidence (config.storeFileNames). Nil for non-file events and
    /// when name storage is off. Never enters the fingerprint or the hash.
    public let rawName: String?
    /// The previous filename on a fileRenamed event, from the folder diff. Same
    /// opt-in rule as rawName. Nil everywhere else.
    public let previousName: String?

    public init(id: UUID = UUID(),
                timestamp: Date,
                kind: PaveEventKind,
                origin: PaveEventOrigin = .user,
                bundleID: String? = nil,
                folder: String? = nil,
                fileExtension: String? = nil,
                subjectHash: String? = nil,
                reliability: Double = 1.0,
                sessionID: UUID? = nil,
                rawName: String? = nil,
                previousName: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.origin = origin
        self.bundleID = bundleID
        self.folder = folder
        self.fileExtension = fileExtension
        self.subjectHash = subjectHash
        self.reliability = reliability
        self.sessionID = sessionID
        self.rawName = rawName
        self.previousName = previousName
    }

    enum CodingKeys: String, CodingKey {
        case id, timestamp, kind, origin, bundleID, folder
        case fileExtension, subjectHash, reliability, sessionID
        case rawName, previousName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date(timeIntervalSince1970: 0)
        kind = try c.decodeIfPresent(PaveEventKind.self, forKey: .kind) ?? .bulkChange
        origin = try c.decodeIfPresent(PaveEventOrigin.self, forKey: .origin) ?? .user
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        fileExtension = try c.decodeIfPresent(String.self, forKey: .fileExtension)
        subjectHash = try c.decodeIfPresent(String.self, forKey: .subjectHash)
        reliability = try c.decodeIfPresent(Double.self, forKey: .reliability) ?? 1.0
        sessionID = try c.decodeIfPresent(UUID.self, forKey: .sessionID)
        rawName = try c.decodeIfPresent(String.self, forKey: .rawName)
        previousName = try c.decodeIfPresent(String.self, forKey: .previousName)
    }
}

public enum PaveEventKind: String, Codable, CaseIterable, Sendable {
    case appLaunched, appActivated, appTerminated
    case fileCreated, fileRenamed, fileMoved, fileTrashed
    case macroStarted, macroFinished
    case bulkChange
}

/// Who caused the event. `.macro` suppresses self-discovery later.
public enum PaveEventOrigin: Codable, Equatable, Sendable {
    case user
    case system
    case macro(UUID)

    enum K: String, CodingKey { case type, id }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let t = try c.decodeIfPresent(String.self, forKey: .type) ?? "user"
        switch t {
        case "system": self = .system
        case "macro":
            if let id = try c.decodeIfPresent(UUID.self, forKey: .id) { self = .macro(id) }
            else { self = .user }
        default: self = .user
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .user: try c.encode("user", forKey: .type)
        case .system: try c.encode("system", forKey: .type)
        case .macro(let id):
            try c.encode("macro", forKey: .type)
            try c.encode(id, forKey: .id)
        }
    }
}

/// The content-free matching key. Excludes the raw filename identity on purpose:
/// two different files renamed the same way must match. Filenames live on the
/// event for display, never in the fingerprint.
public struct PaveFingerprint: Hashable, Codable, Sendable {
    public let kind: PaveEventKind
    public let bundleID: String?
    public let folder: String?
    public let fileExtension: String?

    public init(kind: PaveEventKind, bundleID: String? = nil,
                folder: String? = nil, fileExtension: String? = nil) {
        self.kind = kind
        self.bundleID = bundleID
        self.folder = folder
        self.fileExtension = fileExtension
    }

    public init(event: PaveEvent) {
        self.init(kind: event.kind, bundleID: event.bundleID,
                  folder: event.folder, fileExtension: event.fileExtension)
    }
}

/// Stable, deterministic hash for filename identity. FNV-1a, no dependencies,
/// same result on every platform and run (Swift's Hasher is not stable).
public enum PaveHash {
    public static func stable(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return String(h, radix: 16)
    }
}
