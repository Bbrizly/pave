import Foundation

/// Turns a detected repeated path into a disabled draft macro. Strict,
/// whole-run-or-nothing: every fingerprint in the run must map cleanly to a
/// step, or the whole conversion fails silently. Precision over recall,
/// same rule as the confidence ladder: silence beats a garbage draft.
///
/// Source-folder recovery for a fileMoved step. A fileMoved event only carries
/// its destination folder (verified against EventNormalizer: the folder on a
/// fileMoved spec is the folder the addition was seen in, i.e. where the file
/// landed). The folder it came from has to be recovered by walking backward
/// through that occurrence's own events for the nearest earlier one sharing
/// the same subjectHash. Since subjectHash is a hash of the CURRENT filename
/// (EventNormalizer recomputes it on every rename), the match found is the
/// event that last held that exact name: a fileCreated if the file was never
/// renamed before moving, or a fileRenamed if it was. Either way that event's
/// folder is where the file physically sat right before the move.
public enum PathToMacro {

    public static func convert(match: PathMatch, events: [PaveEvent], config: PaveConfig) -> Macro? {
        let fps = match.run.fingerprints
        let occurrenceIDs = match.continuation.occurrenceEventIDs
        guard !fps.isEmpty, !occurrenceIDs.isEmpty else { return nil }

        // uniquingKeysWith instead of uniqueKeysWithValues: a caller handing
        // back overlapping event ids (two occurrences sharing an id) must not
        // crash the offer path, it should just fail the conversion below.
        let byID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // One concrete event sequence per occurrence, same length and order as fps.
        var occurrences: [[PaveEvent]] = []
        for ids in occurrenceIDs {
            guard ids.count == fps.count else { return nil }
            var seq: [PaveEvent] = []
            seq.reserveCapacity(ids.count)
            for id in ids {
                guard let e = byID[id] else { return nil }   // can't verify, stay silent
                seq.append(e)
            }
            occurrences.append(seq)
        }

        // Pass 1: resolve every fileMoved's source folder.
        var moveSource: [Int: String] = [:]

        for j in fps.indices where fps[j].kind == .fileMoved {
            guard fps[j].folder != nil else { return nil }   // destination must be known

            var resolvedSource: String?
            for occ in occurrences {
                // Defensive: the concrete event must agree with the fingerprint
                // it was grouped under. A mismatch means the caller handed us
                // events that do not belong to this run.
                guard occ[j].folder == fps[j].folder, occ[j].fileExtension == fps[j].fileExtension
                else { return nil }

                guard let anchor = nearestEarlierMatchingHash(occ, at: j) else { return nil }
                guard let source = fps[anchor].folder else { return nil }
                if let already = resolvedSource, already != source { return nil }   // inconsistent source
                resolvedSource = source
            }
            guard let source = resolvedSource else { return nil }
            moveSource[j] = source
        }

        // Pass 2: map every fingerprint to a step, in order.
        var steps: [Step] = []
        var isRenameEdit = false

        for j in fps.indices {
            let f = fps[j]
            switch f.kind {
            case .appActivated, .appLaunched:
                guard let bundleID = f.bundleID else { return nil }
                steps.append(.app(bundleId: bundleID))

            case .fileRenamed:
                guard let folder = f.folder else { return nil }
                let matcher = FileMatcher(folder: folder, ext: f.fileExtension)
                // If every occurrence carried its filenames, try to learn the
                // real template. On success the draft renames on its own and is
                // named normally. On nil it keeps the {name} placeholder and the
                // "edit rename" flag, so the user finishes the rule by hand.
                if let template = inferRenameTemplate(occurrences: occurrences, at: j, config: config) {
                    steps.append(.renameFile(matcher: matcher, nameTemplate: template))
                } else {
                    steps.append(.renameFile(matcher: matcher, nameTemplate: "{name}"))
                    isRenameEdit = true
                }

            case .fileMoved:
                guard let destination = f.folder, let source = moveSource[j] else { return nil }
                steps.append(.moveFile(matcher: FileMatcher(folder: source, ext: f.fileExtension),
                                       destination: destination, overwrite: false))

            case .fileCreated:
                // A leading fileCreated (nothing but other fileCreated steps
                // ahead of it) that is followed later in the run by a
                // fileMoved is presumed to be the ritual's starting point:
                // a file lands, then gets moved (with an optional rename in
                // between). There is no step for "a file appeared", and this
                // shape covers both the direct case (moved keeps the created
                // event's own subjectHash as its anchor) and the renamed
                // case (the anchor is the rename instead, since the hash
                // changes on every rename): drop it silently either way.
                // Any fileCreated NOT in this shape is real information with
                // no step to express it, so it kills the whole conversion.
                guard isLeading(j, in: fps),
                      fps[(j + 1)...].contains(where: { $0.kind == .fileMoved })
                else { return nil }

            case .fileTrashed, .bulkChange, .macroStarted, .macroFinished, .appTerminated:
                return nil
            }
        }

        guard !steps.isEmpty else { return nil }
        let prefix = isRenameEdit ? "Draft (edit rename): " : "Draft: "
        return Macro(name: prefix + describe(steps), enabled: false, steps: steps,
                     paveOrigin: match.pathKey)
    }

    // MARK: helpers

    /// Learn the rename template at fingerprint index j from the filenames on
    /// each occurrence's rename event. Returns nil unless every occurrence has
    /// both its previous and new name, then defers to TemplateInferencer. Any
    /// missing name kills inference so the placeholder path takes over.
    private static func inferRenameTemplate(occurrences: [[PaveEvent]], at j: Int,
                                            config: PaveConfig) -> String? {
        var renames: [(previous: String, new: String, at: Date)] = []
        for occ in occurrences {
            guard let previous = occ[j].previousName, let new = occ[j].rawName else { return nil }
            renames.append((previous: previous, new: new, at: occ[j].timestamp))
        }
        return TemplateInferencer.infer(renames: renames, config: config)?.template
    }

    /// True when nothing before index j in the run is anything other than
    /// another fileCreated. "Leading" means at the very front of the ritual,
    /// not buried after user-visible steps.
    private static func isLeading(_ j: Int, in fps: [PaveFingerprint]) -> Bool {
        for i in 0..<j where fps[i].kind != .fileCreated { return false }
        return true
    }

    /// Nearest earlier event in the same occurrence whose subjectHash matches
    /// the event at index j. Nil if none, or if either has no hash.
    private static func nearestEarlierMatchingHash(_ occ: [PaveEvent], at j: Int) -> Int? {
        guard let hash = occ[j].subjectHash else { return nil }
        var i = j - 1
        while i >= 0 {
            if occ[i].subjectHash == hash { return i }
            i -= 1
        }
        return nil
    }

    // MARK: naming

    private static func describe(_ steps: [Step]) -> String {
        steps.map(phrase).joined(separator: " then ")
    }

    private static func phrase(_ step: Step) -> String {
        switch step {
        case .app(let bundleId):
            return "open \(appName(bundleId))"
        case .open(let target):
            return "open \(lastComponent(target))"
        case .moveFile(let matcher, let destination, _):
            let subject = matcher.ext?.isEmpty == false ? matcher.ext! : "file"
            return "move newest \(subject) from \(lastComponent(matcher.folder)) to \(lastComponent(destination))"
        case .renameFile(let matcher, _):
            let subject = matcher.ext?.isEmpty == false ? matcher.ext! : "file"
            return "rename newest \(subject) in \(lastComponent(matcher.folder))"
        default:
            return "do a step"
        }
    }

    private static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private static func appName(_ bundleID: String) -> String {
        bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}
