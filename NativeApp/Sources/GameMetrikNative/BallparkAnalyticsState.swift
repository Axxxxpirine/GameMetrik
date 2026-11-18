import Foundation
import GameMetrikCore

struct BallparkAnalyticsData: Sendable {
    var overview: BallparkReport<BallparkOverviewRow>?
    var questions: BallparkReport<BallparkQuestionRow>?
    var series: BallparkReport<BallparkSeriesRow>?
    var habits: BallparkReport<BallparkHabitRow>?
    var quality: BallparkReport<BallparkQualityRow>?
    var errors: [BallparkReportKind: String] = [:]

    init() {}

    init(bundle: BallparkReportBundle) {
        overview = bundle.overview
        questions = bundle.questions
        series = bundle.series
        habits = bundle.habits
        quality = bundle.quality
    }

    var loadedKinds: [BallparkReportKind] {
        BallparkReportKind.allCases.filter { report(for: $0) != nil }
    }

    var isEmpty: Bool { loadedKinds.isEmpty }

    var latestGeneration: Date? {
        [overview?.generatedAt, questions?.generatedAt, series?.generatedAt, habits?.generatedAt, quality?.generatedAt]
            .compactMap { $0.flatMap(Dates.parse) }
            .max()
    }

    func report(for kind: BallparkReportKind) -> Any? {
        switch kind {
        case .overview: overview
        case .questions: questions
        case .series: series
        case .habits: habits
        case .quality: quality
        }
    }
}

extension BallparkReportKind {
    var frenchTitle: String {
        switch self {
        case .overview: "Aperçu"
        case .questions: "Questions"
        case .series: "Séries"
        case .habits: "Habitudes"
        case .quality: "Qualité"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "chart.xyaxis.line"
        case .questions: "questionmark.bubble"
        case .series: "rectangle.stack"
        case .habits: "calendar"
        case .quality: "waveform.path.ecg"
        }
    }
}
