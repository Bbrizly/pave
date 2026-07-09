#if os(macOS)
import PaveKit
import SwiftUI

/// Read-only window into the observation ledger: is it recording, what
/// repeated this week, and the raw recent feed. Loads once on appear plus
/// a manual Refresh. Never polls, matches the report status boundary
/// (observer + ledger + Activity pane, no miner/prediction UI yet).
struct ActivityView: View {
    @StateObject private var store = ActivityStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                statusSection
                repeatsSection
                recentSection
                footer
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await store.load() }
        .confirmationDialog(
            "Delete all observation history?",
            isPresented: $store.showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete everything", role: .destructive) {
                Task { await store.deleteAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears every recorded event. It cannot be undone.")
        }
    }

    private var header: some View {
        HStack {
            Text("Activity")
                .font(.title2.bold())
            Spacer()
            Button {
                Task { await store.load() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.isLoading)
        }
    }

    // MARK: status

    @ViewBuilder private var statusSection: some View {
        sectionHeader("Status")
        switch store.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
        case .noDatabase:
            emptyCard(
                "The agent has not recorded anything yet.",
                detail: "PaveAgent writes to the ledger once it starts watching folders and app switches.")
        case .failed(let message):
            failedCard(message)
        case .ready(let snapshot):
            statusCard(snapshot)
        }
    }

    private func statusCard(_ s: ActivityStore.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(s.stateColor).frame(width: 9, height: 9)
                Text(s.stateLabel).font(.headline)
                if s.isPaused == true {
                    Text("Paused")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .foregroundColor(.orange)
                }
                Spacer()
            }
            HStack(spacing: 20) {
                stat("Rows", "\(s.rows)")
                stat("DB size", s.dbSizeText)
                stat("Dropped", "\(s.dropped)", highlight: s.dropped > 0)
                stat("Last write", s.lastWriteText)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.secondary.opacity(0.15)))
    }

    private func stat(_ label: String, _ value: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
                .kerning(0.3)
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundColor(highlight ? .orange : .primary)
        }
    }

    // MARK: repeated this week

    @ViewBuilder private var repeatsSection: some View {
        if case .ready(let s) = store.phase {
            sectionHeader("Repeated this week")
            if s.repeats.isEmpty {
                emptyCard(
                    "Nothing repeated 3+ times yet. Keep working, Pave is watching folders and app switches only.",
                    detail: nil)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(s.repeats.enumerated()), id: \.offset) { _, run in
                        repeatCard(run)
                    }
                }
            }
        }
    }

    private func repeatCard(_ run: RepeatedRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(run.occurrences)\u{d7}")
                    .font(.headline)
                Text("across \(run.distinctDays) day\(run.distinctDays == 1 ? "" : "s")")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Spacer()
                Text(ActivityStore.relative.localizedString(for: run.lastSeen, relativeTo: Date()))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(run.plainEnglish().enumerated()), id: \.offset) { i, line in
                    Text("\(i + 1). \(line)")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.secondary.opacity(0.15)))
    }

    // MARK: recent activity

    @ViewBuilder private var recentSection: some View {
        if case .ready(let s) = store.phase {
            sectionHeader("Recent activity")
            if s.recent.isEmpty {
                emptyCard("No events recorded yet.", detail: nil)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(s.recent.enumerated()), id: \.offset) { i, event in
                        recentRow(event)
                        if i < s.recent.count - 1 {
                            Divider().opacity(0.4)
                        }
                    }
                }
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.secondary.opacity(0.12)))
            }
        }
    }

    private func recentRow(_ event: PaveEvent) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ActivityStore.icon(for: event.kind))
                .foregroundColor(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(ActivityStore.description(for: event))
                    .font(.callout)
                Text(ActivityStore.relative.localizedString(for: event.timestamp, relativeTo: Date()))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Button(role: .destructive) {
                store.showDeleteConfirm = true
            } label: {
                Label("Delete observation history", systemImage: "trash")
            }
            .disabled(store.isLoading)
            Text("Metadata only. Local only. Filenames in watched folders are kept as local evidence, never file contents, never keystrokes. Deleting history removes everything.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: shared pieces

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .kerning(0.5)
    }

    private func emptyCard(_ text: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .foregroundColor(.secondary)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.secondary.opacity(0.12)))
    }

    private func failedCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Couldn't read the activity ledger.", systemImage: "exclamationmark.triangle")
                .foregroundColor(.orange)
            Text(message)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.18)))
    }
}

/// Owns ledger reads for ActivityView. The ledger open and the two report
/// queries happen off the main actor in `readSnapshot()`; everything that
/// touches `@Published` state runs here on the main actor.
@MainActor
final class ActivityStore: ObservableObject {
    enum Phase {
        case loading
        case noDatabase
        case failed(String)
        case ready(Snapshot)
    }

    struct Snapshot {
        var stateLabel: String
        var stateColor: Color
        var isPaused: Bool?
        var rows: Int
        var dbSizeText: String
        var dropped: Int
        var lastWriteText: String
        var repeats: [RepeatedRun]
        var recent: [PaveEvent]
    }

    /// Unformatted read from the ledger, built off the main actor.
    private struct RawSnapshot {
        var rows: Int
        var dbBytes: Int64
        var lastWrite: Date?
        var dropped: Int
        var lastErrorText: String?
        var isPaused: Bool?
        var repeats: [RepeatedRun]
        var recent: [PaveEvent]
    }

    private enum LoadOutcome {
        case failed(String)
        case ok(RawSnapshot)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var isLoading = false
    @Published var showDeleteConfirm = false

    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    /// Display-only heuristic for "still recording" vs "gone quiet". Not a
    /// matcher tuning literal, purely how fresh the last write needs to be
    /// before this pane calls it live.
    private static let recordingWindow: TimeInterval = 15 * 60

    private nonisolated static var dbURL: URL {
        Store().root.appendingPathComponent("pave.sqlite")
    }

    private nonisolated static var configURL: URL {
        Store().root.appendingPathComponent("pave.json")
    }

    func load() async {
        isLoading = true
        guard FileManager.default.fileExists(atPath: Self.dbURL.path) else {
            phase = .noDatabase
            isLoading = false
            return
        }

        let outcome = await Task.detached(priority: .userInitiated) { () -> LoadOutcome in
            Self.readSnapshot()
        }.value

        switch outcome {
        case .failed(let message):
            phase = .failed(message)
        case .ok(let raw):
            phase = .ready(makeSnapshot(from: raw))
        }
        isLoading = false
    }

    func deleteAll() async {
        guard FileManager.default.fileExists(atPath: Self.dbURL.path) else { return }
        isLoading = true
        await Task.detached(priority: .userInitiated) {
            let ledger = PaveLedger(url: Self.dbURL)
            ledger.deleteAll()
        }.value
        await load()
    }

    /// Off the main actor: opens the ledger, pulls stats plus the two
    /// report windows. Returns raw values only, no formatting here.
    private nonisolated static func readSnapshot() -> LoadOutcome {
        let ledger = PaveLedger(url: dbURL)
        let stats = ledger.stats()
        let now = Date()

        let since14 = Calendar.current.date(byAdding: .day, value: -14, to: now)
            ?? now.addingTimeInterval(-14 * 86_400)
        let recentEvents = ledger.events(in: Date(timeIntervalSince1970: 0) ..< now, limit: 200)
            .sorted { $0.timestamp > $1.timestamp }
        let windowEvents = ledger.events(in: since14 ..< now, limit: 20_000)
        let repeats = ReportBuilder.build(from: windowEvents, config: PaveConfig.load(from: configURL))
        let errorText = ledger.lastError

        if let errorText, stats.rows == 0, stats.lastWrite == nil {
            return .failed(errorText)
        }

        let raw = RawSnapshot(
            rows: stats.rows,
            dbBytes: stats.dbBytes,
            lastWrite: stats.lastWrite,
            dropped: stats.droppedEvents,
            lastErrorText: errorText,
            isPaused: readPausedFlag(),
            repeats: repeats,
            recent: Array(recentEvents.prefix(200)))
        return .ok(raw)
    }

    /// Turns a raw ledger read into display text and colors. Runs on the
    /// main actor so the shared formatters never cross threads.
    private func makeSnapshot(from raw: RawSnapshot) -> Snapshot {
        let now = Date()
        let stateLabel: String
        let stateColor: Color
        if let err = raw.lastErrorText, !err.isEmpty {
            stateLabel = "Failed"
            stateColor = .red
        } else if let lastWrite = raw.lastWrite, now.timeIntervalSince(lastWrite) < Self.recordingWindow {
            stateLabel = "Recording"
            stateColor = .green
        } else {
            stateLabel = "No data yet"
            stateColor = .secondary
        }

        let lastWriteText = raw.lastWrite
            .map { Self.relative.localizedString(for: $0, relativeTo: now) } ?? "never"

        return Snapshot(
            stateLabel: stateLabel,
            stateColor: stateColor,
            isPaused: raw.isPaused,
            rows: raw.rows,
            dbSizeText: Self.bytes.string(fromByteCount: raw.dbBytes),
            dropped: raw.dropped,
            lastWriteText: lastWriteText,
            repeats: raw.repeats,
            recent: raw.recent)
    }

    /// Only reports a paused hint when the key is actually readable; the
    /// agent's UserDefaults domain is not guaranteed shared with the editor.
    private nonisolated static func readPausedFlag() -> Bool? {
        guard UserDefaults.standard.object(forKey: "pave.observation.paused") != nil else { return nil }
        return UserDefaults.standard.bool(forKey: "pave.observation.paused")
    }

    /// Small fixed icon map. Falls back to a generic dot for kinds this
    /// build does not know about yet, same read-only posture as unknown steps.
    static func icon(for kind: PaveEventKind) -> String {
        switch kind.rawValue {
        case "appActivated": return "app.badge"
        case "fileCreated": return "doc.badge.plus"
        case "fileRenamed": return "pencil"
        case "fileMoved": return "arrow.turn.up.right"
        case "fileTrashed": return "trash"
        case "bulkChange": return "square.stack.3d.up"
        case "macroStarted": return "bolt.fill"
        default: return "circle.dashed"
        }
    }

    static func description(for event: PaveEvent) -> String {
        let label = humanize(event.kind.rawValue)
        var detail = ""
        if let bundleID = event.bundleID, !bundleID.isEmpty {
            detail = bundleID
        } else {
            var pieces: [String] = []
            if let folder = event.folder, !folder.isEmpty { pieces.append(folder) }
            if let ext = event.fileExtension, !ext.isEmpty { pieces.append("." + ext) }
            detail = pieces.joined(separator: " ")
        }
        return detail.isEmpty ? label : "\(label) \u{b7} \(detail)"
    }

    /// "appActivated" -> "App Activated". Works for any future rawValue
    /// without needing the full PaveEventKind case list.
    private static func humanize(_ raw: String) -> String {
        var out = ""
        for (i, ch) in raw.enumerated() {
            if ch.isUppercase && i > 0 { out.append(" ") }
            out.append(i == 0 ? Character(ch.uppercased()) : ch)
        }
        return out
    }
}
#endif
