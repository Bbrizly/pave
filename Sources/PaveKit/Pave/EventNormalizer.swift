import Foundation

/// A raw signal from an observer. The normalizer turns these into PaveEvents.
/// Folder snapshots carry file identity (fileID) and a display name.
/// No contents ever cross this boundary.
public enum RawChange {
    case appActivated(bundleID: String)
    case appLaunched(bundleID: String)
    case appTerminated(bundleID: String)
    case folderChanged(folder: String, snapshot: [FileStat])
    case screenLocked
    case screenUnlocked
}

public struct FileStat: Equatable, Sendable {
    public let fileID: UInt64
    public let name: String
    public init(fileID: UInt64, name: String) {
        self.fileID = fileID
        self.name = name
    }
}

/// Turns raw signals into semantic PaveEvents. Pure logic, no I/O, no timers.
/// The clock is the `at:` argument on every ingest, so tests are deterministic.
///
/// Move detection is source-first: a file leaving folder A is held briefly, and
/// if the same fileID appears in folder B within the burst window it becomes a
/// fileMoved. A removal that never reappears is emitted as fileTrashed once the
/// window passes (checked lazily on the next ingest, nothing polls).
public final class EventNormalizer {
    public var config: PaveConfig

    private var snapshots: [String: [UInt64: FileStat]] = [:]
    private var pendingRemovals: [Removal] = []
    private var lastActivation: [String: Date] = [:]
    private var burstTimes: [String: [(time: Date, count: Int)]] = [:]
    private var currentSessionID: UUID?
    private var lastEventTime: Date?
    private var locked = false

    private struct Removal {
        let fileID: UInt64
        let folder: String
        let ext: String?
        let hash: String
        let name: String
        let time: Date
    }

    private struct Spec {
        let kind: PaveEventKind
        let bundleID: String?
        let folder: String?
        let ext: String?
        let hash: String?
        let reliability: Double
        let rawName: String?
        let previousName: String?

        init(kind: PaveEventKind, bundleID: String?, folder: String?, ext: String?,
             hash: String?, reliability: Double,
             rawName: String? = nil, previousName: String? = nil) {
            self.kind = kind
            self.bundleID = bundleID
            self.folder = folder
            self.ext = ext
            self.hash = hash
            self.reliability = reliability
            self.rawName = rawName
            self.previousName = previousName
        }
    }

    public init(config: PaveConfig = PaveConfig()) {
        self.config = config
    }

    public func ingest(_ raw: RawChange, at now: Date) -> [PaveEvent] {
        var specs: [Spec] = []

        // Expire held removals that never reappeared. They become trashed.
        specs.append(contentsOf: expireRemovals(now: now))

        switch raw {
        case .screenLocked:
            locked = true
            currentSessionID = UUID()   // lock ends the current session
        case .screenUnlocked:
            locked = false
        case .appLaunched(let b):
            specs.append(Spec(kind: .appLaunched, bundleID: b, folder: nil, ext: nil, hash: nil, reliability: 1.0))
        case .appTerminated(let b):
            specs.append(Spec(kind: .appTerminated, bundleID: b, folder: nil, ext: nil, hash: nil, reliability: 1.0))
        case .appActivated(let b):
            if let last = lastActivation[b], now.timeIntervalSince(last) < config.activationDedupeSeconds {
                lastActivation[b] = now   // refresh, keep deduping a steady stream
            } else {
                lastActivation[b] = now
                specs.append(Spec(kind: .appActivated, bundleID: b, folder: nil, ext: nil, hash: nil, reliability: 1.0))
            }
        case .folderChanged(let folder, let snapshot):
            specs.append(contentsOf: folderSpecs(folder: folder, snapshot: snapshot, now: now))
        }

        return finalize(specs, now: now)
    }

    // MARK: folder diff

    private func folderSpecs(folder: String, snapshot: [FileStat], now: Date) -> [Spec] {
        if config.excludedPathSubstrings.contains(where: { folder.contains($0) }) { return [] }

        var new: [UInt64: FileStat] = [:]
        for f in snapshot where !isExcludedFile(f.name) { new[f.fileID] = f }
        let old = snapshots[folder] ?? [:]

        var renames: [FileStat] = []
        var additions: [FileStat] = []
        var removals: [UInt64] = []
        for (id, stat) in new {
            if let prev = old[id] {
                if prev.name != stat.name { renames.append(stat) }
            } else {
                additions.append(stat)
            }
        }
        for (id, _) in old where new[id] == nil { removals.append(id) }

        let changeCount = renames.count + additions.count + removals.count
        if changeCount == 0 { return [] }

        // Burst collapse: too many changes in this folder inside the window.
        var recent = (burstTimes[folder] ?? []).filter { now.timeIntervalSince($0.time) <= config.burstWindowSeconds }
        let windowSum = recent.reduce(0) { $0 + $1.count } + changeCount
        recent.append((now, changeCount))
        burstTimes[folder] = recent
        snapshots[folder] = new

        if windowSum > config.burstThresholdCount {
            return [Spec(kind: .bulkChange, bundleID: nil, folder: folder, ext: nil, hash: nil, reliability: 1.0)]
        }

        var specs: [Spec] = []
        for r in renames {
            // The previous name is the same fileID's name in the prior snapshot.
            let prev = old[r.fileID]?.name
            specs.append(Spec(kind: .fileRenamed, bundleID: nil, folder: folder,
                              ext: ext(of: r.name), hash: PaveHash.stable(r.name), reliability: 0.75,
                              rawName: name(r.name), previousName: name(prev)))
        }
        for a in additions {
            if let idx = pendingRemovals.firstIndex(where: { $0.fileID == a.fileID && $0.folder != folder }) {
                pendingRemovals.remove(at: idx)
                specs.append(Spec(kind: .fileMoved, bundleID: nil, folder: folder,
                                  ext: ext(of: a.name), hash: PaveHash.stable(a.name), reliability: 0.75,
                                  rawName: name(a.name)))
            } else {
                specs.append(Spec(kind: .fileCreated, bundleID: nil, folder: folder,
                                  ext: ext(of: a.name), hash: PaveHash.stable(a.name), reliability: 1.0,
                                  rawName: name(a.name)))
            }
        }
        for id in removals {
            if let stat = old[id] {
                pendingRemovals.append(Removal(fileID: id, folder: folder,
                                               ext: ext(of: stat.name), hash: PaveHash.stable(stat.name),
                                               name: stat.name, time: now))
            }
        }
        return specs
    }

    private func expireRemovals(now: Date) -> [Spec] {
        var out: [Spec] = []
        var kept: [Removal] = []
        for r in pendingRemovals {
            if now.timeIntervalSince(r.time) > config.burstWindowSeconds {
                out.append(Spec(kind: .fileTrashed, bundleID: nil, folder: r.folder,
                                ext: r.ext, hash: r.hash, reliability: 1.0, rawName: name(r.name)))
            } else {
                kept.append(r)
            }
        }
        pendingRemovals = kept
        return out
    }

    // MARK: session and origin

    private func finalize(_ specs: [Spec], now: Date) -> [PaveEvent] {
        guard !specs.isEmpty else { return [] }
        if let last = lastEventTime, now.timeIntervalSince(last) > config.sessionIdleMinutes * 60 {
            currentSessionID = UUID()
        }
        if currentSessionID == nil { currentSessionID = UUID() }
        lastEventTime = now
        let origin: PaveEventOrigin = locked ? .system : .user
        let session = currentSessionID
        return specs.map {
            PaveEvent(timestamp: now, kind: $0.kind, origin: origin,
                      bundleID: $0.bundleID, folder: $0.folder, fileExtension: $0.ext,
                      subjectHash: $0.hash, reliability: $0.reliability, sessionID: session,
                      rawName: $0.rawName, previousName: $0.previousName)
        }
    }

    // MARK: helpers

    /// Gate a filename behind the opt-in. Off means names never leave here.
    private func name(_ value: String?) -> String? {
        config.storeFileNames ? value : nil
    }

    private func isExcludedFile(_ name: String) -> Bool {
        guard let e = ext(of: name) else { return false }
        return config.excludedExtensions.contains(e)
    }

    private func ext(of name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let e = String(name[name.index(after: dot)...]).lowercased()
        return e.isEmpty ? nil : e
    }
}
