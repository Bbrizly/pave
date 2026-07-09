import Foundation

/// Turns one explicit capture window into a draft macro. The user chose the
/// start and end, so this is lenient where PathToMacro is strict: it maps what
/// it can, skips what it cannot, and only bails if too little survives. It
/// never infers a rename template (a single capture has no repetition to learn
/// from) and never runs anything, it just drafts a disabled macro.
public enum RecordConverter {

    public static func convert(events: [PaveEvent], config: PaveConfig) -> Macro? {
        // Only the user's own actions, in time order. Anything Pave or the
        // system caused is not part of what the user meant to record.
        let seq = events
            .filter { if case .user = $0.origin { return true } else { return false } }
            .sorted { $0.timestamp < $1.timestamp }

        var steps: [Step] = []
        for (i, e) in seq.enumerated() {
            switch e.kind {
            case .appActivated, .appLaunched:
                guard let bundleID = e.bundleID else { continue }
                steps.append(.app(bundleId: bundleID))

            case .fileMoved:
                // Destination is the event's folder. Recover the source from the
                // nearest earlier event with the same subjectHash in the window.
                // Unrecoverable means we cannot name a source folder, so skip it
                // rather than draft a broken move.
                guard let destination = e.folder,
                      let source = nearestEarlierSameHashFolder(seq, at: i) else { continue }
                steps.append(.moveFile(matcher: FileMatcher(folder: source, ext: e.fileExtension),
                                       destination: destination, overwrite: false))

            case .fileRenamed:
                // One capture cannot infer a template, so the placeholder stands.
                // rawName only helps name the macro nicely, never the step.
                guard let folder = e.folder else { continue }
                steps.append(.renameFile(matcher: FileMatcher(folder: folder, ext: e.fileExtension),
                                         nameTemplate: "{name}"))

            default:
                // fileCreated, fileTrashed, bulkChange, macro and app
                // termination events have no step to express, so drop them.
                continue
            }
        }

        // A single mapped step is not a ritual worth saving. Two is the floor.
        guard steps.count >= 2 else { return nil }
        return Macro(name: "Recorded: " + describe(steps),
                     enabled: false, steps: steps,
                     paveOrigin: "record:" + UUID().uuidString)
    }

    // MARK: helpers

    /// Folder of the nearest earlier event sharing this event's subjectHash. The
    /// hash tracks the current filename, so the last event that held that exact
    /// name is where the file physically sat before the move. Nil if none.
    private static func nearestEarlierSameHashFolder(_ seq: [PaveEvent], at j: Int) -> String? {
        guard let hash = seq[j].subjectHash else { return nil }
        var i = j - 1
        while i >= 0 {
            if seq[i].subjectHash == hash, let folder = seq[i].folder { return folder }
            i -= 1
        }
        return nil
    }

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
