import Foundation

public enum AuroraJourneyDemo {
    /// Synthetic aggregates, shifted into the selected window. Never used as a live fallback.
    public static func bundle(filters: AuroraJourneyFilters, now: Date = Date()) -> AuroraJourneyBundle {
        let calendar = AuroraJourneyContract.calendar
        let start = AuroraJourneyContract.day(filters.fromDay)!
        let end = AuroraJourneyContract.day(filters.toDayExclusive)!
        let today = calendar.startOfDay(for: now)
        let first = max(start, calendar.date(byAdding: .day, value: -22, to: today)!)
        let recent = min(calendar.date(byAdding: .day, value: -1, to: end)!, today)
        let days = Array(Set([first, recent])).sorted()
        func ratio(_ n: Int, _ d: Int, mature: Bool = true) -> AuroraJourneyRatio {
            mature ? .init(numerator: n, denominator: d, value: (Double(n) / Double(d) * 10_000).rounded() / 10_000) : .immature
        }
        var funnel: [AuroraJourneyFunnelRow] = [], opens: [AuroraJourneyRetentionRow] = [], completed: [AuroraJourneyRetentionRow] = []
        for day in days where day < end {
            let age = calendar.dateComponents([.day], from: day, to: today).day!
            let date = Dates.day(day, timezone: AuroraJourneyContract.zone)
            for version in ["1.4.1", "1.5.0"] where filters.appVersion == nil || filters.appVersion == version {
                let size = version == "1.5.0" ? 3 : 1
                funnel.append(.init(cohortDay: date, appVersion: version, cohortSize: size, window: "J0-J6", mature: age >= 10,
                                    tutorialStarted: ratio(size == 3 ? 2 : 1, size, mature: age >= 10),
                                    tutorialCompleted: ratio(1, size, mature: age >= 10), firstRunCompleted: ratio(1, size, mature: age >= 10),
                                    anonymousFirstLaunches: size == 3 ? 6 : 0, consentAccepted: size == 3 ? 4 : 0, consentDeclined: size == 3 ? 1 : 0,
                                    measuredShare: size == 3 ? ratio(3, 6) : .init(numerator: 1, denominator: 0, value: nil, reason: .notCollected)))
                opens.append(.init(cohortDay: date, appVersion: version, cohortSize: size,
                                   returnD1: ratio(size == 3 ? 2 : 0, size, mature: age >= 5),
                                   returnD7: ratio(size == 3 ? 1 : 0, size, mature: age >= 11), returnD7D13: ratio(1, size, mature: age >= 17)))
                completed.append(.init(cohortDay: date, appVersion: version, cohortSize: 1,
                                       returnD1: ratio(size == 3 ? 1 : 0, 1, mature: age >= 5), returnD7: ratio(0, 1, mature: age >= 11),
                                       returnD7D13: ratio(size == 3 ? 0 : 1, 1, mature: age >= 17)))
            }
        }
        let coverage = AuroraJourneyCoverage(collectionFirstReceivedAt: Dates.iso(start), archivedDaysInWindow: 0,
            graceDays: 3, consentRequired: true, attribution: "not_collected", cohortDefinition: AuroraJourneyContract.cohortDefinition,
            firstOpenInWindow: .init(newInstall: funnel.reduce(0) { $0 + $1.cohortSize }, newInstallLateConsent: 1, newInstallKnownAccount: 1, excludedSuspicious: 1, existingPlayer: 1, unknown: 0),
            anonymousInWindow: .init(firstLaunchNewInstall: funnel.reduce(0) { $0 + $1.anonymousFirstLaunches }, firstLaunchExistingPlayer: 0,
                                    consentAccepted: funnel.reduce(0) { $0 + $1.consentAccepted }, consentDeclined: funnel.reduce(0) { $0 + $1.consentDeclined }),
            rejectionsInWindow: ["clock_ahead": 1])
        func report<R>(_ kind: AuroraJourneyReportKind, _ rows: [R]) -> AuroraJourneyReport<R> {
            .init(contractVersion: 1, report: kind, generatedAt: Dates.iso(now), asOf: Dates.iso(now), timezone: "Europe/Zurich", filters: filters, coverage: coverage, rows: rows)
        }
        let runs: [AuroraJourneyRunRow] = [
            .init(appVersion: "1.5.0", mode: .campaign, level: 1, games: 2, startObserved: 2, solved: 1, abandonedRestart: 0, abandonedNewPuzzle: 0, openRecent: 0, leftNotResumed: 0, appStoppedWhilePlaying: 0, leftAppReturned: 0, leftAppNotReturned: 1, noEndObserved: 0),
            .init(appVersion: "1.5.0", mode: .quick, level: 0, games: 3, startObserved: 2, solved: 1, abandonedRestart: 1, abandonedNewPuzzle: 0, openRecent: 0, leftNotResumed: 0, appStoppedWhilePlaying: 1, leftAppReturned: 0, leftAppNotReturned: 0, noEndObserved: 0),
            .init(appVersion: "1.5.0", mode: .lightpaths, level: 12, games: 5, startObserved: 5, solved: 2, abandonedRestart: 0, abandonedNewPuzzle: 0, openRecent: 1, leftNotResumed: 0, appStoppedWhilePlaying: 0, leftAppReturned: 1, leftAppNotReturned: 0, noEndObserved: 1)
        ]
        let quality = AuroraJourneyQualityRow(day: Dates.day(first, timezone: AuroraJourneyContract.zone), appVersion: "1.5.0", platform: .ios,
            installations: 7, events: 19, byEvent: ["first_open": 7, "app_opened": 4, "tutorial_started": 2, "tutorial_completed": 1, "run_started": 3, "run_completed": 2],
            firstOpenNewInstall: 6, firstOpenExistingPlayer: 1, firstOpenUnknown: 0, firstOpenLateConsent: 1, installationsReportingLosses: 1,
            lostEventsReported: 3, launchesAfterForegroundStop: 1)
        var result = AuroraJourneyBundle()
        result.funnel = report(.funnel, funnel); result.retentionOpen = report(.retentionOpen, opens)
        result.retentionCompleted = report(.retentionCompleted, completed)
        result.runs = report(.runs, runs.filter { filters.appVersion == nil || $0.appVersion == filters.appVersion })
        result.quality = report(.quality, filters.appVersion == nil || filters.appVersion == quality.appVersion ? [quality] : [])
        var steps: [AuroraJourneyStepsRow] = []
        let notCollected = AuroraJourneyRatio(numerator: 0, denominator: 0, value: nil, reason: .notCollected)
        for day in days where day < end {
            let age = calendar.dateComponents([.day], from: day, to: today).day!
            let date = Dates.day(day, timezone: AuroraJourneyContract.zone)
            for version in ["1.5.0", "1.5.1"] where filters.appVersion == nil || filters.appVersion == version {
                if version == "1.5.0" {
                    steps.append(.init(cohortDay: date, appVersion: version, firstLaunches: 9, stepsOpen: 0,
                                       measuredShare: .init(numerator: 0, denominator: 9, value: 0), tutorialStarted: notCollected,
                                       tutorialCompleted: notCollected, solved1: notCollected, solved3: notCollected, solved10: notCollected,
                                       returnD1: notCollected, returnD7D13: notCollected))
                } else {
                    let week = age >= 10
                    steps.append(.init(cohortDay: date, appVersion: version, firstLaunches: 20, stepsOpen: 14,
                                       measuredShare: ratio(14, 20), tutorialStarted: ratio(13, 14, mature: week),
                                       tutorialCompleted: ratio(11, 14, mature: week), solved1: ratio(10, 14, mature: week),
                                       solved3: ratio(7, 14, mature: week), solved10: ratio(3, 14, mature: week),
                                       returnD1: ratio(6, 14, mature: age >= 5), returnD7D13: ratio(4, 14, mature: age >= 17)))
                }
            }
        }
        result.steps = .init(generatedAt: Dates.iso(now), asOf: Dates.iso(now), filters: .init(filters),
                             coverage: .init(stepsFirstDay: Dates.day(start, timezone: AuroraJourneyContract.zone), graceDays: 3, identifier: "none",
                                             regionRule: "storefront outside the EEA and the United Kingdom unless turned off; inside them, or unknown, only with the usage-statistics consent",
                                             cohortDefinition: "anonymous new installations whose steps may be reported (steps_open), dated by the Zurich day of their first launch"),
                             rows: steps)
        result.monetization = monetization(filters: filters, days: days.filter { $0 < end }, today: today, now: now)
        return result
    }

    /// Fictitious measured monetization: two currencies kept apart, a test ad at 0 with unknown precision,
    /// a failed load, a Peaceful Grove journey, one mature and one immature cohort of the Light Paths test.
    static func monetization(filters: AuroraJourneyFilters, days: [Date], today: Date, now: Date) -> AuroraMonetizationBundle {
        let version = "1.5.2", calendar = AuroraJourneyContract.calendar
        let included = filters.appVersion == nil || filters.appVersion == version
        let window = AuroraMonetizationFilters(filters)
        let coverage = AuroraMonetizationCoverage(collectionFirstReceivedAt: days.first.map(Dates.iso),
            collectionRule: "on by default when the App Store storefront is known and outside the EEA and the United Kingdom; off by default inside them or while the storefront is unknown (Android, editor); an explicit choice in Settings is kept")
        var ads: [AuroraAdRow] = [], loads: [AuroraAdLoadRow] = [], premium: [AuroraPremiumRow] = [], cohorts: [AuroraExperimentRow] = []
        for (index, date) in days.enumerated() where included {
            let day = Dates.day(date, timezone: AuroraJourneyContract.zone)
            ads.append(.init(day: day, appVersion: version, platform: .ios, format: .interstitial, placement: .next, gameMode: .campaign,
                             installations: 12, opportunities: 40,
                             decisions: ["show": 14, "frequency": 12, "time_gap": 6, "discovery": 4, "not_ready": 2, "premium": 2],
                             showRequested: 14, opened: 13, impressions: 13, closed: 12, displayFailed: 1, paidEvents: 13,
                             revenue: [.init(currency: "CHF", precision: .precise, valueMicros: 41_250, paidEvents: 5),
                                       .init(currency: "EUR", precision: .estimated, valueMicros: 63_400, paidEvents: 8)]))
            ads.append(.init(day: day, appVersion: version, platform: .ios, format: .rewarded, placement: .hint, gameMode: .campaign,
                             installations: 5, opportunities: 9, decisions: ["offered": 5, "show": 3, "cancelled": 1],
                             showRequested: 3, opened: 3, impressions: 3, closed: 3, displayFailed: 0,
                             rewardsGranted: 2, rewardsNotGranted: 1, paidEvents: 3,
                             revenue: [.init(currency: "CHF", precision: .precise, valueMicros: 30_000, paidEvents: 2),
                                       .init(currency: "CHF", precision: .unknown, valueMicros: 0, paidEvents: 1)]))
            if index == 0 {
                ads.append(.init(day: day, appVersion: version, platform: .android, format: .interstitial, placement: .next, gameMode: .quick,
                                 installations: 4, opportunities: 6, decisions: ["show": 2, "day_cap": 4],
                                 showRequested: 2, opened: 2, impressions: 2, closed: 2, displayFailed: 0, paidEvents: 2,
                                 revenue: [.init(currency: "EUR", precision: .publisherProvided, valueMicros: 18_000, paidEvents: 2)]))
                loads.append(.init(day: day, appVersion: version, platform: .android, format: .interstitial, installations: 4,
                                   requested: 4, loaded: 3, failed: 1, errors: ["3": 1]))
            }
            loads.append(.init(day: day, appVersion: version, platform: .ios, format: .interstitial, installations: 12,
                               requested: 20, loaded: 17, failed: 3, errors: ["1": 2, "-1": 1]))
            loads.append(.init(day: day, appVersion: version, platform: .ios, format: .rewarded, installations: 5,
                               requested: 6, loaded: 6, failed: 0, errors: [:]))
            premium.append(.init(day: day, appVersion: version, platform: .ios, placement: .home, installations: 6,
                steps: ["offer_viewed": 7, "sign_in_requested": 3, "sign_in_completed": 2, "sign_in_cancelled": 1, "confirm_viewed": 2,
                        "purchase_started": 2, "purchase_validated": 1, "purchase_failed": 1],
                installationsByStep: ["offer_viewed": 6, "sign_in_requested": 3, "sign_in_completed": 2, "sign_in_cancelled": 1,
                                      "confirm_viewed": 2, "purchase_started": 2, "purchase_validated": 1, "purchase_failed": 1]))
            premium.append(.init(day: day, appVersion: version, platform: .ios, placement: .settings, installations: 2,
                steps: ["offer_viewed": 2, "entitlement_unknown": 1], installationsByStep: ["offer_viewed": 2, "entitlement_unknown": 1]))
            let age = calendar.dateComponents([.day], from: date, to: today).day!
            func ratio(_ n: Int, _ d: Int, mature: Bool) -> AuroraJourneyRatio {
                mature ? .init(numerator: n, denominator: d, value: (Double(n) / Double(d) * 10_000).rounded() / 10_000) : .immature
            }
            for (variant, size) in [(AuroraAdVariant.lpControl, 40), (.lpTreatment, 38)] {
                let week = age >= 10, treated = variant == .lpTreatment
                cohorts.append(.init(cohortDay: day, variant: variant, appVersion: version, cohortSize: size, mature: week,
                    returnD1: ratio(treated ? 16 : 18, size, mature: age >= 5), returnD7: ratio(treated ? 8 : 9, size, mature: age >= 11),
                    lightpathsSolved: week ? (treated ? 118 : 131) : nil, interstitialImpressions: week ? (treated ? 52 : 30) : nil,
                    lightpathsInterstitials: week ? (treated ? 22 : 0) : nil, rewardedImpressions: week ? (treated ? 6 : 7) : nil,
                    revenue: week ? [.init(currency: "CHF", valueMicros: treated ? 214_000 : 128_500, paidEvents: treated ? 31 : 19),
                                     .init(currency: "EUR", valueMicros: treated ? 96_000 : 61_000, paidEvents: treated ? 14 : 9)] : nil))
            }
        }
        var result = AuroraMonetizationBundle()
        result.ads = .init(report: .ads, generatedAt: Dates.iso(now), asOf: Dates.iso(now), filters: window, coverage: coverage, rows: ads)
        result.adLoads = .init(report: .adLoads, generatedAt: Dates.iso(now), asOf: Dates.iso(now), filters: window, coverage: coverage, rows: loads)
        result.premium = .init(report: .premium, generatedAt: Dates.iso(now), asOf: Dates.iso(now), filters: window, coverage: coverage, rows: premium)
        result.experiment = .init(report: .experiment, generatedAt: Dates.iso(now), asOf: Dates.iso(now), filters: window, coverage: coverage, rows: cohorts)
        return result
    }
}
