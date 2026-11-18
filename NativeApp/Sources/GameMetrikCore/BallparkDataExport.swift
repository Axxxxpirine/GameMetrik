import Foundation

public extension DataExport {
    mutating func addBallpark(
        overview: BallparkReport<BallparkOverviewRow>? = nil,
        questions: BallparkReport<BallparkQuestionRow>? = nil,
        series: BallparkReport<BallparkSeriesRow>? = nil,
        habits: BallparkReport<BallparkHabitRow>? = nil,
        quality: BallparkReport<BallparkQualityRow>? = nil
    ) {
        let reports: [(BallparkReportKind, String, BallparkCoverage, Int)] = [
            overview.map { (.overview, $0.generatedAt, $0.coverage, $0.discardedRows) },
            questions.map { (.questions, $0.generatedAt, $0.coverage, $0.discardedRows) },
            series.map { (.series, $0.generatedAt, $0.coverage, $0.discardedRows) },
            habits.map { (.habits, $0.generatedAt, $0.coverage, $0.discardedRows) },
            quality.map { (.quality, $0.generatedAt, $0.coverage, $0.discardedRows) }
        ].compactMap { $0 }

        if let report = overview {
            add("ballpark_apercu", "Ballpark · activité quotidienne", [
                "day", "opened_accounts", "played_accounts", "completed_accounts", "sessions_observed",
                "first_activities_observed", "participations_assigned", "participations_started",
                "participations_completed", "participations_expired_incomplete", "participations_open_incomplete"
            ], report.rows.map { row in [
                .text(row.day), .integer(row.openedAccounts), .integer(row.playedAccounts), .integer(row.completedAccounts),
                .integer(row.sessionsObserved), .integer(row.firstActivitiesObserved), .integer(row.participationsAssigned),
                .integer(row.participationsStarted), .integer(row.participationsCompleted),
                .integer(row.participationsExpiredIncomplete), .integer(row.participationsOpenIncomplete)
            ] }, generatedAt: report.generatedAt, timezone: report.timezone)
        }

        if let report = questions {
            let ratios: [(String, KeyPath<BallparkQuestionRow, BallparkRatio>)] = [
                ("factor_le_1_5", \.factorLe15), ("factor_le_2", \.factorLe2), ("factor_le_5", \.factorLe5),
                ("factor_le_10", \.factorLe10), ("exact", \.exact), ("under", \.under), ("over", \.over),
                ("calculator_opened", \.calculatorOpened), ("calculator_result_used", \.calculatorResultUsed),
                ("explanation_opened", \.explanationOpened), ("source_opened", \.sourceOpened)
            ]
            let ratioColumns = ratios.flatMap { ["\($0.0)_numerator", "\($0.0)_denominator", "\($0.0)_ratio"] }
            add("ballpark_questions", "Ballpark · questions", [
                "question_id", "revision", "locale", "metadata_fingerprint", "prompt", "unit", "reference",
                "theme", "subject", "dimension", "editorial_difficulty", "seen_participations", "answers", "players",
                "complete_time_sample", "sample_status", "factor_q25", "factor_median", "factor_q75", "factor_reason",
                "log_error_q25", "log_error_median", "log_error_q75", "factor_bin_1_to_1_5", "factor_bin_over_1_5_to_2",
                "factor_bin_over_2_to_5", "factor_bin_over_5_to_10", "factor_bin_over_10", "active_time_median_ms",
                "active_time_p75_ms", "active_time_p90_ms", "interruptions", "resumes"
            ] + ratioColumns, report.rows.map { row in
                var values: [ExportValue] = [
                    .text(row.questionID), .integer(row.revision), .text(row.locale.rawValue), .text(row.metadataFingerprint),
                    .text(row.prompt), .text(row.unit), .text(row.reference), .text(row.theme), .text(row.subject),
                    .text(row.dimension), .text(row.editorialDifficulty), .integer(row.seenParticipations), .integer(row.answers),
                    .integer(row.players), .integer(row.completeTimeSample), .text(row.sampleStatus.rawValue),
                    .number(row.factorQ25), .number(row.factorMedian), .number(row.factorQ75), .text(row.factorReason?.rawValue),
                    .number(row.logErrorQ25), .number(row.logErrorMedian), .number(row.logErrorQ75),
                    .number(row.factorBins.oneTo15.map(Double.init)), .number(row.factorBins.over15To2.map(Double.init)),
                    .number(row.factorBins.over2To5.map(Double.init)), .number(row.factorBins.over5To10.map(Double.init)),
                    .number(row.factorBins.over10.map(Double.init)), .number(row.activeTimeMedianMs), .number(row.activeTimeP75Ms),
                    .number(row.activeTimeP90Ms), .integer(row.interruptions), .integer(row.resumes)
                ]
                for (_, path) in ratios {
                    let ratio = row[keyPath: path]
                    values += [.integer(ratio.numerator), .integer(ratio.denominator), .number(ratio.value)]
                }
                return values
            }, generatedAt: report.generatedAt, timezone: report.timezone)
        }

        if let report = series {
            add("ballpark_series", "Ballpark · séries", [
                "game_day", "series_id", "mode", "closes_at", "selector_version", "assigned", "started",
                "at_least_one_answer", "exactly_one_answer", "exactly_two_answers", "exactly_three_answers", "resumed",
                "open_incomplete", "expired_incomplete", "completed", "cancelled",
                "completion_numerator", "completion_denominator", "completion_ratio"
            ], report.rows.map { row in [
                .text(row.gameDay), .text(row.seriesID), .text(row.mode.rawValue), .text(row.closesAt),
                .number(row.selectorVersion.map(Double.init)), .integer(row.assigned), .integer(row.started),
                .integer(row.atLeastOneAnswer), .integer(row.exactlyOneAnswer), .integer(row.exactlyTwoAnswers),
                .integer(row.exactlyThreeAnswers), .integer(row.resumed), .integer(row.statusCounts.openIncomplete),
                .integer(row.statusCounts.expiredIncomplete), .integer(row.statusCounts.completed), .integer(row.statusCounts.cancelled),
                .integer(row.completion.numerator), .integer(row.completion.denominator), .number(row.completion.value)
            ] }, generatedAt: report.generatedAt, timezone: report.timezone)
            add("ballpark_series_questions", "Ballpark · composition des séries", [
                "game_day", "series_id", "position", "question_id", "revision", "metadata_fingerprint",
                "theme", "subject", "dimension", "editorial_difficulty"
            ], report.rows.flatMap { row in row.questions.map { question in [
                .text(row.gameDay), .text(row.seriesID), .integer(question.position), .text(question.questionID),
                .integer(question.revision), .text(question.metadataFingerprint), .text(question.theme), .text(question.subject),
                .text(question.dimension), .text(question.editorialDifficulty)
            ] } }, generatedAt: report.generatedAt, timezone: report.timezone)
        }

        if let report = habits {
            let days = report.rows.compactMap { row -> BallparkHabitDay? in if case .day(let value) = row { value } else { nil } }
            let weeks = report.rows.compactMap { row -> BallparkHabitWeek? in if case .week(let value) = row { value } else { nil } }
            let hours = report.rows.compactMap { row -> BallparkHabitHour? in if case .hour(let value) = row { value } else { nil } }
            add("ballpark_habitudes_jours", "Ballpark · habitudes quotidiennes", [
                "day", "opened_accounts", "answered_accounts", "dau", "wau", "mau", "new_observed_accounts",
                "returning_accounts", "sessions", "completed_series", "daily_participations", "group_participations", "party_participations",
                "retention_j1_numerator", "retention_j1_denominator", "retention_j1_ratio",
                "retention_j7_numerator", "retention_j7_denominator", "retention_j7_ratio",
                "retention_j30_numerator", "retention_j30_denominator", "retention_j30_ratio"
            ], days.map { row in
                [.text(row.day), .integer(row.openedAccounts), .integer(row.answeredAccounts), .integer(row.dau), .integer(row.wau),
                 .integer(row.mau), .integer(row.newObservedAccounts), .integer(row.returningAccounts), .integer(row.sessions),
                 .integer(row.completedSeries), .integer(row.dailyParticipations), .integer(row.groupParticipations), row.partyParticipations.map(ExportValue.integer) ?? .null]
                + [row.retentionJ1, row.retentionJ7, row.retentionJ30].flatMap { [.integer($0.numerator), .integer($0.denominator), .number($0.value)] }
            }, generatedAt: report.generatedAt, timezone: report.timezone)
            add("ballpark_habitudes_semaines", "Ballpark · fréquence hebdomadaire", [
                "week_start", "active_accounts", "played_1_day", "played_2_days", "played_3_days", "played_4_days",
                "played_5_days", "played_6_days", "played_7_days", "series_numerator", "series_denominator", "series_per_active_account"
            ], weeks.map { row in
                [.text(row.weekStart), .integer(row.activeAccounts)] + row.daysPlayedDistribution.map(ExportValue.integer)
                    + [.integer(row.seriesPerActiveAccount.numerator), .integer(row.seriesPerActiveAccount.denominator), .number(row.seriesPerActiveAccount.value)]
            }, generatedAt: report.generatedAt, timezone: report.timezone)
            add("ballpark_habitudes_heures", "Ballpark · heures locales", ["hour", "responses", "sessions"], hours.map {
                [.integer($0.hour), .integer($0.responses), .integer($0.sessions)]
            }, generatedAt: report.generatedAt, timezone: report.timezone)
        }

        if let report = quality {
            add("ballpark_qualite", "Ballpark · qualité technique", [
                "app_version", "build_number", "os_version", "operation", "operations_observed", "successes",
                "controlled_errors", "failure_numerator", "failure_denominator", "failure_ratio", "latency_sample",
                "latency_median_ms", "latency_p95_ms", "known_lost_events", "known_lost_reason", "suspect_timelines",
                "partial_durations", "overlapping_durations"
            ], report.rows.map { row in [
                .text(row.appVersion), .text(row.buildNumber), .text(row.osVersion), .text(row.operation),
                .integer(row.operationsObserved), .integer(row.successes), .integer(row.controlledErrors),
                .integer(row.failure.numerator), .integer(row.failure.denominator), .number(row.failure.value),
                .integer(row.latencySample), .number(row.latencyMedianMs), .number(row.latencyP95Ms),
                .number(row.knownLostEvents.value.map(Double.init)), .text(row.knownLostEvents.reason?.rawValue),
                .integer(row.suspectTimelines), .integer(row.partialDurations), .integer(row.overlappingDurations)
            ] }, generatedAt: report.generatedAt, timezone: report.timezone)
        }

        add("ballpark_couverture", "Ballpark · couverture par rapport", [
            "report", "v2_available_from", "excluded_test_accounts", "participants_eligible", "participants_measured",
            "events_rejected_known", "events_rejected_reason", "events_lost_known", "events_lost_reason",
            "complete_duration_numerator", "complete_duration_denominator", "complete_duration_ratio",
            "v1_events", "v2_events", "observed_through", "warnings", "discarded_rows"
        ], reports.map { kind, _, coverage, discarded in [
            .text(kind.rawValue), .text(coverage.v2AvailableFrom), .integer(coverage.excludedTestAccounts),
            .integer(coverage.participantsEligible), .integer(coverage.participantsMeasured),
            .number(coverage.eventsRejectedKnown.value.map(Double.init)), .text(coverage.eventsRejectedKnown.reason?.rawValue),
            .number(coverage.eventsLostKnown.value.map(Double.init)), .text(coverage.eventsLostKnown.reason?.rawValue),
            .integer(coverage.completeDuration.numerator), .integer(coverage.completeDuration.denominator), .number(coverage.completeDuration.value),
            .integer(coverage.v1Events), .integer(coverage.v2Events), .text(coverage.observedThrough),
            .text(coverage.warnings.map(\.rawValue).joined(separator: " | ")), .integer(discarded)
        ] }, generatedAt: reports.map(\.1).max(), timezone: "Europe/Zurich")

        for (kind, generatedAt, coverage, discarded) in reports {
            let discardedNote = discarded > 0 ? " \(discarded) ligne(s) illisible(s) ou incohérente(s) écartée(s)." : ""
            checks.append(ExportCheck(
                section: "Ballpark · " + kind.rawValue,
                status: coverage.warnings.isEmpty && discarded == 0 ? "loaded" : "partial",
                detail: "Agrégats serveur : \(coverage.participantsMeasured)/\(coverage.participantsEligible) participant(s) mesuré(s).\(discardedNote) Les identités, réponses brutes et saisies ne sont pas exportées.",
                updatedAt: generatedAt
            ))
        }
        notes.append("Ballpark : les jours d’aperçu, habitudes et qualité sont civils ; questions et séries suivent le jour de jeu commençant à 09:00 Europe/Zurich. Les taux conservent numérateur, dénominateur et valeur serveur. Les petits effectifs restent masqués selon le contrat.")
    }
}
