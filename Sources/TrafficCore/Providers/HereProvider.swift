import Foundation

/// HERE: router v8 para la ETA, traffic v7 para la causa.
/// La ruta llega partida en secciones que hay que sumar, y el polyline viene
/// en flexible polyline, no en el encoded de Google.
public struct HereProvider: TrafficProvider {
    public let id: ProviderID = .here

    private let client: HTTPClient
    private let credentials: CredentialStore
    /// false ahorra la cuota de incidentes, la más escasa. Para calibrar
    /// solo importa la ETA.
    private let fetchIncidents: Bool

    public init(
        client: HTTPClient = URLSessionHTTPClient(),
        credentials: CredentialStore = CredentialStore(),
        fetchIncidents: Bool = true
    ) {
        self.client = client
        self.credentials = credentials
        self.fetchIncidents = fetchIncidents
    }

    public func fetch(_ query: RouteQuery) async throws -> ETASample {
        let key = try credentials.apiKey(for: id)
        let capturedAt = Date()

        let routeData = try await client.fetchJSONBody(try routeRequest(query, key: key), provider: id)
        var sample = try parseRoute(routeData, capturedAt: capturedAt)

        guard fetchIncidents else { return sample }
        let points = sample.polyline.map { Polyline.decode($0) } ?? []
        if let bbox = BoundingBox(points: points) {
            // Igual que en TomTom: sin causa seguimos teniendo ETA.
            if let incidentData = try? await client.fetchJSONBody(incidentRequest(bbox, key: key), provider: id),
               let incidents = try? parseIncidents(incidentData) {
                sample.incidents = incidents
            }
        }
        return sample
    }

    // MARK: - Requests

    func routeRequest(_ query: RouteQuery, key: String) throws -> URLRequest {
        var items: [URLQueryItem] = [
            .init(name: "apiKey", value: key),
            .init(name: "transportMode", value: "car"),
            .init(name: "origin", value: "\(query.origin.lat),\(query.origin.lon)"),
            .init(name: "destination", value: "\(query.destination.lat),\(query.destination.lon)"),
            .init(name: "return", value: "summary,polyline,travelSummary"),
            .init(name: "departureTime", value: "now"),
        ]
        // passThrough evita que HERE trate el waypoint como parada con espera.
        for w in query.waypoints {
            items.append(.init(name: "via", value: "\(w.lat),\(w.lon)!passThrough=true"))
        }

        var components = URLComponents(string: "https://router.hereapi.com/v8/routes")
        components?.queryItems = items
        guard let url = components?.url else {
            throw ProviderError.transport("here: URL de ruta inválida")
        }
        return URLRequest(url: url)
    }

    func incidentRequest(_ bbox: BoundingBox, key: String) throws -> URLRequest {
        var components = URLComponents(string: "https://data.traffic.hereapi.com/v7/incidents")
        components?.queryItems = [
            .init(name: "apiKey", value: key),
            .init(name: "in", value: "bbox:\(bbox.west),\(bbox.south),\(bbox.east),\(bbox.north)"),
            .init(name: "locationReferencing", value: "shape"),
        ]
        guard let url = components?.url else {
            throw ProviderError.transport("here: URL de incidentes inválida")
        }
        return URLRequest(url: url)
    }

    // MARK: - Parseo de ruta

    private struct RouteResponse: Decodable {
        struct Route: Decodable {
            struct Section: Decodable {
                struct Summary: Decodable {
                    let duration: Int?
                    let baseDuration: Int?
                    let length: Int?
                }
                let summary: Summary?
                let polyline: String?
            }
            let sections: [Section]?
        }
        let routes: [Route]?
    }

    func parseRoute(_ data: Data, capturedAt: Date) throws -> ETASample {
        let decoded: RouteResponse
        do {
            decoded = try JSONDecoder().decode(RouteResponse.self, from: data)
        } catch {
            throw ProviderError.decoding("here: \(error)")
        }

        guard let route = decoded.routes?.first, let sections = route.sections, !sections.isEmpty else {
            throw ProviderError.noRoute
        }

        var duration = 0
        var distance = 0
        // baseDuration es opcional por sección: si falta en alguna, la suma
        // parcial sería un free-flow falso, así que se descarta entera.
        var baseDuration: Int? = 0
        var points: [Coordinate] = []

        for section in sections {
            guard let summary = section.summary, let d = summary.duration else {
                throw ProviderError.decoding("here: sección sin duration")
            }
            duration += d
            distance += summary.length ?? 0

            if let base = summary.baseDuration, baseDuration != nil {
                baseDuration! += base
            } else {
                baseDuration = nil
            }

            if let encoded = section.polyline {
                // Un polyline corrupto en una sección no debe tumbar la ETA.
                if let decodedPoints = try? FlexiblePolyline.decode(encoded) {
                    points.append(contentsOf: decodedPoints)
                }
            }
        }

        return ETASample(
            provider: id,
            capturedAt: capturedAt,
            durationSeconds: duration,
            freeFlowSeconds: baseDuration,
            distanceMeters: distance,
            polyline: points.isEmpty ? nil : Polyline.encode(points),
            incidents: []
        )
    }

    // MARK: - Parseo de incidentes

    private struct IncidentResponse: Decodable {
        struct Result: Decodable {
            struct Location: Decodable {
                struct Shape: Decodable {
                    struct Link: Decodable {
                        struct Point: Decodable { let lat: Double?; let lng: Double? }
                        let points: [Point]?
                    }
                    let links: [Link]?
                }
                let shape: Shape?
            }
            struct Details: Decodable {
                struct Text: Decodable { let value: String? }
                let id: String?
                let description: Text?
                let type: String?
                let criticality: String?
                let startTime: String?
                let endTime: String?
            }
            let location: Location?
            let incidentDetails: Details?
        }
        let results: [Result]?
    }

    func parseIncidents(_ data: Data) throws -> [TrafficIncident] {
        let decoded: IncidentResponse
        do {
            decoded = try JSONDecoder().decode(IncidentResponse.self, from: data)
        } catch {
            throw ProviderError.decoding("here incidentes: \(error)")
        }

        return (decoded.results ?? []).enumerated().map { offset, result in
            let details = result.incidentDetails
            let firstPoint = result.location?.shape?.links?
                .compactMap(\.points).first?.first
            let location: Coordinate? = {
                guard let lat = firstPoint?.lat, let lon = firstPoint?.lng,
                      lat.isFinite, lon.isFinite else { return nil }
                return Coordinate(lat: lat, lon: lon)
            }()

            return TrafficIncident(
                id: details?.id ?? "here-\(offset)",
                category: Self.category(for: details?.type),
                description: details?.description?.value,
                location: location,
                startTime: ISO8601.parse(details?.startTime),
                endTime: ISO8601.parse(details?.endTime),
                delaySeconds: nil,
                severity: Self.severity(for: details?.criticality)
            )
        }
    }

    static func category(for type: String?) -> IncidentCategory {
        switch type?.lowercased() {
        case "accident": return .accident
        case "congestion": return .congestion
        case "construction", "roadworks": return .roadworks
        case "roadclosure", "laneclosure", "closure": return .closure
        case "weather", "precipitation", "visibility": return .weather
        case "hazard", "obstruction", "disabledvehicle": return .hazard
        case "masstransit", "planned", "event": return .event
        default: return .unknown
        }
    }

    /// HERE entrega criticality como texto. Se normaliza a la escala 0-4 común.
    static func severity(for criticality: String?) -> Int? {
        switch criticality?.lowercased() {
        case "low": return 1
        case "minor": return 2
        case "major": return 3
        case "critical": return 4
        default: return nil
        }
    }
}
