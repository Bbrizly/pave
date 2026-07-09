import Foundation

/// The ONLY file allowed to hold tuning literals. Every knob lives here with a
/// unit and a reason. PaveConfig mirrors these and can override them at runtime.
public enum PaveDefaults {
    /// Folders watched for file events. The common user document roots.
    public static let watchedFolders: [String] = ["~/Desktop", "~/Documents", "~/Downloads"]
    /// Extensions ignored. Partial or in-progress download and temp files.
    public static let excludedExtensions: [String] = ["crdownload", "download", "part", "tmp", "icloud"]
    /// Path substrings ignored. Trash churn is not user intent.
    public static let excludedPathSubstrings: [String] = [".Trash"]
    /// Count. More changes than this in one folder inside the burst window collapse to one bulkChange.
    public static let burstThresholdCount: Int = 20
    /// Seconds. Window for the burst collapse test and for pairing a move.
    public static let burstWindowSeconds: Double = 2
    /// Seconds. Repeat activations of the same app inside this window are dropped.
    public static let activationDedupeSeconds: Double = 2
    /// Minutes. Idle gap that ends a session.
    public static let sessionIdleMinutes: Double = 15
    /// Days. Events older than this are pruned.
    public static let retentionDays: Int = 30
    /// Count. Ledger flushes when this many events are buffered.
    public static let flushBatchSize: Int = 64
    /// Seconds. Ledger flushes when the oldest buffered event is older than this.
    public static let flushMaxLatencySeconds: Double = 1
    /// Count. A fingerprint run must occur at least this many times to be reported.
    public static let reportMinOccurrences: Int = 3
    /// Count. Shortest run length reported, in steps.
    public static let reportMinLength: Int = 3
    /// Count. Longest run length reported, in steps.
    public static let reportMaxLength: Int = 12
    /// Count. Events at the head of a path used as the live match key.
    public static let matchPrefixLength: Int = 2
    /// Count. Stranger events tolerated inside a candidate prefix before it breaks.
    public static let matchGapTolerance: Int = 2
    /// Count. A path must recur at least this many times to be discovered.
    public static let discoveredMinOccurrences: Int = 3
    /// Count. A path must recur at least this many times to be suggested.
    public static let suggestMinOccurrences: Int = 3
    /// Count. Shortest full path length that may be suggested, in steps.
    public static let suggestMinLength: Int = 3
    /// Ratio 0…1. The best continuation must own at least this share to suggest.
    public static let suggestConfidence: Double = 0.8
    /// Hours. Minimum gap before the same path may be offered again.
    public static let offerCooldownHours: Double = 6
    /// Days. A dismissed path stays suppressed this long.
    public static let dismissalSuppressDays: Double = 7
    /// Count. The live PathIndex rebuilds after this many new events are
    /// appended, so a growing ledger stays reflected without rebuilding on
    /// every single event.
    public static let rebuildEveryEvents: Int = 500
    /// Days. How far back the live PathIndex looks when it (re)builds.
    public static let pathIndexWindowDays: Int = 30
    /// Count. Safety cap on how many events one PathIndex rebuild reads.
    public static let pathIndexEventLimit: Int = 200_000
    /// Bool. Store raw filenames on file events as opt-in evidence. Watched
    /// folders are opted-in, so this is on by default. Off keeps names nil.
    public static let storeFileNames: Bool = true
    /// Ratio 0…1. Lowest share of occurrences a rendered rename template must
    /// reproduce exactly before it is trusted. Precision over recall.
    public static let templateMinConfidence: Double = 0.9
    /// Count. Confirmed runs of a learned macro before Pave may offer auto-run.
    public static let paveAfterConfirmedRuns: Int = 5
    /// Bool. Master switch for auto-run. Off by default: the agent must check
    /// this AND the per-macro approval before ever running anything on its own.
    public static let autoRunEnabled: Bool = false
}
