import Foundation

public enum Analytics {
    /// Invalid rows are set aside and counted: one corrupted run must not hide every other player.
    public static func unique(_ events: [Completion], interval: DateInterval) -> (events: [Completion], ignored: Int) {
        var seen = Set<String>(), ignored = 0
        let kept = events.filter {
            guard $0.valid, let date = $0.date else { ignored += 1; return false }
            return date >= interval.start && date < interval.end && seen.insert($0.user_id.lowercased() + ":" + $0.run_id.lowercased()).inserted
        }
        return (kept, ignored)
    }
    public static func ratio(_ numerator: Double, _ denominator: Double) -> Double? {
        denominator > 0 ? (numerator / denominator * 10000).rounded() / 100 : nil
    }
    public static func arpdau(revenue: [Decimal], active: [Int]) -> Decimal? {
        guard !revenue.isEmpty, revenue.count == active.count, active.reduce(0, +) > 0 else { return nil }
        var value = revenue.reduce(Decimal.zero, +) / Decimal(active.reduce(0, +))
        var rounded = Decimal(); NSDecimalRound(&rounded, &value, 4, .plain); return rounded
    }
    public static func directory(profiles: [Profile], events: [Completion], activeEntitlements: Set<String>?, range: Timeframe, timezone: TimeZone, now: Date = Date(), entitlementNote: String? = nil) throws -> PlayerDirectory {
        let (valid, ignored) = unique(events, interval: range.interval(now: now, timezone: timezone))
        let events = valid.filter { $0.date! <= now }
        var ids = Set<String>(); var publicIDs = Set<String>()
        for profile in profiles {
            guard UUID(uuidString: profile.user_id) != nil, UUID(uuidString: profile.public_id) != nil, profile.adventure_step >= 1,
                  ids.insert(profile.user_id.lowercased()).inserted, publicIDs.insert(profile.public_id.lowercased()).inserted else {
                throw GameMetrikError.message("Le répertoire contient un profil invalide ou dupliqué.")
            }
        }
        let grouped = Dictionary(grouping: events, by: { $0.user_id.lowercased() })
        let players = profiles.map { profile -> Player in
            let rows = grouped[profile.user_id.lowercased()] ?? []
            let count = Double(rows.count)
            let elapsed = rows.reduce(0) { $0 + $1.elapsed_ms } / 60000
            let name = profile.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Player(id: profile.public_id, name: name.isEmpty ? "Sans pseudonyme" : name, hasName: !name.isEmpty,
                          adventureStep: profile.adventure_step, jardinPaisible: activeEntitlements.map { $0.contains(profile.user_id.lowercased()) },
                          completions: rows.count, playMinutes: elapsed, averageMinutes: count > 0 ? elapsed / count : nil,
                          scoreRatio: ratio(rows.reduce(0) { $0 + $1.score }, rows.reduce(0) { $0 + $1.maximum_score }),
                          perfectRate: ratio(Double(rows.filter(\.perfect).count), count), firstPlayed: rows.compactMap(\.date).min(), lastPlayed: rows.compactMap(\.date).max(),
                          modes: breakdown(rows, mode: true), difficulties: breakdown(rows, mode: false), trend: trend(rows, timezone: timezone),
                          moves: mean(rows.map(\.moves)), hints: mean(rows.map(\.hints)), mistakes: mean(rows.map(\.mistakes)), undos: mean(rows.map(\.undos)), completionHours: hours(rows, timezone: timezone))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let count = events.count
        let active = Set(events.map { $0.user_id.lowercased() }).count
        let duration = events.reduce(0) { $0 + $1.elapsed_ms } / 60000
        return PlayerDirectory(players: players, completions: count, activePlayers: active, trend: trend(events, timezone: timezone), kpis: [
            KPI(id: "active", label: "Joueurs actifs", value: Double(active), hint: "Joueurs ayant terminé au moins une partie sur la période."),
            KPI(id: "completions", label: "Parties terminées", value: Double(count)),
            KPI(id: "duration", label: "Durée moyenne", value: count > 0 ? duration / Double(count) : nil, unit: "duration", hint: "Minutes par partie terminée."),
            KPI(id: "score", label: "Score pondéré", value: ratio(events.reduce(0) { $0 + $1.score }, events.reduce(0) { $0 + $1.maximum_score }), unit: "percent", hint: "Somme des scores divisée par la somme des scores maximum.")
        ], modes: breakdown(events, mode: true), difficulties: breakdown(events, mode: false), entitlementNote: entitlementNote, generatedAt: now, dataNote: ignored > 0 ? "\(ignored) partie(s) ignorée(s) : date, identifiant ou valeur négative invalide. Les autres parties sont comptées normalement." : nil, completionHours: hours(events, timezone: timezone), timezone: timezone.identifier)
    }
    private static func hours(_ events: [Completion], timezone: TimeZone) -> [CompletionHour] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timezone
        let counts = Dictionary(grouping: events) { calendar.component(.hour, from: $0.date!) }.mapValues(\.count)
        return (0..<24).map { CompletionHour(hour: $0, completions: counts[$0] ?? 0) }
    }
    private static func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
    private static func breakdown(_ events: [Completion], mode: Bool) -> [Breakdown] {
        let grouped = Dictionary(grouping: events) { mode ? $0.mode : String($0.difficulty) }
        let modeLabels = ["campaign": "Campagne", "quick": "Partie rapide", "daily": "Défi quotidien"]
        let difficultyLabels = ["Très facile", "Facile", "Intermédiaire", "Difficile", "Expert"]
        return grouped.map { key, rows in
            Breakdown(name: mode ? (modeLabels[key] ?? key) : (Int(key).flatMap { difficultyLabels.indices.contains($0) ? difficultyLabels[$0] : nil } ?? "Niveau \(key)"), value: Double(rows.count), share: Double(rows.count) / Double(events.count) * 100)
        }.sorted { $0.value == $1.value ? $0.name < $1.name : $0.value > $1.value }
    }
    private static func trend(_ events: [Completion], timezone: TimeZone) -> [PlayerDay] {
        Dictionary(grouping: events, by: { Dates.day($0.date!, timezone: timezone) }).map { day, rows in
            PlayerDay(id: day, completions: rows.count, minutes: rows.reduce(0) { $0 + $1.elapsed_ms } / 60000)
        }.sorted { $0.id < $1.id }
    }
}
