import XCTest
@testable import TrafficCore

final class HereParsingTests: XCTestCase {
    private func provider(_ client: HTTPClient) -> HereProvider {
        HereProvider(client: client, credentials: .stub())
    }

    func testSumsMultipleSections() async throws {
        let client = StubHTTPClient(replies: [
            .init(data: Fixtures.data("here/route_happy.json")),
            .init(data: Fixtures.data("here/incidents_happy.json")),
        ])
        let sample = try await provider(client).fetch(testQuery)

        XCTAssertEqual(sample.durationSeconds, 4100 + 3980)
        XCTAssertEqual(sample.freeFlowSeconds, 3200 + 3100)
        XCTAssertEqual(sample.distanceMeters, 92000 + 87104)
        XCTAssertNotNil(sample.polyline)
    }

    func testMissingBaseDurationInOneSectionDropsFreeFlowEntirely() throws {
        // Una suma parcial sería un free-flow falso, y con él un delay falso.
        let sample = try provider(StubHTTPClient(replies: []))
            .parseRoute(Fixtures.data("here/route_section_missing_base_duration.json"), capturedAt: .now)

        XCTAssertEqual(sample.durationSeconds, 8080)
        XCTAssertNil(sample.freeFlowSeconds)
        XCTAssertNil(sample.delaySeconds)
    }

    func testSectionWithoutDurationIsDecodingError() {
        XCTAssertThrowsError(
            try provider(StubHTTPClient(replies: []))
                .parseRoute(Fixtures.data("here/route_section_missing_duration.json"), capturedAt: .now)
        ) { error in
            guard case ProviderError.decoding = error else { return XCTFail("esperaba .decoding, fue \(error)") }
        }
    }

    func testNoRoutes() async {
        let client = StubHTTPClient(replies: [.init(data: Fixtures.data("here/route_no_routes.json"))])
        await XCTAssertThrowsProviderError(try await provider(client).fetch(testQuery)) { error in
            XCTAssertEqual(error, .noRoute)
        }
    }

    func testCorruptPolylineDoesNotKillTheETA() throws {
        let sample = try provider(StubHTTPClient(replies: []))
            .parseRoute(Fixtures.data("here/route_corrupt_polyline.json"), capturedAt: .now)

        XCTAssertEqual(sample.durationSeconds, 4100)
        XCTAssertNil(sample.polyline, "polyline vacío antes que polyline inventado")
    }

    func testIncidentMapping() throws {
        let incidents = try provider(StubHTTPClient(replies: []))
            .parseIncidents(Fixtures.data("here/incidents_happy.json"))

        XCTAssertEqual(incidents.count, 2)
        XCTAssertEqual(incidents[0].id, "here-acc-001")
        XCTAssertEqual(incidents[0].category, .accident)
        XCTAssertEqual(incidents[0].severity, 3)
        XCTAssertEqual(incidents[0].description, "Accidente de tránsito, pista derecha bloqueada")
        XCTAssertEqual(incidents[0].location, Coordinate(lat: -32.7870, lon: -71.1890))
        XCTAssertFalse(incidents[0].hasReliableEnd)

        XCTAssertEqual(incidents[1].category, .roadworks)
        XCTAssertTrue(incidents[1].hasReliableEnd)
    }

    func testIncidentWithoutShapeHasNoLocation() throws {
        let incidents = try provider(StubHTTPClient(replies: []))
            .parseIncidents(Fixtures.data("here/incidents_missing_shape.json"))
        XCTAssertEqual(incidents.count, 1)
        XCTAssertNil(incidents[0].location)
    }

    func testEmptyIncidents() throws {
        let incidents = try provider(StubHTTPClient(replies: []))
            .parseIncidents(Fixtures.data("here/incidents_empty.json"))
        XCTAssertTrue(incidents.isEmpty)
    }

    func testCriticalityNormalizesToZeroFour() {
        XCTAssertEqual(HereProvider.severity(for: "low"), 1)
        XCTAssertEqual(HereProvider.severity(for: "critical"), 4)
        XCTAssertNil(HereProvider.severity(for: "wat"))
    }

    func testRequestShape() throws {
        let p = provider(StubHTTPClient(replies: []))
        let url = try XCTUnwrap(p.routeRequest(testQuery, key: "k").url?.absoluteString)
        XCTAssertTrue(url.contains("origin=-32.6558,-71.439"))
        XCTAssertTrue(url.contains("destination=-33.4089,-70.568"))
        // passThrough evita que HERE trate el waypoint como parada.
        XCTAssertTrue(url.contains("passThrough%3Dtrue") || url.contains("passThrough=true"))
        XCTAssertTrue(url.contains("departureTime=now"))
    }

    func testAuthErrorIsSurfaced() async {
        let client = StubHTTPClient(replies: [.init(status: 401, data: Data("unauthorized".utf8))])
        await XCTAssertThrowsProviderError(try await provider(client).fetch(testQuery)) { error in
            guard case .http(let status, _) = error else { return XCTFail("esperaba .http, fue \(error)") }
            XCTAssertEqual(status, 401)
        }
    }
}

final class FlexiblePolylineTests: XCTestCase {
    /// Vector de prueba oficial de heremaps/flexible-polyline.
    func testDecodesReferenceVector() throws {
        let points = try FlexiblePolyline.decode("BFoz5xJ67i1B1B7PzIhaxL7Y")
        let expected = [
            Coordinate(lat: 50.10228, lon: 8.69821),
            Coordinate(lat: 50.10201, lon: 8.69567),
            Coordinate(lat: 50.10063, lon: 8.69150),
            Coordinate(lat: 50.09878, lon: 8.68752),
        ]
        XCTAssertEqual(points.count, expected.count)
        for (got, want) in zip(points, expected) {
            XCTAssertEqual(got.lat, want.lat, accuracy: 0.00001)
            XCTAssertEqual(got.lon, want.lon, accuracy: 0.00001)
        }
    }

    func testEmptyInputThrows() {
        XCTAssertThrowsError(try FlexiblePolyline.decode("")) { error in
            XCTAssertEqual(error as? FlexiblePolyline.DecodeError, .empty)
        }
    }

    func testInvalidCharacterThrows() {
        XCTAssertThrowsError(try FlexiblePolyline.decode("BFoz5xJ!!!")) { error in
            guard case FlexiblePolyline.DecodeError.invalidCharacter = error else {
                return XCTFail("esperaba .invalidCharacter, fue \(error)")
            }
        }
    }
}

final class PolylineTests: XCTestCase {
    func testRoundTrip() {
        let original = [
            Coordinate(lat: -32.6558, lon: -71.4390),
            Coordinate(lat: -32.7870, lon: -71.1890),
            Coordinate(lat: -33.4089, lon: -70.5680),
        ]
        let decoded = Polyline.decode(Polyline.encode(original))
        XCTAssertEqual(decoded.count, original.count)
        for (a, b) in zip(decoded, original) {
            XCTAssertEqual(a.lat, b.lat, accuracy: 0.00001)
            XCTAssertEqual(a.lon, b.lon, accuracy: 0.00001)
        }
    }

    func testEmptyStringDecodesToNothing() {
        XCTAssertTrue(Polyline.decode("").isEmpty)
    }

    func testTruncatedInputReturnsWhatItCould() {
        // Entrada cortada: se devuelve lo decodificado, no se revienta.
        XCTAssertNoThrow(Polyline.decode("_p~iF~ps|U_ulL"))
    }
}
