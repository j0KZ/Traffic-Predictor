import XCTest
@testable import TrafficCore

final class EngineTests: XCTestCase {

    func testOneFailureDoesNotLoseTheOthers() async {
        let engine = SamplingEngine(providers: [
            FakeProvider(id: .google, result: .failure(.http(status: 500, body: "boom"))),
            FakeProvider(id: .tomtom, result: .success(makeSample(.tomtom, duration: 8040))),
            FakeProvider(id: .here,   result: .success(makeSample(.here, duration: 8100))),
        ])
        let round = await engine.runOnce(testQuery)

        XCTAssertEqual(round.samples.count, 2)
        XCTAssertEqual(round.failures.count, 1)
        XCTAssertNotNil(round.failures[.google])
        XCTAssertTrue(round.failures[.google]!.contains("500"), "el error exacto, no un resumen")
    }

    func testEveryProviderDownIsAnEmptyRoundNotACrash() async {
        let engine = SamplingEngine(providers: ProviderID.allCases.map {
            FakeProvider(id: $0, result: .failure(.transport("red caída")))
        })
        let round = await engine.runOnce(testQuery)

        XCTAssertTrue(round.samples.isEmpty)
        XCTAssertEqual(round.failures.count, ProviderID.allCases.count)
        XCTAssertEqual(DivergenceAnalyzer.analyze(round.samples).verdict, .insufficient)
    }

    func testProviderTimeoutIsEnforced() async {
        var cadence = SamplingCadence()
        cadence.providerTimeout = 0.2

        let engine = SamplingEngine(providers: [
            FakeProvider(id: .google, result: .success(makeSample(.google, duration: 7900)), delay: 5),
            FakeProvider(id: .tomtom, result: .success(makeSample(.tomtom, duration: 8040))),
        ], cadence: cadence)

        let started = Date()
        let round = await engine.runOnce(testQuery)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 3, "una fuente colgada no puede retrasar la ronda")
        XCTAssertEqual(round.samples.count, 1)
        XCTAssertTrue(round.failures[.google]?.contains("timeout") == true)
    }

    func testIncidentsAreFilteredToTheRoute() async {
        let points = (0...100).map { Coordinate(lat: -32.787 + Double($0) * 0.001, lon: -71.189) }
        let onRoute = TrafficIncident(id: "on", category: .accident, description: "en ruta",
                                      location: Coordinate(lat: -32.7370, lon: -71.1890))
        let offRoute = TrafficIncident(id: "off", category: .accident, description: "Valparaíso",
                                       location: Coordinate(lat: -33.0472, lon: -71.6127))

        let engine = SamplingEngine(providers: [
            FakeProvider(id: .tomtom, result: .success(makeSample(
                .tomtom, duration: 8040,
                polyline: Polyline.encode(points),
                incidents: [onRoute, offRoute]
            )))
        ])
        let round = await engine.runOnce(testQuery)
        XCTAssertEqual(round.samples[.tomtom]?.incidents.map(\.id), ["on"])
    }

    func testRateLimitedProviderIsSkippedNextRound() async {
        let engine = SamplingEngine(providers: [
            FakeProvider(id: .google, result: .failure(.rateLimited(retryAfter: 60))),
            FakeProvider(id: .tomtom, result: .success(makeSample(.tomtom, duration: 8040))),
        ])

        let first = await engine.runOnce(testQuery)
        XCTAssertTrue(first.failures[.google]!.contains("rate limited"))

        let second = await engine.runOnce(testQuery)
        XCTAssertTrue(second.failures[.google]!.contains("backoff"), "no se reintenta de inmediato")
        XCTAssertNotNil(second.samples[.tomtom], "las otras fuentes siguen normales")
    }

    func testAuthErrorDoesNotTriggerBackoff() async {
        // Un 401 no se arregla esperando: reintentar no cuesta nada útil, pero
        // saltarse rondas sí esconde el problema.
        let engine = SamplingEngine(providers: [
            FakeProvider(id: .google, result: .failure(.http(status: 401, body: "bad key")))
        ])
        _ = await engine.runOnce(testQuery)
        let second = await engine.runOnce(testQuery)
        XCTAssertFalse(second.failures[.google]!.contains("backoff"))
    }
}

final class CadenceTests: XCTestCase {
    private func round(_ durations: [ProviderID: Int]) -> SampleRound {
        SampleRound(
            capturedAt: .now,
            samples: durations.mapValues { makeSample(.google, duration: $0) },
            failures: [:]
        )
    }

    func testFirstRoundUsesActiveInterval() async {
        let engine = SamplingEngine(providers: [])
        let interval = await engine.nextInterval(after: round([.google: 8000]))
        XCTAssertEqual(interval, 120, "sin referencia, muestrea rápido para formar serie")
    }

    func testBigJumpAccelerates() async {
        let engine = SamplingEngine(providers: [])
        _ = await engine.nextInterval(after: round([.google: 8000]))
        let interval = await engine.nextInterval(after: round([.google: 8400]))
        XCTAssertEqual(interval, 120, "salto de 400s supera el umbral de 180s")
    }

    func testSmallDriftStaysStable() async {
        let engine = SamplingEngine(providers: [])
        _ = await engine.nextInterval(after: round([.google: 8000]))
        let interval = await engine.nextInterval(after: round([.google: 8060]))
        XCTAssertEqual(interval, 300, "deriva de 1 min no justifica acelerar")
    }

    func testEmptyRoundDoesNotAccelerate() async {
        // No aceleres contra una API caída.
        let engine = SamplingEngine(providers: [])
        _ = await engine.nextInterval(after: round([.google: 8000]))
        let interval = await engine.nextInterval(
            after: SampleRound(capturedAt: .now, samples: [:], failures: [.google: "caído"])
        )
        XCTAssertEqual(interval, 300)
    }

    func testAdaptiveOffAlwaysUsesStable() async {
        var cadence = SamplingCadence()
        cadence.adaptive = false
        let engine = SamplingEngine(providers: [], cadence: cadence)

        let first = await engine.nextInterval(after: round([.google: 8000]))
        let second = await engine.nextInterval(after: round([.google: 9000]))
        XCTAssertEqual(first, 300)
        XCTAssertEqual(second, 300)
    }
}
