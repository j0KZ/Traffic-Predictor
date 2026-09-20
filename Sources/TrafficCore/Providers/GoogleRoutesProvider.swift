import Foundation

/// Google Routes API v2. Entrega duración con y sin tráfico y, con
/// TRAFFIC_ON_POLYLINE, dónde está lento. No entrega incidentes discretos:
/// responde "dónde", nunca "por qué".
public struct GoogleRoutesProvider: TrafficProvider {
    public let id: ProviderID = .google

    private let client: HTTPClient
    private let credentials: CredentialStore
    private let endpoint = URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes")!

    private static let fieldMask = [
        "routes.duration",
        "routes.staticDuration",
        "routes.distanceMeters",
        "routes.polyline.encodedPolyline",
        "routes.travelAdvisory",
        "routes.legs.travelAdvisory.speedReadingIntervals",
    ].joined(separator: ",")

    public init(client: HTTPClient = URLSessionHTTPClient(), credentials: CredentialStore = CredentialStore()) {
        self.client = client
        self.credentials = credentials
    }

    public func fetch(_ query: RouteQuery) async throws -> ETASample {
        let key = try credentials.apiKey(for: id)
        let capturedAt = Date()
        let request = try makeRequest(query, key: key, now: capturedAt)
        let data = try await client.fetchJSONBody(request, provider: id)
        return try parse(data, capturedAt: capturedAt)
    }

    func makeRequest(_ query: RouteQuery, key: String, now: Date) throws -> URLRequest {
        // departureTime debe ser futuro o Google responde 400.
        let departure = query.departAt ?? now.addingTimeInterval(30)

        var body: [String: Any] = [
            "origin": Self.waypointJSON(query.origin, via: false),
            "destination": Self.waypointJSON(query.destination, via: false),
            "travelMode": "DRIVE",
            "routingPreference": "TRAFFIC_AWARE_OPTIMAL",
            "departureTime": ISO8601.string(from: departure),
            "extraComputations": ["TRAFFIC_ON_POLYLINE"],
        ]
        if !query.waypoints.isEmpty {
            body["intermediates"] = query.waypoints.map { Self.waypointJSON($0, via: true) }
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(Self.fieldMask, forHTTPHeaderField: "X-Goog-FieldMask")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func waypointJSON(_ c: Coordinate, via: Bool) -> [String: Any] {
        var json: [String: Any] = [
            "location": ["latLng": ["latitude": c.lat, "longitude": c.lon]]
        ]
        if via { json["via"] = true }
        return json
    }

    // MARK: - Parseo

    private struct Response: Decodable {
        struct Route: Decodable {
            struct Polyline: Decodable { let encodedPolyline: String? }
            let duration: String?
            let staticDuration: String?
            let distanceMeters: Int?
            let polyline: Polyline?
        }
        let routes: [Route]?
    }

    func parse(_ data: Data, capturedAt: Date) throws -> ETASample {
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ProviderError.decoding("google: \(error)")
        }

        // 200 con `routes: []` significa que no hay ruta viable, no un error HTTP.
        guard let route = decoded.routes?.first else {
            throw ProviderError.noRoute
        }
        guard let rawDuration = route.duration else {
            throw ProviderError.decoding("google: ruta sin duration")
        }
        guard let distance = route.distanceMeters else {
            throw ProviderError.decoding("google: ruta sin distanceMeters")
        }

        let duration = try DurationParser.parseGoogleDuration(rawDuration)
        // staticDuration es opcional: si viene mal formada preferimos no tener
        // free-flow antes que inventar un delay falso.
        let freeFlow = route.staticDuration.flatMap { try? DurationParser.parseGoogleDuration($0) }

        return ETASample(
            provider: id,
            capturedAt: capturedAt,
            durationSeconds: duration,
            freeFlowSeconds: freeFlow,
            distanceMeters: distance,
            polyline: route.polyline?.encodedPolyline,
            incidents: []
        )
    }
}
