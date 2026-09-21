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

        // Valores reales capturados el 2026-09-20 sobre Ruta 5 Norte.
        XCTAssertEqual(sample.durationSeconds, 8412)
        XCTAssertEqual(sample.freeFlowSeconds, 7244)
        XCTAssertEqual(sample.distanceMeters, 161_479)
        // Nuestro delay (8412-7244=1168) no coincide con el trafficDelayInSeconds
        // que reporta TomTom (1079): su delay no se mide contra noTraffic. Nos
        // quedamos con el nuestro, que sí es reproducible desde los campos.
        XCTAssertEqual(sample.delaySeconds, 1168)
        XCTAssertNotNil(sample.polyline)
        XCTAssertEqual(client.requests.count, 2, "routing + incidentDetails")
    }

    func testIncidentDescriptionIsThePorQue() throws {
        let incidents = try provider(StubHTTPClient(replies: []))
            .parseIncidents(Fixtures.data("tomtom/incidents_happy.json"))

        XCTAssertEqual(incidents.count, 2)
        // Varios eventos describen la misma causa con más detalle: se unen.
        XCTAssertEqual(incidents[0].description, "Obras · Nuevo trazado de carretera por obras")
        XCTAssertEqual(incidents[0].category, .roadworks)
        // LineString: se toma el primer par, en orden [lon, lat].
        XCTAssertEqual(incidents[0].location?.lat ?? 0, -33.07798, accuracy: 0.00001)
        XCTAssertEqual(incidents[0].location?.lon ?? 0, -71.54869, accuracy: 0.00001)

        XCTAssertEqual(incidents[1].description, "Tráfico parado")
        XCTAssertEqual(incidents[1].category, .congestion)
        XCTAssertEqual(incidents[1].severity, 3)
        XCTAssertEqual(incidents[1].delaySeconds, 97)
    }

    func testCongestionEndTimeIsNotTreatedAsReliable() throws {
        // En la respuesta real ocurre lo contrario a lo que uno supondría:
        // las obras llegan sin endTime y el atasco sí trae uno. Ese endTime
        // del atasco es una predicción, no un compromiso, y no se usa para
        // estimar recuperación.
        let incidents = try provider(StubHTTPClient(replies: []))
            .parseIncidents(Fixtures.data("tomtom/incidents_happy.json"))

        let roadworks = incidents[0]
        let congestion = incidents[1]

        XCTAssertEqual(roadworks.category, .roadworks)
        XCTAssertNil(roadworks.endTime, "las obras reales vinieron sin fin")
        XCTAssertFalse(roadworks.hasReliableEnd)

        XCTAssertNotNil(congestion.endTime, "el atasco sí trae un fin estimado")
        XCTAssertFalse(congestion.hasReliableEnd, "pero no es confiable: es una predicción")
    }

    func testIncidentIDIsStableAcrossRounds() throws {
        // Sin id propio de TomTom, el id se deriva del contenido: el mismo
        // incidente conserva su id aunque cambie de posición en la lista.
        let p = provider(StubHTTPClient(replies: []))
        let first = try p.parseIncidents(Fixtures.data("tomtom/incidents_happy.json"))
        let second = try p.parseIncidents(Fixtures.data("tomtom/incidents_happy.json"))
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertFalse(first[0].id.hasSuffix("-0"), "no debe depender del índice: \(first[0].id)")
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
        // Sin coordenadas el id cae al índice, que es lo único que queda.
        XCTAssertTrue(incidents[0].id.contains("accident"))
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
        XCTAssertEqual(sample.durationSeconds, 8412)
        XCTAssertTrue(sample.incidents.isEmpty)
    }

    func testShortRetryAfterIsRetriedOnce() async throws {
        // Límite por segundo con Retry-After: 1. Se espera y se reintenta.
        let client = StubHTTPClient(replies: [
            .init(status: 429, data: Data(), headers: ["Retry-After": "1"]),
            .init(data: Fixtures.data("tomtom/route_happy.json")),
        ], fallback: .init(data: Data("{}".utf8)))
        let sample = try await provider(client).fetch(testQuery)
        XCTAssertEqual(sample.durationSeconds, 8412)
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
