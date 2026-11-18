import Foundation

public enum AuroraInsightsDemo {
    /// Synthetic aggregates of the complete collection, shifted into the selected window. Never used as a live fallback.
    /// Collection is presented as starting 20 days before `now`: earlier days stay « non collecté ».
    public static func bundle(filters: AuroraJourneyFilters, population: AuroraInsightsPopulation, now: Date = Date()) -> AuroraInsightsBundle {
        let calendar = AuroraJourneyContract.calendar, zone = AuroraJourneyContract.zone
        let today = calendar.startOfDay(for: now)
        let start = AuroraJourneyContract.day(filters.fromDay)!, end = AuroraJourneyContract.day(filters.toDayExclusive)!
        let collectionStart = calendar.date(byAdding: .day, value: -20, to: today)!
        let generated = Dates.iso(now)
        var days: [Date] = []
        var cursor = max(start, collectionStart)
        while cursor < end && cursor <= today { days.append(cursor); cursor = calendar.date(byAdding: .day, value: 1, to: cursor)! }
        let scale = population == .internalBuilds ? 1 : population == .all ? 9 : 8
        let versions = population == .internalBuilds ? ["1.6.1"] : ["1.6.0"]
        let fInsights = AuroraInsightsFilters(filters, population: population)
        let first = Dates.iso(collectionStart)
        var bundle = AuroraInsightsBundle(population: population, filters: filters)
        func coverage(retention: Int) -> AuroraInsightsCoverage {
            .init(collectionFirstReceivedAt: first, archivedDaysInWindow: 0, archiveAvailableForPopulation: population != .internalBuilds, rawRetentionDays: retention)
        }
        func report<Row: AuroraInsightsRow>(_ rows: [Row], retention: Int = 396) -> AuroraInsightsReport<Row> where Row.Coverage == AuroraInsightsCoverage {
            .init(generatedAt: generated, asOf: generated, filters: fInsights, coverage: coverage(retention: retention), rows: rows)
        }
        var activity: [AuroraActivityRow] = [], sessions: [AuroraSessionsRow] = [], screens: [AuroraScreenRow] = [], dialogs: [AuroraDialogRow] = []
        var actions: [AuroraActionRow] = [], gameplay: [AuroraGameplayRow] = [], timeline: [AuroraTimelineRow] = [], progress: [AuroraProgressRow] = []
        var settings: [AuroraSettingRow] = [], stability: [AuroraStabilityRow] = [], diagnostics: [AuroraDiagnosticRow] = []
        var performance: [AuroraPerformanceRow] = [], cloud: [AuroraCloudRow] = [], privacy: [AuroraPrivacyRow] = [], consents: [AuroraConsentRow] = []
        var context: [AuroraContextRow] = [], notifications: [AuroraNotificationRow] = [], server: [AuroraServerRow] = []
        var history: [AuroraPresenceDayRow] = [], hourly: [AuroraPresenceHourRow] = []
        for (index, date) in days.enumerated() {
            let day = Dates.day(date, timezone: zone)
            let weekday = calendar.component(.weekday, from: date)
            let dau = scale * (5 + (weekday == 1 || weekday == 7 ? 3 : 0) + index % 3)
            activity.append(.init(day: day, dau: dau, wau: min(dau * 3, scale * (12 + index)), mau: scale * (14 + index * 2), newInstallations: scale * (1 + index % 2),
                                  returningInstallations: dau - scale, sessions: dau * 2, accounts: scale / 4, installationsWithContext: dau - 1))
            for version in versions where filters.appVersion == nil || filters.appVersion == version {
                let s = dau * 2
                sessions.append(.init(day: day, appVersion: version, installations: dau, sessionsStarted: s, sessionsMeasured: s - 1, segments: s + 3,
                                      foregroundSeconds: s * 540, adSeconds: s * 25, idleSeconds: s * 60, gridSeconds: s * 380, activeSeconds: s * 455,
                                      endedByQuit: s / 6, medianSessionSeconds: 420, p90SessionSeconds: 1_260, medianActiveSeconds: 350))
                for (screen, views, seconds) in [("home", s, 18), ("grid", s * 3, 120), ("level_select", s, 25), ("settings", scale, 30)] {
                    screens.append(.init(day: day, appVersion: version, screen: screen, installations: min(dau, views), views: views, seconds: views * seconds,
                                         medianSeconds: Double(seconds) * 0.8, leftToBackground: views / 8,
                                         origins: screen == "home" ? ["launch": views / 2, "back": views - views / 2] : ["navigate": views]))
                }
                dialogs.append(.init(day: day, appVersion: version, dialog: "daily_reward", installations: dau / 2, closes: dau / 2, seconds: dau * 3,
                                     medianSeconds: 5, outcomes: ["accept": dau / 2 - 1, "dismiss": 1], screens: ["home": dau / 2]))
                dialogs.append(.init(day: day, appVersion: version, dialog: "premium_offer", installations: scale, closes: scale, seconds: scale * 9,
                                     medianSeconds: 8, outcomes: ["decline": scale - 1, "accept": 1], screens: ["settings": scale]))
                actions.append(.init(day: day, appVersion: version, action: "hint_used", installations: dau / 2, events: dau, valueSum: dau, valuedEvents: dau, screens: ["grid": dau]))
                actions.append(.init(day: day, appVersion: version, action: "share_tapped", installations: scale / 2, events: scale / 2, valueSum: nil, valuedEvents: 0, screens: ["victory": scale / 2]))
                for (mode, level, difficulty, board) in [("campaign", 12 + index, "steady", 6), ("quick", 0, "normal", 7), ("daily", 0, "facile", 6), ("lightpaths", 3, "gentle", 5)] {
                    let runs = mode == "campaign" ? dau : dau / 2
                    gameplay.append(.init(day: day, appVersion: version, mode: mode, level: level, difficulty: difficulty, boardSize: board, outcome: "solved",
                                          installations: min(dau, runs), runs: runs, activeSeconds: runs * 140, medianActiveSeconds: 125, moves: runs * 38,
                                          errors: runs * 2, undos: runs * 3, hints: runs / 2, runsWithHints: runs / 3, runsWithErrors: runs / 2,
                                          scoredRuns: mode == "lightpaths" ? 0 : runs, score: mode == "lightpaths" ? 0 : runs * 820,
                                          maxScore: mode == "lightpaths" ? 0 : runs * 1_000, newBest: runs / 4, ranked: mode == "daily" ? runs : 0,
                                          completionKnown: runs, completionPct: runs * 100))
                    gameplay.append(.init(day: day, appVersion: version, mode: mode, level: level, difficulty: difficulty, boardSize: board, outcome: "back",
                                          installations: max(1, runs / 4), runs: max(1, runs / 4), activeSeconds: max(1, runs / 4) * 60, medianActiveSeconds: 55,
                                          moves: max(1, runs / 4) * 12, errors: max(1, runs / 4), undos: 1, hints: 0, runsWithHints: 0, runsWithErrors: 1,
                                          scoredRuns: 0, score: 0, maxScore: 0, newBest: 0, ranked: 0, completionKnown: max(1, runs / 4), completionPct: max(1, runs / 4) * 40))
                    timeline.append(.init(day: day, appVersion: version, mode: mode, level: level, difficulty: difficulty, installations: max(1, runs / 5),
                                          timelines: max(1, runs / 5), actions: max(1, runs / 5) * 36, truncated: 0, partial: 0,
                                          firstActionDs: max(1, runs / 5) * 32, medianFirstActionDs: 30, lastActionDs: max(1, runs / 5) * 1_350,
                                          byKind: mode == "lightpaths" ? ["t": max(1, runs / 5) * 36] : ["f": max(1, runs / 5) * 24, "x": max(1, runs / 5) * 8, "u": max(1, runs / 5) * 3, "h": 1]))
                }
                progress.append(.init(day: day, appVersion: version, kind: "streak", code: "current", installations: dau / 2, events: dau / 2, valueMax: 4 + index))
                progress.append(.init(day: day, appVersion: version, kind: "chapter", code: "chapter_2", installations: scale / 2, events: scale / 2, valueMax: 2))
                settings.append(.init(day: day, appVersion: version, setting: "vibrations", value: "off", installations: 1, changes: 1))
                settings.append(.init(day: day, appVersion: version, setting: "music", value: "off", installations: scale / 4, changes: scale / 4))
                stability.append(.init(day: day, appVersion: version, installations: dau, launches: s, coldStarts: dau, stopsWhileOnScreen: index % 4 == 0 ? 1 : 0,
                                       installationsWithStops: index % 4 == 0 ? 1 : 0, errorEvents: 2, installationsWithErrors: 1, sessionsWithErrors: 1))
                diagnostics.append(.init(day: day, appVersion: version, kind: "exception", exceptionType: "NullReferenceException", fingerprint: "6e816f005df565b4",
                                         installations: 1, events: 2, sessions: 1, screens: ["grid": 2]))
                for (model, os) in [("iPhone15,2", "18"), ("iPhone17,1", "19")] {
                    let frames = dau * 36_000
                    performance.append(.init(day: day, appVersion: version, deviceModel: model, osMajor: os, installations: dau / 2, stretches: dau, frames: frames,
                                             slowFrames: frames / (model == "iPhone15,2" ? 60 : 200), verySlowFrames: frames / 3_000, maxFrameMs: model == "iPhone15,2" ? 180 : 90,
                                             fpsFrames: frames * (model == "iPhone15,2" ? 58 : 60), memoryPeakMbMax: 520, memoryPeakMbMedian: 410, startups: dau,
                                             startupMsMedian: model == "iPhone15,2" ? 2_100 : 1_400, thermalSerious: 0, lowPower: 1))
                }
                cloud.append(.init(day: day, appVersion: version, op: "sync_save", outcome: "success", installations: scale / 2, ops: dau, medianMs: 180, p90Ms: 420, maxMs: 1_900, statuses: ["200": dau]))
                cloud.append(.init(day: day, appVersion: version, op: "sync_save", outcome: "no_answer", installations: 1, ops: 1, medianMs: 10_000, p90Ms: 10_000, maxMs: 10_000, statuses: ["0": 1]))
                privacy.append(.init(day: day, appVersion: version, statisticsBasis: "regional_default", statisticsSource: "regional_rule", regionClass: "other",
                                     attStatus: "not_determined", installations: dau - 2, sessions: s - 3))
                privacy.append(.init(day: day, appVersion: version, statisticsBasis: "explicit_granted", statisticsSource: "settings", regionClass: "eea_uk",
                                     attStatus: "denied", installations: 2, sessions: 3))
                consents.append(.init(day: day, appVersion: version, purpose: "statistics", state: "granted", source: "settings", installations: 1, events: 1))
                if population != .internalBuilds, index % 5 == 2 {
                    consents.append(.init(day: day, appVersion: version, purpose: "statistics", state: "withdrawn", source: "anonymous_count", installations: nil, events: 1))
                }
                for (dimension, value, share) in [("device_model", "iPhone15,2", 2), ("device_model", "iPhone17,1", 2), ("os_major", "18", 2), ("os_major", "19", 2),
                                                 ("storefront", "CHE", 2), ("storefront", "FRA", 2), ("game_language", "fr", 1), ("connection", "wifi", 1),
                                                 ("ad_config_revision", "12", 1)] {
                    context.append(.init(day: day, appVersion: version, dimension: dimension, value: value, installations: (dau - 1) / share))
                }
                notifications.append(.init(day: day, appVersion: version, kind: "grove_reminder", destination: "daily", installations: scale / 2, opens: scale / 2))
            }
            server.append(.init(day: day, eventsReceived: dau * 60, installationsSending: dau + 1, coreEvents: dau * 25, extendedEvents: dau * 35,
                                rejections: index % 6 == 0 ? ["rate_limited": 1] : [:], presenceMinutes: 1_440, presencePeak: dau / 3 + 1))
            history.append(.init(day: day, peakInApp: dau / 3, peakOnGrid: dau / 4, peakAt: Dates.iso(calendar.date(byAdding: .hour, value: 20, to: date)!),
                                 avgInApp: Double(dau) / 9, minutesObserved: date == today ? max(1, calendar.dateComponents([.minute], from: today, to: now).minute ?? 1) : 1_440,
                                 internalPeakInApp: 1, complete: date != today))
            if AuroraInsightsContract.span(filters) <= 31 {
                for hour in [8, 12, 20] {
                    hourly.append(.init(hour: day + String(format: "T%02d:00:00", hour), avgInApp: Double(dau) / Double(hour == 20 ? 4 : 8),
                                        peakInApp: dau / (hour == 20 ? 3 : 6), avgOnGrid: Double(dau) / 10, peakOnGrid: dau / 6, minutesObserved: 60))
                }
            }
        }
        bundle.set(report(activity, retention: 761)); bundle.set(report(sessions)); bundle.set(report(screens)); bundle.set(report(dialogs))
        bundle.set(report(actions)); bundle.set(report(gameplay, retention: 761)); bundle.set(report(timeline, retention: 90)); bundle.set(report(progress, retention: 761))
        bundle.set(report(settings)); bundle.set(report(stability, retention: 761)); bundle.set(report(diagnostics, retention: 90))
        bundle.set(report(performance, retention: 90)); bundle.set(report(cloud, retention: 90)); bundle.set(report(privacy)); bundle.set(report(consents, retention: 761))
        bundle.set(report(context)); bundle.set(report(notifications))
        bundle.set(AuroraInsightsReport<AuroraServerRow>(generatedAt: generated, asOf: generated,
            filters: .init(fromDay: filters.fromDay, toDayExclusive: filters.toDayExclusive, appVersion: nil, population: .all),
            coverage: .init(storage: .init(databaseBytes: 48_000_000, journeyEventsBytes: 21_000_000, journeyEventsRowsEstimate: 180_000,
                                           reportArchiveBytes: 900_000, presenceMinutesBytes: 2_400_000, presenceLiveRows: 3),
                            functions: [.init(function: "record_journey_events_v1", calls: 12_400, meanMs: 0.8), .init(function: "record_presence_v1", calls: 51_000, meanMs: 0.2)],
                            requestLogs: "Supabase keeps its own API and database logs (with IP addresses) under its own retention; they are not read here"),
            rows: server))
        let presence = AuroraPresenceCoverage(firstSignalAt: first, samplerMinutesToday: history.last?.minutesObserved)
        bundle.live = .init(generatedAt: generated, filters: .init(), coverage: presence, rows: [
            .init(distribution: "app_store", appVersion: "1.6.0", state: "grid", gameMode: "campaign", players: 3),
            .init(distribution: "app_store", appVersion: "1.6.0", state: "grid", gameMode: "daily", players: 1),
            .init(distribution: "app_store", appVersion: "1.6.0", state: "app", gameMode: "none", players: 2),
            .init(distribution: "testflight", appVersion: "1.6.1", state: "app", gameMode: "none", players: 1)
        ])
        bundle.history = .init(generatedAt: generated, filters: .init(fromDay: filters.fromDay, toDayExclusive: filters.toDayExclusive), coverage: presence, rows: history)
        if bundle.hourlyRequested {
            bundle.hourly = .init(generatedAt: generated, filters: .init(fromDay: filters.fromDay, toDayExclusive: filters.toDayExclusive), coverage: presence, rows: hourly)
        }
        return bundle
    }
}
