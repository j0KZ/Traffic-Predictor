import XCTest
@testable import TrafficCore

final class GoogleParsingTests: XCTestCase {
    private func provider(_ client: HTTPClient) -> GoogleRoutesProvider {
        GoogleRoutesProvider(client: client, credentials: .stub())
    }

    func testParsesHappyPath() async throws {
        let sample = try await provider(StubHTTPClient(fixture: "google/happy.json")).fetch(testQuery)

        XCTAssertEqual(sample.provider, .google)
        XCTAssertEqual(sample.durationSeconds, 7920)
        XCTAssertEqual(sample.freeFlowSeconds, 6300)
        XCTAssertEqual(sample.distanceMeters, 178432)
        XCTAssertEqual(sample.delaySeconds, 1620)
        XCTAssertNotNil(sample.polyline)
        XCTAssertTrue(sample.incidents.isEmpty, "Google no entrega incidentes por esta vía")
    }

    func testParsesDurationSuffix() throws {
        XCTAssertEqual(try DurationParser.parseGoogleDuration("8340s"), 8340)
        XCTAssertEqual(try DurationParser.parseGoogleDuration("0s"), 0)
        // Fracciones se truncan al segundo: no necesitamos milisegundos.
        XCTAssertEqual(try DurationParser.parseGoogleDuration("7920.9s"), 7920)
    }

    func testDurationWithoutSuffixIsRejected() async {
        let p = provider(StubHTTPClient(fixture: "google/duration_without_suffix.json"))
        await XCTAssertThrowsProviderError(try await p.fetch(testQuery)) { error in
            guard case .decoding = error else { return XCTFail("esperaba .decoding, fue \(error)") }
        }
    }

    func testEmptyRoutesIsNoRoute() async {
        let p = provider(StubHTTPClient(fixture: "google/no_routes.json"))
        await XCTAssertThrowsProviderError(try await p.fetch(testQuery)) { error in
            XCTAssertEqual(error, .noRoute)
        }
    }

    func testMissingStaticDurationLeavesFreeFlowNil() async throws {
        let sample = try await provider(StubHTTPClient(fixture: "google/missing_static_duration.json")).fetch(testQuery)
        XCTAssertNil(sample.freeFlowSeconds)
        // Sin free-flow no se inventa un delay.
        XCTAssertNil(sample.delaySeconds)
    }

    func testPastDepartureReturns400() async {
        let client = StubHTTPClient(replies: [
            .init(status: 400, data: Fixtures.data("google/error_400_past_departure.json"))
        ])
        await XCTAssertThrowsProviderError(try await provider(client).fetch(testQuery)) { error in
            guard case .http(let status, let body) = error else { return XCTFail("esperaba .http, fue \(error)") }
            XCTAssertEqual(status, 400)
            XCTAssertTrue(body.contains("departure_time"))
        }
    }

    func testMalformedJSONIsDecodingError() async {
        let p = provider(StubHTTPClient(fixture: "google/malformed.json"))
        await XCTAssertThrowsProviderError(try await p.fetch(testQuery)) { error in
            guard case .decoding = error else { return XCTFail("esperaba .decoding, fue \(error)") }
        }
    }

    func testEmptyBodyWith200IsDecodingError() async {
        let client = StubHTTPClient(replies: [.init(status: 200, data: Data())])
        await XCTAssertThrowsProviderError(try await provider(client).fetch(testQuery)) { error in
            guard case .decoding = error else { return XCTFail("esperaba .decoding, fue \(error)") }
        }
    }

    func testRateLimitCarriesRetryAfter() async {
        let client = StubHTTPClient(replies: [
            .init(status: 429, data: Data("rate limited".utf8), headers: ["Retry-After": "30"])
        ])
        await XCTAssertThrowsProviderError(try await provider(client).fetch(testQuery)) { error in
            XCTAssertEqual(error, .rateLimited(retryAfter: 30))
        }
    }

    func testUnauthorizedAndForbiddenAndServerErrorSurfaceStatus() async {
        for status in [401, 403, 500] {
            let client = StubHTTPClient(replies: [.init(status: status, data: Data("nope".utf8))])
            await XCTAssertThrowsProviderError(try await provider(client).fetch(testQuery)) { error in
                guard case .http(let received, _) = error else { return XCTFail("esperaba .http, fue \(error)") }
                XCTAssertEqual(received, status)
            }
        }
    }

    func testMissingCredentialIsReportedBeforeAnyRequest() async {
        let client = StubHTTPClient(replies: [])
        let p = GoogleRoutesProvider(client: client, credentials: CredentialStore(environment: [:]))
        await XCTAssertThrowsProviderError(try await p.fetch(testQuery)) { error in
            XCTAssertEqual(error, .missingCredential(.google))
        }
        XCTAssertTrue(client.requests.isEmpty, "no debe salir a la red sin credencial")
    }

    func testRequestShape() throws {
        let p = provider(StubHTTPClient(replies: []))
        let now = Date(timeIntervalSince1970: 1_758_000_000)
        let request = try p.makeRequest(testQuery, key: "k", now: now)

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-Api-Key"), "k")
        XCTAssertTrue(request.value(forHTTPHeaderField: "X-Goog-FieldMask")?.contains("routes.staticDuration") == true)

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["routingPreference"] as? String, "TRAFFIC_AWARE_OPTIMAL")

        // departureTime debe ser futuro o Google responde 400.
        let departure = try XCTUnwrap(ISO8601.parse(json["departureTime"] as? String))
        XCTAssertGreaterThan(departure, now)

        let intermediates = try XCTUnwrap(json["intermediates"] as? [[String: Any]])
        XCTAssertEqual(intermediates.count, 1)
        XCTAssertEqual(intermediates[0]["via"] as? Bool, true)
    }
}

/// XCTAssertThrowsError no acepta funciones async; esta sí.
func XCTAssertThrowsProviderError<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ check: (ProviderError) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("no lanzó error", file: file, line: line)
    } catch let error as ProviderError {
        check(error)
    } catch {
        XCTFail("error no tipado: \(error)", file: file, line: line)
    }
}
