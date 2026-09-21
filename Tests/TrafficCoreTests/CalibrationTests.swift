import XCTest
@testable import TrafficCore

final class CalibrationTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_758_000_000)

    private func sample(_ p: ProviderID, _ d: Int, at minutes: Double) -> ETASample {
        ETASample(provider: p, capturedAt: base.addingTimeInterval(minutes * 60),
                  durationSeconds: d, distanceMeters: 162_000)
    }

    private func waze(_ d: Int, at minutes: Double) -> ReferenceReading {
        ReferenceReading(routeID: "r5n", source: "waze",
                         capturedAt: base.addingTimeInterval(minutes * 60), durationSeconds: d)
    }

    func testRealNightReadingShowsTomTomOptimisticAgainstWaze() throws {
        // Lectura real del 2026-09-21 00:24: Waze 2h07, TomTom 1h51.
        let biases = Calibrator.bias(
            samples: [sample(.tomtom, 6658, at: 0)],
            references: [waze(7620, at: 0.5)]
        )
        let tomtom = try XCTUnwrap(biases.first { $0.provider == .tomtom })
        XCTAssertEqual(tomtom.ratio, 6658.0 / 7620.0, accuracy: 0.0001)
        XCTAssertEqual(tomtom.offsetSeconds, -962)
        XCTAssertLessThan(tomtom.ratio, 1, "ratio < 1: la fuente es optimista")
    }

    func testOnePairIsReportedButNeverUsedAsCorrection() throws {
        let biases = Calibrator.bias(samples: [sample(.tomtom, 6658, at: 0)], references: [waze(7620, at: 0)])
        let tomtom = try XCTUnwrap(biases.first)
        XCTAssertFalse(tomtom.isUsableForCorrection)
        XCTAssertNil(tomtom.corrected(7000), "una corrección con un par es ruido con decimales")
        XCTAssertNil(tomtom.trendCorrelation, "con un par no hay curva")
    }

    func testEnoughPairsProduceACorrection() throws {
        let samples = (0..<8).map { sample(.tomtom, 9000, at: Double($0) * 5) }
        let refs = (0..<8).map { waze(10_000, at: Double($0) * 5 + 1) }
        let tomtom = try XCTUnwrap(Calibrator.bias(samples: samples, references: refs).first)

        XCTAssertTrue(tomtom.isUsableForCorrection)
        XCTAssertEqual(tomtom.corrected(9000), 10_000)
    }

    func testReadingsTooFarApartAreNotPaired() {
        // 10 minutos de diferencia: el tráfico ya es otro.
        let biases = Calibrator.bias(samples: [sample(.tomtom, 6658, at: 0)], references: [waze(7620, at: 10)])
        XCTAssertTrue(biases.isEmpty)
    }

    func testEachReferencePairsWithTheClosestSample() throws {
        let samples = [sample(.tomtom, 7000, at: 0), sample(.tomtom, 8000, at: 4)]
        let tomtom = try XCTUnwrap(Calibrator.bias(samples: samples, references: [waze(8500, at: 3.5)]).first)
        XCTAssertEqual(tomtom.pairs.first?.sample, 8000)
    }

    func testTrendCorrelationDetectsASourceThatFollowsTheCurve() throws {
        // TomTom sigue la curva de Waze con un offset: correlación ~1.
        let wazeCurve = [7600, 8200, 9100, 9800, 9300, 8400]
        let samples = wazeCurve.enumerated().map { sample(.tomtom, $0.element - 900, at: Double($0.offset) * 5) }
        let refs = wazeCurve.enumerated().map { waze($0.element, at: Double($0.offset) * 5) }
        let tomtom = try XCTUnwrap(Calibrator.bias(samples: samples, references: refs).first)
        XCTAssertEqual(tomtom.trendCorrelation ?? 0, 1, accuracy: 0.001)
    }

    func testFlatSourceHasNoCorrelationNotAZero() throws {
        // Mapbox sin cobertura devuelve siempre lo mismo: no sigue ni deja de
        // seguir la curva, simplemente no la ve.
        let refs = [7600, 8200, 9100, 9800].enumerated().map { waze($0.element, at: Double($0.offset) * 5) }
        let samples = (0..<4).map { sample(.mapbox, 7000, at: Double($0) * 5) }
        let mapbox = try XCTUnwrap(Calibrator.bias(samples: samples, references: refs).first)
        XCTAssertNil(mapbox.trendCorrelation)
    }

    func testReferenceRoundTripThroughStore() async throws {
        let store = try SampleStore.inMemory()
        let reading = waze(7620, at: 0)
        try await store.persist(reading)
        let loaded = try await store.references(routeID: "r5n", from: base.addingTimeInterval(-60), to: base.addingTimeInterval(60))
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].durationSeconds, 7620)
        XCTAssertEqual(loaded[0].source, "waze")
    }
}
