import Foundation

/// Complete, explicitly synthetic Ballpark dataset for the local demonstration workspace.
public struct BallparkReportBundle: Codable, Sendable {
    public var overview: BallparkReport<BallparkOverviewRow>
    public var questions: BallparkReport<BallparkQuestionRow>
    public var series: BallparkReport<BallparkSeriesRow>
    public var habits: BallparkReport<BallparkHabitRow>
    public var quality: BallparkReport<BallparkQualityRow>

    public init(
        overview: BallparkReport<BallparkOverviewRow>, questions: BallparkReport<BallparkQuestionRow>,
        series: BallparkReport<BallparkSeriesRow>, habits: BallparkReport<BallparkHabitRow>,
        quality: BallparkReport<BallparkQualityRow>
    ) {
        self.overview = overview
        self.questions = questions
        self.series = series
        self.habits = habits
        self.quality = quality
    }
}

public enum BallparkDemo {
    /// Fictitious values only. They are never used as a fallback for a failed live request.
    public static let bundle: BallparkReportBundle = {
        let filters = BallparkReportFilters(fromDay: "2026-09-14", toDayExclusive: "2026-09-21")
        let coverage = BallparkCoverage(
            v2AvailableFrom: "2026-08-01T00:00:00Z", excludedTestAccounts: 2,
            participantsEligible: 38, participantsMeasured: 34,
            eventsRejectedKnown: .init(value: 1, reason: nil),
            eventsLostKnown: .init(value: nil, reason: .notInstrumented),
            completeDuration: .init(numerator: 94, denominator: 108, value: 0.8704, reason: nil),
            v1Events: 14, v2Events: 486, observedThrough: "2026-09-20T21:00:00Z",
            warnings: [.optionalCollectionBias, .v1PartialCoverage]
        )
        let generated = "2026-09-21T08:00:00Z"
        let asOf = "2026-09-21T07:59:30Z"
        func ratio(_ numerator: Int, _ denominator: Int, _ value: Double) -> BallparkRatio {
            .init(numerator: numerator, denominator: denominator, value: value, reason: nil)
        }
        func report<Row: Codable & Sendable>(
            _ kind: BallparkReportKind, _ rows: [Row]
        ) -> BallparkReport<Row> {
            BallparkReport(
                contractVersion: 1, report: kind, generatedAt: generated, asOf: asOf,
                timezone: "Europe/Zurich", dayBasis: kind.dayBasis, filters: filters,
                coverage: coverage, rows: rows, pageCount: 1
            )
        }

        let overview = report(.overview, [
            BallparkOverviewRow(day: "2026-09-14", openedAccounts: 18, playedAccounts: 15,
                completedAccounts: 11, sessionsObserved: 21, firstActivitiesObserved: 3,
                participationsAssigned: 24, participationsStarted: 19, participationsCompleted: 14,
                participationsExpiredIncomplete: 2, participationsOpenIncomplete: 3),
            BallparkOverviewRow(day: "2026-09-15", openedAccounts: 21, playedAccounts: 18,
                completedAccounts: 13, sessionsObserved: 25, firstActivitiesObserved: 2,
                participationsAssigned: 27, participationsStarted: 22, participationsCompleted: 16,
                participationsExpiredIncomplete: 3, participationsOpenIncomplete: 3),
            BallparkOverviewRow(day: "2026-09-16", openedAccounts: 20, playedAccounts: 17,
                completedAccounts: 12, sessionsObserved: 24, firstActivitiesObserved: 4,
                participationsAssigned: 26, participationsStarted: 21, participationsCompleted: 15,
                participationsExpiredIncomplete: 2, participationsOpenIncomplete: 4),
            BallparkOverviewRow(day: "2026-09-17", openedAccounts: 25, playedAccounts: 22,
                completedAccounts: 17, sessionsObserved: 31, firstActivitiesObserved: 3,
                participationsAssigned: 34, participationsStarted: 28, participationsCompleted: 21,
                participationsExpiredIncomplete: 3, participationsOpenIncomplete: 4),
            BallparkOverviewRow(day: "2026-09-18", openedAccounts: 23, playedAccounts: 20,
                completedAccounts: 15, sessionsObserved: 28, firstActivitiesObserved: 2,
                participationsAssigned: 31, participationsStarted: 25, participationsCompleted: 18,
                participationsExpiredIncomplete: 3, participationsOpenIncomplete: 4),
            BallparkOverviewRow(day: "2026-09-19", openedAccounts: 24, playedAccounts: 21,
                completedAccounts: 16, sessionsObserved: 29, firstActivitiesObserved: 5,
                participationsAssigned: 33, participationsStarted: 27, participationsCompleted: 20,
                participationsExpiredIncomplete: 4, participationsOpenIncomplete: 3),
            BallparkOverviewRow(day: "2026-09-20", openedAccounts: 28, playedAccounts: 25,
                completedAccounts: 19, sessionsObserved: 36, firstActivitiesObserved: 4,
                participationsAssigned: 41, participationsStarted: 34, participationsCompleted: 24,
                participationsExpiredIncomplete: 3, participationsOpenIncomplete: 7)
        ])
        let questions = report(.questions, [
            BallparkQuestionRow(
                questionID: "demo-earth", revision: 2, locale: .fr,
                metadataFingerprint: "demo-metadata-earth-v2", prompt: "Combien pèse la Terre ?",
                unit: "kg", reference: "5972000000000000000000000", theme: "Sciences",
                subject: "Astronomie", dimension: "Masse", editorialDifficulty: "Intermédiaire",
                seenParticipations: 31, answers: 29, players: 26, completeTimeSample: 23,
                sampleStatus: .limitedSample, factorQ25: 1.5, factorMedian: 2.2, factorQ75: 4.8,
                factorReason: nil, logErrorQ25: -0.31, logErrorMedian: 0.18, logErrorQ75: 0.92,
                factorLe15: ratio(7, 26, 0.2692), factorLe2: ratio(12, 26, 0.4615),
                factorLe5: ratio(20, 26, 0.7692), factorLe10: ratio(23, 26, 0.8846),
                exact: ratio(2, 26, 0.0769), under: ratio(12, 26, 0.4615),
                over: ratio(12, 26, 0.4615),
                factorBins: .init(oneTo15: 7, over15To2: 5, over2To5: 8, over5To10: 3, over10: 3),
                activeTimeMedianMs: 28_400, activeTimeP75Ms: 41_200, activeTimeP90Ms: 58_900,
                calculatorOpened: ratio(9, 24, 0.375), calculatorResultUsed: ratio(6, 24, 0.25),
                explanationOpened: ratio(18, 25, 0.72), sourceOpened: ratio(8, 25, 0.32),
                interruptions: 4, resumes: 3
            ),
            BallparkQuestionRow(
                questionID: "demo-alps", revision: 1, locale: .fr,
                metadataFingerprint: "demo-metadata-alps-v1", prompt: "Quelle est la hauteur du Cervin ?",
                unit: "m", reference: "4478", theme: "Géographie", subject: "Alpes",
                dimension: "Longueur", editorialDifficulty: "Accessible", seenParticipations: 4,
                answers: 4, players: 4, completeTimeSample: 3, sampleStatus: .insufficientSample,
                factorQ25: nil, factorMedian: nil, factorQ75: nil, factorReason: .insufficientSample,
                logErrorQ25: nil, logErrorMedian: nil, logErrorQ75: nil,
                factorLe15: .init(numerator: 3, denominator: 4, value: nil, reason: .insufficientSample),
                factorLe2: .init(numerator: 4, denominator: 4, value: nil, reason: .insufficientSample),
                factorLe5: .init(numerator: 4, denominator: 4, value: nil, reason: .insufficientSample),
                factorLe10: .init(numerator: 4, denominator: 4, value: nil, reason: .insufficientSample),
                exact: .init(numerator: 1, denominator: 4, value: nil, reason: .insufficientSample),
                under: .init(numerator: 2, denominator: 4, value: nil, reason: .insufficientSample),
                over: .init(numerator: 1, denominator: 4, value: nil, reason: .insufficientSample),
                factorBins: .init(oneTo15: nil, over15To2: nil, over2To5: nil, over5To10: nil, over10: nil),
                activeTimeMedianMs: nil, activeTimeP75Ms: nil, activeTimeP90Ms: nil,
                calculatorOpened: ratio(0, 4, 0), calculatorResultUsed: ratio(0, 4, 0),
                explanationOpened: ratio(3, 4, 0.75), sourceOpened: ratio(1, 4, 0.25),
                interruptions: 0, resumes: 0
            )
        ])
        let series = report(.series, [
            BallparkSeriesRow(
                gameDay: "2026-09-20", seriesID: "demo-series-opaque-01", mode: .daily,
                closesAt: "2026-09-21T09:00:00+02:00", selectorVersion: 2,
                questions: [
                    .init(position: 1, questionID: "demo-alps", revision: 1, metadataFingerprint: "demo-metadata-alps-v1", theme: "Géographie", subject: "Alpes", dimension: "Longueur", editorialDifficulty: "Accessible"),
                    .init(position: 2, questionID: "demo-earth", revision: 2, metadataFingerprint: "demo-metadata-earth-v2", theme: "Sciences", subject: "Astronomie", dimension: "Masse", editorialDifficulty: "Intermédiaire"),
                    .init(position: 3, questionID: "demo-ocean", revision: 1, metadataFingerprint: "demo-metadata-ocean-v1", theme: "Nature", subject: "Océans", dimension: "Volume", editorialDifficulty: "Difficile")
                ], assigned: 38, started: 31, atLeastOneAnswer: 29, exactlyOneAnswer: 3,
                exactlyTwoAnswers: 4, exactlyThreeAnswers: 22, resumed: 5,
                statusCounts: .init(openIncomplete: 2, expiredIncomplete: 3, completed: 22, cancelled: 4),
                completion: ratio(22, 31, 0.7097)
            )
        ])
        let habitDays = [
            ("2026-09-14", 18, 15, 15, 21, 32, 3, 12, 21, 14, 11, 3, 0.50, 0.33),
            ("2026-09-15", 21, 18, 18, 24, 33, 2, 16, 25, 16, 13, 3, 0.58, 0.38),
            ("2026-09-16", 20, 17, 17, 26, 34, 4, 13, 24, 15, 12, 3, 0.60, 0.42),
            ("2026-09-17", 25, 22, 22, 30, 36, 3, 19, 31, 21, 17, 4, 0.625, 0.50),
            ("2026-09-18", 23, 20, 20, 31, 37, 2, 18, 28, 18, 15, 3, 0.64, 0.50),
            ("2026-09-19", 24, 21, 21, 32, 37, 5, 16, 29, 20, 16, 4, 0.65, 0.53),
            ("2026-09-20", 28, 25, 25, 34, 38, 4, 21, 36, 24, 19, 5, 0.6667, 0.5556)
        ].map { day, opened, answered, dau, wau, mau, fresh, returning, sessions, completed, daily, group, j1, j7 in
            BallparkHabitDay(
                day: day, openedAccounts: opened, answeredAccounts: answered,
                dau: dau, wau: wau, mau: mau, newObservedAccounts: fresh, returningAccounts: returning,
                sessions: sessions, completedSeries: completed, dailyParticipations: daily, groupParticipations: group,
                retentionJ1: ratio(Int((j1 * 12).rounded()), 12, j1),
                retentionJ7: ratio(Int((j7 * 9).rounded()), 9, j7),
                retentionJ30: .init(numerator: 0, denominator: 3, value: nil, reason: .insufficientSample)
            )
        }
        let habitWeek = BallparkHabitWeek(
            weekStart: "2026-09-14", activeAccounts: 34,
            daysPlayedDistribution: [8, 7, 6, 5, 4, 2, 2],
            seriesPerActiveAccount: ratio(71, 34, 2.0882)
        )
        let habitHours = [(8, 7, 4), (12, 15, 8), (18, 28, 13), (20, 41, 18), (22, 19, 10)]
            .map { BallparkHabitHour(hour: $0.0, responses: $0.1, sessions: $0.2) }
        let habitRows: [BallparkHabitRow] = habitDays.map(BallparkHabitRow.day)
            + [.week(habitWeek)] + habitHours.map(BallparkHabitRow.hour)
        let habits = report(.habits, habitRows)
        let quality = report(.quality, [
            BallparkQualityRow(appVersion: "0.1.1", buildNumber: "18", osVersion: "iOS 26.0",
                operation: "submit_answer", operationsObserved: 116, successes: 112,
                controlledErrors: 4, failure: ratio(4, 116, 0.0345), latencySample: 108,
                latencyMedianMs: 184, latencyP95Ms: 612,
                knownLostEvents: .init(value: nil, reason: .notInstrumented), suspectTimelines: 2,
                partialDurations: 7, overlappingDurations: 1)
        ])
        return BallparkReportBundle(
            overview: overview, questions: questions, series: series, habits: habits, quality: quality
        )
    }()
}
