import Foundation

/// Mapbox Directions con perfil `driving-traffic`. Ocupa el lugar que tenía
/// Google: ETA con tráfico y congestión por segmento, sin incidentes discretos.
/// Responde "dónde", no "por qué".
public struct MapboxProvider: TrafficProvider {
    public let id: ProviderID = .mapbox

    private let client: HTTPClient
    private let credentials: CredentialStore

    public init(client: HTTPClient = URLSessionHTTPClient(), credentials: CredentialStore = CredentialStore()) {
        self.client = client
        self.credentials = credentials
    }

    public func fetch(_ query: RouteQuery) async throws -> ETASample {
        let token = try credentials.apiKey(for: id)
        let capturedAt = Date()
        let data = try await client.fetchJSONBody(try makeRequest(query, token: token), provider: id)
        return try parse(data, capturedAt: capturedAt)
    }

    func makeRequest(_ query: RouteQuery, token: String) throws -> URLRequest {
        // Mapbox toma las coordenadas como lon,lat: al revés que los otros dos.
        let coordinates = ([query.origin] + query.waypoints + [query.destination])
            .map { "\($0.lon),\($0.lat)" }
            .joined(separator: ";")

        var components = URLComponents(
            string: "https://api.mapbox.com/directions/v5/mapbox/driving-traffic/\(coordinates)"
        )
        components?.queryItems = [
            .init(name: "access_token", value: token),
            .init(name: "geometries", value: "polyline"),
            .init(name: "overview", value: "full"),
            .init(name: "annotations", value: "congestion,duration"),
            .init(name: "steps", value: "false"),
        ]
        guard let url = components?.url else {
            throw ProviderError.transport("mapbox: URL inválida")
        }
        return URLRequest(url: url)
    }

    // MARK: - Parseo

    private struct Response: Decodable {
        struct Route: Decodable {
            let duration: Double?
            let durationTypical: Double?
            let distance: Double?
            let geometry: String?

            enum CodingKeys: String, CodingKey {
                case duration, distance, geometry
                case durationTypical = "duration_typical"
            }
        }
        let code: String?
        let message: String?
        let routes: [Route]?
    }

    func parse(_ data: Data, capturedAt: Date) throws -> ETASample {
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ProviderError.decoding("mapbox: \(error)")
        }

        // Mapbox responde 200 con code "NoRoute" en vez de un status de error.
        if let code = decoded.code, code != "Ok" {
            guard code == "NoRoute" || code == "NoSegment" else {
                throw ProviderError.decoding("mapbox: code \(code) \(decoded.message ?? "")")
            }
            throw ProviderError.noRoute
        }
        guard let route = decoded.routes?.first else { throw ProviderError.noRoute }
        guard let duration = route.duration, duration.isFinite,
              let distance = route.distance, distance.isFinite else {
            throw ProviderError.decoding("mapbox: ruta sin duration o distance")
        }

        // duration_typical es el tiempo habitual a esta hora, no el de flujo
        // libre: llenar freeFlowSeconds con él daría un delay que no es delay.
        // Se deja nil y manda el baseline del operador.
        return ETASample(
            provider: id,
            capturedAt: capturedAt,
            durationSeconds: Int(duration),
            freeFlowSeconds: nil,
            distanceMeters: Int(distance),
            polyline: route.geometry,
            incidents: []
        )
    }
}
