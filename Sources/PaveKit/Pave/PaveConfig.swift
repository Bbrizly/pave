import Foundation

/// Runtime config. Mirrors PaveDefaults field for field. Tolerant decode: every
/// field falls back to its default, so a partial or old JSON still loads.
public struct PaveConfig: Codable, Equatable, Sendable {
    public var watchedFolders: [String]
    public var excludedExtensions: [String]
    public var excludedPathSubstrings: [String]
    public var burstThresholdCount: Int
    public var burstWindowSeconds: Double
    public var activationDedupeSeconds: Double
    public var sessionIdleMinutes: Double
    public var retentionDays: Int
    public var flushBatchSize: Int
    public var flushMaxLatencySeconds: Double
    public var reportMinOccurrences: Int
    public var reportMinLength: Int
    public var reportMaxLength: Int
    public var matchPrefixLength: Int
    public var matchGapTolerance: Int
    public var discoveredMinOccurrences: Int
    public var suggestMinOccurrences: Int
    public var suggestMinLength: Int
    public var suggestConfidence: Double
    public var offerCooldownHours: Double
    public var dismissalSuppressDays: Double
    public var rebuildEveryEvents: Int
    public var storeFileNames: Bool
    public var templateMinConfidence: Double
    public var paveAfterConfirmedRuns: Int
    public var autoRunEnabled: Bool

    public init(watchedFolders: [String] = PaveDefaults.watchedFolders,
                excludedExtensions: [String] = PaveDefaults.excludedExtensions,
                excludedPathSubstrings: [String] = PaveDefaults.excludedPathSubstrings,
                burstThresholdCount: Int = PaveDefaults.burstThresholdCount,
                burstWindowSeconds: Double = PaveDefaults.burstWindowSeconds,
                activationDedupeSeconds: Double = PaveDefaults.activationDedupeSeconds,
                sessionIdleMinutes: Double = PaveDefaults.sessionIdleMinutes,
                retentionDays: Int = PaveDefaults.retentionDays,
                flushBatchSize: Int = PaveDefaults.flushBatchSize,
                flushMaxLatencySeconds: Double = PaveDefaults.flushMaxLatencySeconds,
                reportMinOccurrences: Int = PaveDefaults.reportMinOccurrences,
                reportMinLength: Int = PaveDefaults.reportMinLength,
                reportMaxLength: Int = PaveDefaults.reportMaxLength,
                matchPrefixLength: Int = PaveDefaults.matchPrefixLength,
                matchGapTolerance: Int = PaveDefaults.matchGapTolerance,
                discoveredMinOccurrences: Int = PaveDefaults.discoveredMinOccurrences,
                suggestMinOccurrences: Int = PaveDefaults.suggestMinOccurrences,
                suggestMinLength: Int = PaveDefaults.suggestMinLength,
                suggestConfidence: Double = PaveDefaults.suggestConfidence,
                offerCooldownHours: Double = PaveDefaults.offerCooldownHours,
                dismissalSuppressDays: Double = PaveDefaults.dismissalSuppressDays,
                rebuildEveryEvents: Int = PaveDefaults.rebuildEveryEvents,
                storeFileNames: Bool = PaveDefaults.storeFileNames,
                templateMinConfidence: Double = PaveDefaults.templateMinConfidence,
                paveAfterConfirmedRuns: Int = PaveDefaults.paveAfterConfirmedRuns,
                autoRunEnabled: Bool = PaveDefaults.autoRunEnabled) {
        self.watchedFolders = watchedFolders
        self.excludedExtensions = excludedExtensions
        self.excludedPathSubstrings = excludedPathSubstrings
        self.burstThresholdCount = burstThresholdCount
        self.burstWindowSeconds = burstWindowSeconds
        self.activationDedupeSeconds = activationDedupeSeconds
        self.sessionIdleMinutes = sessionIdleMinutes
        self.retentionDays = retentionDays
        self.flushBatchSize = flushBatchSize
        self.flushMaxLatencySeconds = flushMaxLatencySeconds
        self.reportMinOccurrences = reportMinOccurrences
        self.reportMinLength = reportMinLength
        self.reportMaxLength = reportMaxLength
        self.matchPrefixLength = matchPrefixLength
        self.matchGapTolerance = matchGapTolerance
        self.discoveredMinOccurrences = discoveredMinOccurrences
        self.suggestMinOccurrences = suggestMinOccurrences
        self.suggestMinLength = suggestMinLength
        self.suggestConfidence = suggestConfidence
        self.offerCooldownHours = offerCooldownHours
        self.dismissalSuppressDays = dismissalSuppressDays
        self.rebuildEveryEvents = rebuildEveryEvents
        self.storeFileNames = storeFileNames
        self.templateMinConfidence = templateMinConfidence
        self.paveAfterConfirmedRuns = paveAfterConfirmedRuns
        self.autoRunEnabled = autoRunEnabled
    }

    enum CodingKeys: String, CodingKey {
        case watchedFolders, excludedExtensions, excludedPathSubstrings
        case burstThresholdCount, burstWindowSeconds, activationDedupeSeconds
        case sessionIdleMinutes, retentionDays, flushBatchSize, flushMaxLatencySeconds
        case reportMinOccurrences, reportMinLength, reportMaxLength
        case matchPrefixLength, matchGapTolerance, discoveredMinOccurrences
        case suggestMinOccurrences, suggestMinLength, suggestConfidence
        case offerCooldownHours, dismissalSuppressDays, rebuildEveryEvents
        case storeFileNames, templateMinConfidence, paveAfterConfirmedRuns, autoRunEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PaveConfig()
        watchedFolders = try c.decodeIfPresent([String].self, forKey: .watchedFolders) ?? d.watchedFolders
        excludedExtensions = try c.decodeIfPresent([String].self, forKey: .excludedExtensions) ?? d.excludedExtensions
        excludedPathSubstrings = try c.decodeIfPresent([String].self, forKey: .excludedPathSubstrings) ?? d.excludedPathSubstrings
        burstThresholdCount = try c.decodeIfPresent(Int.self, forKey: .burstThresholdCount) ?? d.burstThresholdCount
        burstWindowSeconds = try c.decodeIfPresent(Double.self, forKey: .burstWindowSeconds) ?? d.burstWindowSeconds
        activationDedupeSeconds = try c.decodeIfPresent(Double.self, forKey: .activationDedupeSeconds) ?? d.activationDedupeSeconds
        sessionIdleMinutes = try c.decodeIfPresent(Double.self, forKey: .sessionIdleMinutes) ?? d.sessionIdleMinutes
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? d.retentionDays
        flushBatchSize = try c.decodeIfPresent(Int.self, forKey: .flushBatchSize) ?? d.flushBatchSize
        flushMaxLatencySeconds = try c.decodeIfPresent(Double.self, forKey: .flushMaxLatencySeconds) ?? d.flushMaxLatencySeconds
        reportMinOccurrences = try c.decodeIfPresent(Int.self, forKey: .reportMinOccurrences) ?? d.reportMinOccurrences
        reportMinLength = try c.decodeIfPresent(Int.self, forKey: .reportMinLength) ?? d.reportMinLength
        reportMaxLength = try c.decodeIfPresent(Int.self, forKey: .reportMaxLength) ?? d.reportMaxLength
        matchPrefixLength = try c.decodeIfPresent(Int.self, forKey: .matchPrefixLength) ?? d.matchPrefixLength
        matchGapTolerance = try c.decodeIfPresent(Int.self, forKey: .matchGapTolerance) ?? d.matchGapTolerance
        discoveredMinOccurrences = try c.decodeIfPresent(Int.self, forKey: .discoveredMinOccurrences) ?? d.discoveredMinOccurrences
        suggestMinOccurrences = try c.decodeIfPresent(Int.self, forKey: .suggestMinOccurrences) ?? d.suggestMinOccurrences
        suggestMinLength = try c.decodeIfPresent(Int.self, forKey: .suggestMinLength) ?? d.suggestMinLength
        suggestConfidence = try c.decodeIfPresent(Double.self, forKey: .suggestConfidence) ?? d.suggestConfidence
        offerCooldownHours = try c.decodeIfPresent(Double.self, forKey: .offerCooldownHours) ?? d.offerCooldownHours
        dismissalSuppressDays = try c.decodeIfPresent(Double.self, forKey: .dismissalSuppressDays) ?? d.dismissalSuppressDays
        rebuildEveryEvents = try c.decodeIfPresent(Int.self, forKey: .rebuildEveryEvents) ?? d.rebuildEveryEvents
        storeFileNames = try c.decodeIfPresent(Bool.self, forKey: .storeFileNames) ?? d.storeFileNames
        templateMinConfidence = try c.decodeIfPresent(Double.self, forKey: .templateMinConfidence) ?? d.templateMinConfidence
        paveAfterConfirmedRuns = try c.decodeIfPresent(Int.self, forKey: .paveAfterConfirmedRuns) ?? d.paveAfterConfirmedRuns
        autoRunEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoRunEnabled) ?? d.autoRunEnabled
    }

    /// Pretty, sorted-key JSON, matching Store.encoder().
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    /// Missing or corrupt file returns defaults. Never throws.
    public static func load(from url: URL) -> PaveConfig {
        guard let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(PaveConfig.self, from: data)
        else { return PaveConfig() }
        return c
    }

    public func save(to url: URL) throws {
        try PaveConfig.encoder().encode(self).write(to: url, options: .atomic)
    }
}
