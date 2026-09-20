import XCTest
@testable import TrafficCore

final class MapboxParsingTests: XCTestCase {
    private func provider(_ client: HTTPClient) -> MapboxProvider {
        MapboxProvider(client: client, credentials: .stub())
    }

    func testParsesHappyPath() async throws {
        let sample = try await provider(StubHTTPClient(fixture: "mapbox/happy.json")).fetch(testQuery)

        XCTAssertEqual(sample.provider, .mapbox)
        // Valores reales capturados el 2026-09-20 sobre Ruta 5 Norte.
        XCTAssertEqual(sample.durationSeconds, 7021, "se trunca al segundo")
        XCTAssertEqual(sample.distanceMeters, 164_793)
        XCTAssertNotNil(sample.polyline)
        XCTAssertTrue(sample.incidents.isEmpty, "Mapbox no entrega incidentes discretos")
    }

    func testTypicalDurationIsNotUsedAsFreeFlow() async throws {
        // duration_typical es el tiempo habitual a esta hora, no el de flujo
        // libre. Usarlo daría un delay que no es delay.
        let sample = try await provider(StubHTTPClient(fixture: "mapbox/happy.json")).fetch(testQuery)
        XCTAssertNil(sample.freeFlowSeconds)
        XCTAssertNil(sample.delaySeconds)
        // El baseline del operador sí produce un delay real.
        XCTAssertEqual(sample.delaySeconds(baseline: 6300), 721)
    }

    func testCoverageMeasuresHowMuchTrafficDataThereActuallyIs() async throws {
        // Mapbox marca "unknown" donde no tiene cobertura. En Ruta 5 Norte eso
        // fue el 67% del trazado en la captura real: su ETA es mayormente
        // tiempo histórico, no medición en vivo.
        let sample = try await provider(StubHTTPClient(fixture: "mapbox/happy.json")).fetch(testQuery)
        let coverage = try XCTUnwrap(sample.trafficCoverage)
        XCTAssertEqual(coverage, 5.0 / 8.0, accuracy: 0.001)
    }

    func testCoverageIsNilWhenNoAnnotationsRequested() {
        XCTAssertNil(MapboxProvider.coverage(nil))
        XCTAssertNil(MapboxProvider.coverage([]))
    }

    func testCoverageIsZeroWhenEverythingIsUnknown() {
        let coverage = try? XCTUnwrap(MapboxProvider.coverage(["unknown", "unknown"]))
        XCTAssertEqual(coverage ?? -1, 0)
    }

    func testNoRouteCodeWith200IsNoRoute() async {
        // Mapbox responde 200 con code "NoRoute" en vez de un status de error.
        let p = provider(StubHTTPClient(fixture: "mapbox/no_route.json"))
        await XCTAssertThrowsProviderError(try await p.fetch(testQuery)) { error in
            XCTAssertEqual(error, .noRoute)
        }
    }

    func testInvalidInputCodeIsDecodingError() async {
        let p = provider(StubHTTPClient(fixture: "mapbox/invalid_input.json"))
        await XCTAssertThrowsProviderError(try await p.fetch(testQuery)) { error in
            guard case .decoding(let detail) = error else { return XCTFail("esperaba .decoding, fue \(error)") }
            XCTAssertTrue(detail.contains("InvalidInput"))
        }
    }

    func testMissingDurationIsDecodingError() async {
        let p = provider(StubHTTPClient(fixture: "mapbox/missing_duration.json"))
        await XCTAssertThrowsProviderError(try await p.fetch(testQuery)) { error in
            guard case .decoding = error else { return XCTFail("esperaba .decoding, fue \(error)") }
        }
    }

    func testMalformedJSONIsDecodingError() async {
        let p = provider(StubHTTPClient(fixture: "mapbox/malformed.json"))
        await XCTAssertThrowsProviderError(try await p.fetch(testQuery)) { error in
            guard case .decoding = error else { return XCTFail("esperaba .decoding, fue \(error)") }
        }
    }

    func testEmptyBodyAndErrorStatuses() async {
        let empty = StubHTTPClient(replies: [.init(status: 200, data: Data())])
        await XCTAssertThrowsProviderError(try await provider(empty).fetch(testQuery)) { error in
            guard case .decoding = error else { return XCTFail("esperaba .decoding, fue \(error)") }
        }
        for status in [401, 403, 422, 500] {
            let client = StubHTTPClient(replies: [.init(status: status, data: Data("nope".utf8))])
            await XCTAssertThrowsProviderError(try await provider(client).fetch(testQuery)) { error in
                guard case .http(let received, _) = error else { return XCTFail("esperaba .http, fue \(error)") }
                XCTAssertEqual(received, status)
            }
        }
    }

    func testRateLimitCarriesRetryAfter() async {
        let client = StubHTTPClient(replies: [
            .init(status: 429, data: Data(), headers: ["Retry-After": "5"])
        ])
        await XCTAssertThrowsProviderError(try await provider(client).fetch(testQuery)) { error in
            XCTAssertEqual(error, .rateLimited(retryAfter: 5))
        }
    }

    func testMissingCredentialIsReportedBeforeAnyRequest() async {
        let client = StubHTTPClient(replies: [])
        let p = MapboxProvider(client: client, credentials: CredentialStore(environment: [:]))
        await XCTAssertThrowsProviderError(try await p.fetch(testQuery)) { error in
            XCTAssertEqual(error, .missingCredential(.mapbox))
        }
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testRequestShapeUsesLonLatOrder() throws {
        let p = provider(StubHTTPClient(replies: []))
        let url = try XCTUnwrap(p.makeRequest(testQuery, token: "tok").url?.absoluteString)

        XCTAssertTrue(url.contains("driving-traffic"))
        // Mapbox toma lon,lat: al revés que TomTom y HERE.
        XCTAssertTrue(url.contains("-71.439,-32.6558;-71.189,-32.787;-70.568,-33.4089"),
                      "orden lon,lat con el waypoint en medio: \(url)")
        XCTAssertTrue(url.contains("annotations=congestion,duration") || url.contains("annotations=congestion%2Cduration"))
        XCTAssertTrue(url.contains("overview=full"))
    }
}
