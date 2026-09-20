import XCTest
@testable import TrafficCore

final class RecoveryTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_758_000_000)

    private func series(_ delays: [Int], everyMinutes: Double = 5) -> [RecoveryEstimator.DelayPoint] {
        delays.enumerated().map {
            .init(at: base.addingTimeInterval(Double($0.offset) * everyMinutes * 60), delaySeconds: $0.element)
        }
    }

    func testScheduledEventWins() {
        let endsAt = base.addingTimeInterval(3600)
        let roadworks = TrafficIncident(
            id: "w1", category: .roadworks, description: "Obras",
            startTime: base, endTime: endsAt
        )
        // Aunque la serie tenga tendencia, el dato del proveedor manda.
        let recovery = RecoveryEstimator.estimate(
            incidents: [roadworks],
            incidentSources: ["w1": .tomtom],
            series: series([1800, 1500, 1200, 900]),
            now: base
        )
        guard case .scheduled(let at, let source) = recovery else {
            return XCTFail("esperaba .scheduled, fue \(recovery)")
        }
        XCTAssertEqual(at, endsAt)
        XCTAssertEqual(source, .tomtom)
    }

    func testCongestionEndTimeIsNotTrusted() {
        // La congestión trae endTime a veces, pero no es confiable.
        let jam = TrafficIncident(
            id: "j1", category: .congestion,
            startTime: base, endTime: base.addingTimeInterval(3600)
        )
        let recovery = RecoveryEstimator.estimate(incidents: [jam], series: series([1800, 1200]), now: base)
        guard case .insufficient = recovery else {
            return XCTFail("esperaba .insufficient, fue \(recovery)")
        }
    }

    func testNegativeSlopeWithGoodFitProjectsClearTime() {
        let recovery = RecoveryEstimator.estimate(
            incidents: [], series: series([1800, 1500, 1200, 900, 600]), now: base
        )
        guard case .trending(let clearAt, let rSquared) = recovery else {
            return XCTFail("esperaba .trending, fue \(recovery)")
        }
        XCTAssertGreaterThan(rSquared, 0.99, "la serie es perfectamente lineal")
        // Baja 300s cada 5 min = 60 s/min. Desde 600s restan 10 min.
        let lastSample = base.addingTimeInterval(4 * 5 * 60)
        XCTAssertEqual(clearAt.timeIntervalSince(lastSample), 600, accuracy: 1)
    }

    func testNoisySeriesIsReportedAsUnclear() {
        let recovery = RecoveryEstimator.estimate(
            incidents: [], series: series([1800, 900, 1700, 800, 1750, 850]), now: base
        )
        guard case .unclear(let reason) = recovery else {
            return XCTFail("esperaba .unclear, fue \(recovery)")
        }
        XCTAssertTrue(reason.contains("R²"), "debe decir por qué, no mostrar un guion")
    }

    func testFlatSeriesIsWorseningNotAnEstimate() {
        // Pendiente plana: no mejora, y no se inventa un número.
        let recovery = RecoveryEstimator.estimate(
            incidents: [], series: series([1200, 1200, 1200, 1200]), now: base
        )
        guard case .worsening(let slope) = recovery else {
            return XCTFail("esperaba .worsening, fue \(recovery)")
        }
        XCTAssertEqual(slope, 0, accuracy: 0.001)
    }

    func testRisingSeriesIsWorsening() {
        let recovery = RecoveryEstimator.estimate(
            incidents: [], series: series([600, 900, 1200, 1500]), now: base
        )
        guard case .worsening(let slope) = recovery else {
            return XCTFail("esperaba .worsening, fue \(recovery)")
        }
        XCTAssertEqual(slope, 60, accuracy: 0.1, "sube 300s cada 5 min")
    }

    func testThreeSamplesIsInsufficient() {
        let recovery = RecoveryEstimator.estimate(incidents: [], series: series([1800, 1500, 1200]), now: base)
        guard case .insufficient(let needed) = recovery else {
            return XCTFail("esperaba .insufficient, fue \(recovery)")
        }
        XCTAssertEqual(needed, 1)
    }

    func testEmptySeriesIsInsufficient() {
        let recovery = RecoveryEstimator.estimate(incidents: [], series: [], now: base)
        guard case .insufficient(let needed) = recovery else {
            return XCTFail("esperaba .insufficient, fue \(recovery)")
        }
        XCTAssertEqual(needed, 4)
    }

    func testAllSamplesAtSameInstantIsUnclear() {
        let points = (0..<4).map { _ in RecoveryEstimator.DelayPoint(at: base, delaySeconds: 1200) }
        let recovery = RecoveryEstimator.estimate(incidents: [], series: points, now: base)
        guard case .unclear = recovery else {
            return XCTFail("esperaba .unclear, fue \(recovery)")
        }
    }

    func testPastScheduledEndIsIgnored() {
        // Unas obras que ya terminaron no explican el delay de ahora.
        let stale = TrafficIncident(
            id: "w2", category: .roadworks,
            startTime: base.addingTimeInterval(-7200), endTime: base.addingTimeInterval(-3600)
        )
        let recovery = RecoveryEstimator.estimate(incidents: [stale], series: series([1800, 1500]), now: base)
        guard case .insufficient = recovery else {
            return XCTFail("esperaba .insufficient, fue \(recovery)")
        }
    }
}
