import XCTest
@testable import TrafficCore

final class TomTomParsingTests: XCTestCase {
    private func provider(_ client: HTTPClient) -> TomTomProvider {
        TomTomProvider(client: client, credentials: .stub())
    }

    func testParsesRouteAndIncidents() async throws {
        let client = StubHTTPClient(replies: [
            .init(data: Fixtures.data("tomtom/route_happy.json")),
            .init(data: Fixtures.data("tomtom/incidents_happy.json")),
        ])
        let sample = try await provider(client).fetch(testQuery)

        XCTAssertEqual(sample.durationSeconds, 8040)
        XCTAssertEqual(sample.freeFlowSeconds, 6300)
        XCTAssertEqual(sample.distanceMeters, 179104)
        XCTAssertEqual(sample.delaySeconds, 1740, "debe cuadrar con trafficDelayInSeconds")
        XCTAssertNotNil(sample.polyline)
        XCTAssertEqual(client.requests.count, 2, "routing + incidentDetails")
    }

    func testIncidentDescriptionIsThePorQue() throws {
        let incidents = try provider(StubHTTPClient(replies: []))
            .parseIncidents(Fixtures.data("tomtom/incidents_happy.json"))

        XCTAssertEqual(incidents.count, 2)
        XCTAssertEqual(incidents[0].description, "Tráfico lento")
        XCTAssertEqual(incidents[0].category, .congestion)
        XCTAssertEqual(incidents[0].severity, 3)
        XCTAssertEqual(incidents[0].delaySeconds, 900)
        // LineString: se toma el primer par, en orden [lon, lat].
        XCTAssertEqual(incidents[0].location, Coordinate(lat: -32.7870, lon: -71.1890))
    }

    func testRoadworksHasReliableEndButCongestionDoesNot() throws {
        let incidents = try provider(StubHTTPClient(replies: []))
            .parseIncidents(Fixtures.data("tomtom/incidents_happy.json"))

        let congestion = incidents[0]
        let roadworks = incidents[1]
        XCTAssertEqual(roadworks.category, .roadworks)
        XCTAssertNotNil(roadworks.endTime)
        XCTAssertTrue(roadworks.hasReliableEnd, "obras programadas: el fin sí es dato")
        XCTAssertFalse(congestion.hasReliableEnd, "la congestión no tiene fin confiable")
    }

    func testIncidentWithoutEndTimeAndNullCoordinates() throws {
        let incidents = try provider(StubHTTPClient(replies: []))
            .parseIncidents(Fixtures.data("tomtom/incidents_no_endtime_null_coords.json"))

        XCTAssertEqual(incidents.count, 1)
        XCTAssertEqual(incidents[0].category, .accident)
        XCTAssertEqual(incidents[0].severity, 4)
        XCTAssertNil(incidents[0].endTime)
        XCTAssertNil(incidents[0].location, "coordenadas nulas no se inventan")
        // Sin id propio se sintetiza uno estable por posición.
        XCTAssertEqual(incidents[0].id, "tomtom-0")
    }

    func testIconCategoryTable() {
        XCTAssertEqual(TomTomProvider.category(for: 1), .accident)
        XCTAssertEqual(TomTomProvider.category(for: 6), .congestion)
        XCTAssertEqual(TomTomProvider.category(for: 7), .closure)
        XCTAssertEqual(TomTomProvider.category(for: 8), .closure)
        XCTAssertEqual(TomTomProvider.category(for: 9), .roadworks)
        XCTAssertEqual(TomTomProvider.category(for: 14), .hazard)
        XCTAssertEqual(TomTomProvider.category(for: 4), .weather)
        // Lo no mapeado cae en .unknown en vez de inventar categoría.
        XCTAssertEqual(TomTomProvider.category(for: 99), .unknown)
        XCTAssertEqual(TomTomProvider.category(for: nil), .unknown)
    }

    func testEmptyIncidentsIsNotAnError() throws {
        let incidents = try provider(StubHTTPClient(replies: []))
            .parseIncidents(Fixtures.data("tomtom/incidents_empty.json"))
        XCTAssertTrue(incidents.isEmpty)
    }

    func testNoRoutes() async {
        let client = StubHTTPClient(replies: [.init(data: Fixtures.data("tomtom/route_no_routes.json"))])
        await XCTAssertThrowsProviderError(try await provider(client).fetch(testQuery)) { error in
            XCTAssertEqual(error, .noRoute)
        }
    }

    func testIncompleteSummaryIsDecodingError() async {
        let client = StubHTTPClient(replies: [.init(data: Fixtures.data("tomtom/route_summary_incomplete.json"))])
        await XCTAssertThrowsProviderError(try await provider(client).fetch(testQuery)) { error in
            guard case .decoding = error else { return XCTFail("esperaba .decoding, fue \(error)") }
        }
    }

    func testIncidentFailureDoesNotLoseTheETA() async throws {
        // La causa es un extra; perderla no puede costarnos la ETA.
        let client = StubHTTPClient(replies: [
            .init(data: Fixtures.data("tomtom/route_happy.json")),
            .init(status: 500, data: Data("boom".utf8)),
        ])
        let sample = try await provider(client).fetch(testQuery)
        XCTAssertEqual(sample.durationSeconds, 8040)
        XCTAssertTrue(sample.incidents.isEmpty)
    }

    func testRouteRateLimitIsSurfaced() async {
        let client = StubHTTPClient(replies: [
            .init(status: 429, data: Data(), headers: ["Retry-After": "12"])
        ])
        await XCTAssertThrowsProviderError(try await provider(client).fetch(testQuery)) { error in
            XCTAssertEqual(error, .rateLimited(retryAfter: 12))
        }
    }

    func testRequestShape() throws {
        let p = provider(StubHTTPClient(replies: []))
        let url = try XCTUnwrap(p.routeRequest(testQuery, key: "k").url?.absoluteString)
        // El waypoint va en medio: fuerza el corredor de Ruta 5 Norte.
        XCTAssertTrue(url.contains("-32.6558,-71.439:-32.787,-71.189:-33.4089,-70.568"))
        XCTAssertTrue(url.contains("traffic=true"))
        XCTAssertTrue(url.contains("sectionType=traffic"))

        let bbox = BoundingBox(west: -71.5, south: -33.5, east: -70.5, north: -32.6)
        let incidentURL = try XCTUnwrap(p.incidentRequest(bbox, key: "k").url?.absoluteString)
        XCTAssertTrue(incidentURL.contains("bbox=-71.5,-33.5,-70.5,-32.6"))
        XCTAssertTrue(incidentURL.contains("language=es-ES"))
    }
}
