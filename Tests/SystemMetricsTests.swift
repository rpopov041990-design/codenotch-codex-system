import XCTest
@testable import Codenotch

final class SystemMetricsTests: XCTestCase {
    func testRatiosAreBoundedAndMissingIsNotZero() {
        XCTAssertNil(SystemMetric.ratio(used: 1, total: 0))
        XCTAssertNil(SystemMetric.ratio(used: .nan, total: 1))
        XCTAssertEqual(SystemMetric.ratio(used: 25, total: 100), 0.25)
        XCTAssertEqual(SystemMetric.ratio(used: 101, total: 100), 1)
        XCTAssertEqual(SystemMetric.ratio(used: -1, total: 100), 0)
    }

    func testLocalReadingsAndThermalIsNotDegrees() {
        let readings = SystemMetricsSampler().sample()
        XCTAssertEqual(Array(readings.prefix(4)).map(\.id), ["system.ram", "system.cpu", "system.disk", "system.thermal"])
        XCTAssertNil(readings[1].fraction, "CPU needs two measurements")
        XCTAssertNil(readings[3].fraction, "Thermal state is not a percentage")
        XCTAssertFalse(readings[3].value.contains("°"))
        for value in readings.compactMap(\.fraction) {
            XCTAssertTrue((0...1).contains(value))
        }
        XCTAssertNotNil(readings[0].fraction)
        XCTAssertNotNil(readings[2].fraction)
    }

    @MainActor
    func testMetricsStayViewLocalAndPrecedeCodex() {
        let model = NotchViewModel()
        let codex = ProviderSnapshot(id: "codex", displayName: "Codex", glyph: .openai,
                                     fidelity: .official, status: .ok, windows: [])
        model.updateSnapshots([codex])
        XCTAssertEqual(model.snapshots.map(\.id), ["codex"])
        model.startSystemMetrics()
        XCTAssertEqual(model.snapshots, [codex], "System cells must never become provider readings")
        XCTAssertEqual(model.displaySnapshots.last?.id, "codex")
        XCTAssertEqual(model.snapshots.last?.id, "codex")
        model.updateSnapshots([codex])
        XCTAssertEqual(Set(model.snapshots.map(\.id)).count, model.snapshots.count)
        XCTAssertEqual(model.snapshots.filter { $0.id == "codex" }.count, 1)
        XCTAssertTrue((4...5).contains(model.systemMetrics.count))
    }

    func testBatteryChargeAndUnavailableHealth() {
        let battery = BatteryReading(fraction: 0.72, charging: true, pluggedIn: true,
                                     health: "Нормальное", cycles: 120, maximumCapacity: 94)
        XCTAssertEqual(battery.metric.value, "72%")
        XCTAssertTrue(battery.metric.symbol.contains("bolt"))
        XCTAssertTrue(battery.metric.detail.contains("94%"))
        XCTAssertTrue(battery.metric.detail.contains("120"))
        let missing = BatteryReading(fraction: nil, charging: false, pluggedIn: true,
                                     health: "Нет данных", cycles: nil, maximumCapacity: nil)
        XCTAssertEqual(missing.metric.value, "—")
        XCTAssertTrue(missing.metric.detail.contains("не заряжается"))
        XCTAssertFalse(missing.metric.detail.contains("0%"))
    }

    @MainActor
    func testSystemClickDoesNotRefreshAccount() async {
        let model = NotchViewModel()
        model.startSystemMetrics()
        var contactedProvider = false
        await model.refresh(model.systemMetrics[0].snapshot) { _ in contactedProvider = true }
        XCTAssertFalse(contactedProvider)
    }
}
