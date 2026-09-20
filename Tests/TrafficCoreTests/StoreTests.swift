import XCTest
@testable import TrafficCore

final class StoreTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_758_000_000)

    private func makeRound(at date: Date, durations: [ProviderID: Int], failures: [ProviderID: String] = [:]) -> SampleRound {
        var samples: [ProviderID: ETASample] = [:]
        for (provider, duration) in durations {
            samples[provider] = ETASample(
                provider: provider, capturedAt: date,
                durationSeconds: duration, freeFlowSeconds: 6300,
                distanceMeters: 179_104, polyline: "_p~iF~ps|U",
                incidents: [
                    TrafficIncident(
                        id: "inc-\(provider.rawValue)", category: .roadworks,
                        description: "Obras", location: Coordinate(lat: -32.787, lon: -71.189),
                        startTime: date, endTime: date.addingTimeInterval(3600),
                        delaySeconds: 600, severity: 2, routeRatio: 0.4
                    )
                ]
            )
        }
        return SampleRound(capturedAt: date, samples: samples, failures: failures)
    }

    func testRoundTrip() async throws {
        let store = try SampleStore.inMemory()
        try await store.persist(makeRound(at: base, durations: [.google: 7920, .tomtom: 8040]), routeID: "r5n")

        let loaded = try await store.samples(routeID: "r5n", from: base.addingTimeInterval(-60), to: base.addingTimeInterval(60))
        XCTAssertEqual(loaded.count, 2)

        let tomtom = try XCTUnwrap(loaded.first { $0.provider == .tomtom })
        XCTAssertEqual(tomtom.durationSeconds, 8040)
        XCTAssertEqual(tomtom.freeFlowSeconds, 6300)
        XCTAssertEqual(tomtom.distanceMeters, 179_104)
        XCTAssertEqual(tomtom.polyline, "_p~iF~ps|U")
        XCTAssertEqual(tomtom.incidents.count, 1)
        XCTAssertEqual(tomtom.incidents[0].description, "Obras")
        XCTAssertEqual(tomtom.incidents[0].routeRatio ?? -1, 0.4, accuracy: 0.0001)
        XCTAssertEqual(tomtom.incidents[0].location, Coordinate(lat: -32.787, lon: -71.189))
        XCTAssertTrue(tomtom.incidents[0].hasReliableEnd)
    }

    func testDeleteCascadesToIncidents() async throws {
        let store = try SampleStore.inMemory()
        let round = makeRound(at: base, durations: [.google: 7920])
        try await store.persist(round, routeID: "r5n")
        let before = try await store.incidentCount()
        XCTAssertEqual(before, 1)

        try await store.deleteSample(id: round.samples[.google]!.id)
        let after = try await store.incidentCount()
        XCTAssertEqual(after, 0, "el incidente no puede quedar huérfano")
    }

    func testRangeQueryRespectsBounds() async throws {
        let store = try SampleStore.inMemory()
        for offset in 0..<5 {
            try await store.persist(
                makeRound(at: base.addingTimeInterval(Double(offset) * 300), durations: [.google: 7900 + offset * 60]),
                routeID: "r5n"
            )
        }

        let window = try await store.samples(
            routeID: "r5n",
            from: base.addingTimeInterval(300),
            to: base.addingTimeInterval(900)
        )
        XCTAssertEqual(window.count, 3)
        XCTAssertEqual(window.map(\.durationSeconds), [7960, 8020, 8080], "debe venir ordenado por tiempo")
    }

    func testOtherRoutesAreNotReturned() async throws {
        let store = try SampleStore.inMemory()
        try await store.persist(makeRound(at: base, durations: [.google: 7920]), routeID: "r5n")
        try await store.persist(makeRound(at: base, durations: [.google: 4200]), routeID: "otra-ruta")

        let loaded = try await store.samples(routeID: "r5n", from: base.addingTimeInterval(-60), to: base.addingTimeInterval(60))
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].durationSeconds, 7920)
    }

    func testFailuresArePersisted() async throws {
        // Si un proveedor falla el 40% de las rondas, su consenso no vale nada.
        let store = try SampleStore.inMemory()
        for offset in 0..<3 {
            try await store.persist(
                makeRound(at: base.addingTimeInterval(Double(offset) * 300),
                          durations: [.tomtom: 8040],
                          failures: [.google: "HTTP 500"]),
                routeID: "r5n"
            )
        }
        let googleFailures = try await store.failureCount(routeID: "r5n", provider: .google)
        let tomtomFailures = try await store.failureCount(routeID: "r5n", provider: .tomtom)
        XCTAssertEqual(googleFailures, 3)
        XCTAssertEqual(tomtomFailures, 0)
    }

    func testRangeQueryUsesTheIndex() async throws {
        let store = try SampleStore.inMemory()
        try await store.persist(makeRound(at: base, durations: [.google: 7920]), routeID: "r5n")
        let plan = try await store.queryPlan()
        XCTAssertTrue(plan.contains("idx_sample_route_time"), "la consulta por rango no debe hacer scan completo: \(plan)")
    }
}
