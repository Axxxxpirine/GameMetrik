import Foundation

public enum Timeframe: String, CaseIterable, Codable, Identifiable, Sendable {
    case today, week = "7d", month = "30d", quarter = "90d", year = "1y", all
    public var id: String { rawValue }
    public var label: String {
        switch self { case .today: "Aujourd’hui"; case .week: "7 jours"; case .month: "30 jours"; case .quarter: "90 jours"; case .year: "1 an"; case .all: "Tout" }
    }
    public var days: Int? {
        switch self { case .today: 1; case .week: 7; case .month: 30; case .quarter: 90; case .year: 365; case .all: nil }
    }
    public func interval(now: Date, timezone: TimeZone) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let today = calendar.startOfDay(for: now)
        let start = days.map { calendar.date(byAdding: .day, value: -($0 - 1), to: today)! } ?? .distantPast
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: today)!)
    }
}

public struct Game: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var slug: String
    public var name: String
    public var icon: String
    public var description: String?
    public var status: String
    public var platforms: [String]
    public var currentVersion: String
    public var integrations: Integrations
    public struct Integrations: Codable, Hashable, Sendable {
        public var admobAppIds: [String]?
        public var admobAppId: String?
        public var appleAppId: String?
        public var bundleId: String?
        public var googlePackageName: String?
        public var supabaseProjectRef: String?
        /// Selects a game-specific analytics contract. Unknown or absent values keep the legacy reader.
        public var analyticsSource: String?
    }
    public var hasJardinPaisible: Bool { slug == "aurora-grove" || integrations.bundleId == "com.auroragrove.puzzle" }
    public var usesAuroraJourney: Bool { slug == "aurora-grove" || integrations.analyticsSource == "aurora_journey" }
    public var usesBallparkAnalytics: Bool { integrations.analyticsSource == "ballpark" }
    public var statusLabel: String { status == "active" ? "Actif" : status == "draft" ? "Brouillon" : "Archivé" }
}

public struct KPI: Codable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var value: Double?
    public var unit: String
    public var change: Double?
    public var state: String
    public var source: String
    public var hint: String?
    public var changeDirection: String?
    public var coverage: Coverage?
    /// Totals in their original currencies; value remains the unconverted CHF total, when possible.
    public var amountsByCurrency: [String: Double]?
    public struct Coverage: Codable, Sendable {
        public var status: String
        public var availableDays: Int
        public var expectedDays: Int
    }
    public init(id: String, label: String, value: Double?, unit: String = "number", change: Double? = nil, source: String = "Calcul natif", hint: String? = nil) {
        self.id = id; self.label = label; self.value = value; self.unit = unit; self.change = change
        self.state = value == nil ? "unknown" : "available"; self.source = source; self.hint = hint
    }
}
public struct TrendPoint: Codable, Identifiable, Sendable {
    public var date: String
    public var revenue: Double
    public var players: Int
    public var installs: Int
    public var revenueAvailable: Bool?
    public var playersAvailable: Bool?
    public var installsAvailable: Bool?
    public var newPlayers: Int?
    public var revenueByCurrency: [String: Double]?
    public var appleIAPNetUnits: Int?
    public var id: String { date }
}
public struct Breakdown: Codable, Identifiable, Sendable {
    public var name: String
    public var value: Double
    public var share: Double
    public var id: String { name }
}
public struct Ranking: Codable, Identifiable, Sendable {
    public var gameId: String
    public var name: String
    public var icon: String
    public var revenue: Double
    public var dau: Int
    public var installs: Int
    public var change: Double
    public var id: String { gameId }
}
public struct DashboardAlert: Codable, Identifiable, Sendable {
    public var id: String
    public var severity: String
    public var title: String
    public var description: String
}
public struct Dashboard: Codable, Sendable {
    public var scope: String
    public var gameId: String?
    public var timeframe: Timeframe
    public var generatedAt: String
    public var timezone: String
    public var currency: String
    public var kpis: [KPI]
    public var trend: [TrendPoint]
    public var platformBreakdown: [Breakdown]
    public var countryBreakdown: [Breakdown]
    public var rankings: [Ranking]
    public var alerts: [DashboardAlert]
    public var dataQuality: Quality
    public var sourceDays: [SourceDay]?
    public var revenueDetails: RevenueDetails?
    public struct Quality: Codable, Sendable {
        public var completeness: Double
        public var note: String
    }
}
public struct SourceDay: Codable, Sendable {
    public var gameID: String
    public var provider: String
    public var date: String
    public var status: String
    public var readAt: String?
    public var timezone: String?
    public var revenueCHF: Double?
    public var adImpressions: Int?
    public var sourceHasError: Bool
    public var appleIAPNetUnits: Int?
}
public struct Review: Codable, Identifiable, Sendable {
    public var id: String
    public var provider: String
    public var gameId: String
    public var gameName: String
    public var country: String
    public var rating: Int
    public var title: String?
    public var body: String
    public var version: String?
    public var publishedAt: String
}
public struct Profile: Codable, Sendable {
    public var user_id: String
    public var public_id: String
    public var display_name: String?
    public var adventure_step: Int
    public init(userID: String, publicID: String, name: String?, step: Int) {
        user_id = userID; public_id = publicID; display_name = name; adventure_step = step
    }
}
public struct Completion: Codable, Sendable {
    public var user_id: String
    public var run_id: String
    public var mode: String
    public var difficulty: Int
    public var elapsed_ms: Double
    public var score: Double
    public var maximum_score: Double
    public var moves: Double
    public var hints: Double
    public var mistakes: Double
    public var undos: Double
    public var perfect: Bool
    public var completed_at: String
    public init(userID: String, runID: String, mode: String = "campaign", difficulty: Int = 0, elapsedMS: Double = 180_000, score: Double = 800, maximumScore: Double = 1000, moves: Double = 20, hints: Double = 0, mistakes: Double = 0, undos: Double = 0, perfect: Bool = false, date: Date) {
        user_id = userID; run_id = runID; self.mode = mode; self.difficulty = difficulty
        elapsed_ms = elapsedMS; self.score = score; maximum_score = maximumScore
        self.moves = moves; self.hints = hints; self.mistakes = mistakes; self.undos = undos
        self.perfect = perfect; completed_at = Dates.iso(date)
    }
    public var date: Date? { Dates.parse(completed_at) }
    public var valid: Bool {
        // New modes or difficulty levels are valid data from a newer game version, shown under their own name.
        date != nil && UUID(uuidString: user_id) != nil && UUID(uuidString: run_id) != nil && difficulty >= 0
        && !mode.isEmpty && mode.count <= 64
        && [elapsed_ms, score, maximum_score, moves, hints, mistakes, undos].allSatisfy { $0.isFinite && $0 >= 0 }
    }
}
public enum Dates {
    public static func parse(_ value: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle().parse(value))
    }
    public static func iso(_ date: Date) -> String { date.formatted(.iso8601) }
    public static func day(_ date: Date, timezone: TimeZone) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: timezone).year().month().day())
    }
}
public struct PlayerDay: Identifiable, Sendable {
    public var id: String
    public var completions: Int
    public var minutes: Double
}
public struct Player: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var hasName: Bool
    public var adventureStep: Int
    public var jardinPaisible: Bool?
    public var completions: Int
    public var playMinutes: Double
    public var averageMinutes: Double?
    public var scoreRatio: Double?
    public var perfectRate: Double?
    public var firstPlayed: Date?
    public var lastPlayed: Date?
    public var modes: [Breakdown]
    public var difficulties: [Breakdown]
    public var trend: [PlayerDay]
    public var moves: Double?
    public var hints: Double?
    public var mistakes: Double?
    public var undos: Double?
    public var completionHours: [CompletionHour] = []
    public var favoriteMode: String { modes.first?.name ?? "—" }
}
public struct PlayerDirectory: Sendable {
    public var players: [Player]
    public var completions: Int
    public var activePlayers: Int
    public var trend: [PlayerDay]
    public var kpis: [KPI]
    public var modes: [Breakdown]
    public var difficulties: [Breakdown]
    public var entitlementNote: String?
    public var generatedAt: Date
    /// Discloses completions set aside as invalid; nil when every row was usable.
    public var dataNote: String? = nil
    public var completionHours: [CompletionHour] = []
    public var timezone: String? = nil
}
public enum GameMetrikError: Error, LocalizedError, Equatable {
    case message(String)
    case http(Int)
    public var errorDescription: String? {
        switch self {
        case .message(let message): message
        case .http(401): "La session a expiré. Reconnecte ton compte dans les réglages."
        case .http(403): "Accès refusé par le service. Vérifie les droits du compte et les règles d’accès."
        case .http(404): "Ces données ne sont pas encore disponibles dans ton espace."
        case .http(429): "Le service reçoit trop de demandes. Réessaie dans un instant."
        case .http(let code): "Le service est indisponible (HTTP \(code)). Réessaie plus tard."
        }
    }
}
