import Foundation
import Testing
@testable import GameMetrikCore

struct ChartCalendarTests {
    @Test func arrowsContinueFromTheInspectorDayOrHoveredMarker() {
        #expect(ChartInspection.movedIndex(hovered: nil, highlighted: 29, offset: -1, count: 30) == 28)
        #expect(ChartInspection.movedIndex(hovered: nil, highlighted: 29, offset: 1, count: 30) == 29)
        #expect(ChartInspection.movedIndex(hovered: 12, highlighted: 29, offset: -1, count: 30) == 11)
        #expect(ChartInspection.movedIndex(hovered: nil, highlighted: 0, offset: -1, count: 30) == 0)
        #expect(ChartInspection.movedIndex(hovered: nil, offset: 1, count: 30) == 0)
        #expect(ChartInspection.movedIndex(hovered: nil, offset: -1, count: 30) == 0)
        #expect(ChartInspection.movedIndex(hovered: nil, highlighted: 0, offset: 1, count: 0) == nil)
    }

    @Test func calendarTicksStayApartWhenObservationsCluster() {
        #expect(ChartInspection.axisPositions([0, 1, 10, 11, 28]) == [0, 7, 14, 21, 28])
        #expect(ChartInspection.axisPositions([0, 1]) == [0, 1])
        #expect(ChartInspection.axisPositions([0]) == [0])
        #expect(ChartInspection.axisPositions([]).isEmpty)
        #expect(ChartInspection.axisPositions([.nan]).isEmpty)
        #expect(ChartInspection.axisPositions([0, 28], limit: 3) == [0, 14, 28])
    }

    @Test func inactiveDaysKeepTheirCalendarDistanceAcrossDST() {
        #expect(ChartInspection.dayPositions(["2026-09-01", "2026-09-02", "2026-09-07"]) == [0, 1, 6])
        #expect(ChartInspection.dayPositions(["2026-03-28", "2026-03-29", "2026-03-30"]) == [0, 1, 2])
        #expect(ChartInspection.dayPositions(["2026-10-24", "2026-10-25", "2026-10-26"]) == [0, 1, 2])
        #expect(ChartInspection.dayPositions([]).isEmpty)
        #expect(ChartInspection.dayPositions(["invalid"]).isEmpty)
    }

    @Test func chartInspectionUsesDateDistanceRatherThanArrayIndex() {
        let positions = ChartInspection.dayPositions(["2026-09-01", "2026-09-02", "2026-09-07"])
        #expect(ChartInspection.nearestIndex(value: 2.9, positions: positions) == 1)
        #expect(ChartInspection.nearestIndex(value: 4.1, positions: positions) == 2)
        #expect(ChartInspection.nearestIndex(value: -10, positions: positions) == 0)
        #expect(ChartInspection.nearestIndex(value: 100, positions: positions) == 2)
        #expect(ChartInspection.nearestIndex(value: nil, positions: positions) == nil)
        #expect(ChartInspection.nearestIndex(value: .nan, positions: positions) == nil)
        #expect(ChartInspection.nearestIndex(value: 3, positions: []) == nil)
        #expect(ChartInspection.nearestIndex(value: 3, positions: [.nan, 4]) == 1)
    }

    @Test func missingReportsBreakTheCurveButKnownZerosRemain() {
        #expect(ChartInspection.segments(positions: [0, 1, 2, 3, 6, 7], values: [10, nil, 0, 8, 9, 10]) == [0, 1, 1, 1, 2, 2])
        #expect(ChartInspection.segments(positions: [], values: []).isEmpty)
    }

    @Test func dayInspectorTracksDatesWhileReportsChangeAndClearsWhenUnavailable() {
        var points = Demo.dashboard(range: .week, gameID: nil, now: Dates.parse("2026-09-07T12:00:00Z")!).trend
        var selection = DashboardDaySelection()
        #expect(selection.point(in: points) == nil)
        selection.select("2026-09-03", in: points)
        #expect(selection.point(in: points)?.date == "2026-09-03")
        selection.move(1, in: points)
        #expect(selection.date == "2026-09-04")
        points.removeFirst()
        points[2].newPlayers = 42
        selection.reconcile(with: points)
        #expect(selection.point(in: points)?.newPlayers == 42)
        selection.move(99, in: points)
        #expect(selection.date == points.last?.date)
        selection.move(-99, in: points)
        #expect(selection.date == points.first?.date)
        selection.reconcile(with: [])
        #expect(selection.date == nil)
        selection.select("not-a-report", in: points)
        #expect(selection.date == nil)
        selection.select(points.last?.date, in: points)
        selection.select(nil, in: points)
        #expect(selection.date == nil)
    }
}
