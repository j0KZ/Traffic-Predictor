import Foundation

/// TomTom: dos llamadas. Routing da la ETA; incidentDetails da el "por qué".
/// Si la segunda falla, la muestra se entrega igual sin incidentes: perder la
/// causa no debe costarnos la ETA.
public struct TomTomProvider: TrafficProvider {
    public let id: ProviderID = .tomtom

    private let client: HTTPClient
    private let credentials: CredentialStore

    public init(client: HTTPClient = URLSessionHTTPClient(), credentials: CredentialStore = CredentialStore()) {
        self.client = client
        self.credentials = credentials
    }

    public func fetch(_ query: RouteQuery) async throws -> ETASample {
        let key = try credentials.apiKey(for: id)
        let capturedAt = Date()

        let routeData = try await client.fetchJSONBody(try routeRequest(query, key: key), provider: id)
        var sample = try parseRoute(routeData, capturedAt: capturedAt)

        let points = sample.polyline.map { Polyline.decode($0) } ?? []
        if let bbox = BoundingBox(points: points) {
            // La causa es un extra: su falla no invalida la ETA que ya tenemos.
            if let incidentData = try? await client.fetchJSONBody(incidentRequest(bbox, key: key), provider: id),
               let incidents = try? parseIncidents(incidentData) {
                sample.incidents = incidents
            }
        }
        return sample
    }

    // MARK: - Requests

    func routeRequest(_ query: RouteQuery, key: String) throws -> URLRequest {
        let locations = ([query.origin] + query.waypoints + [query.destination])
            .map { "\($0.lat),\($0.lon)" }
            .joined(separator: ":")

        var components = URLComponents(
            string: "https://api.tomtom.com/routing/1/calculateRoute/\(locations)/json"
        )
        components?.queryItems = [
            .init(name: "key", value: key),
            .init(name: "traffic", value: "true"),
            .init(name: "travelMode", value: "car"),
            .init(name: "routeType", value: "fastest"),
            .init(name: "computeTravelTimeFor", value: "all"),
            .init(name: "sectionType", value: "traffic"),
        ]
        guard let url = components?.url else {
            throw ProviderError.transport("tomtom: URL de ruta inválida")
        }
        return URLRequest(url: url)
    }

    func incidentRequest(_ bbox: BoundingBox, key: String) throws -> URLRequest {
        let fields = "{incidents{type,geometry{type,coordinates},properties{iconCategory,"
            + "magnitudeOfDelay,events{description,code},startTime,endTime,delay}}}"

        var components = URLComponents(string: "https://api.tomtom.com/traffic/services/5/incidentDetails")
        components?.queryItems = [
            .init(name: "key", value: key),
            .init(name: "bbox", value: "\(bbox.west),\(bbox.south),\(bbox.east),\(bbox.north)"),
            .init(name: "fields", value: fields),
            .init(name: "language", value: "es-ES"),
            .init(name: "categoryFilter", value: "0,1,2,3,4,5,6,7,8,9,10,11,14"),
        ]
        guard let url = components?.url else {
            throw ProviderError.transport("tomtom: URL de incidentes inválida")
        }
        return URLRequest(url: url)
    }

    // MARK: - Parseo de ruta

    private struct RouteResponse: Decodable {
        struct Route: Decodable {
            struct Summary: Decodable {
                let travelTimeInSeconds: Int?
                let noTrafficTravelTimeInSeconds: Int?
                let trafficDelayInSeconds: Int?
                let lengthInMeters: Int?
            }
            struct Leg: Decodable {
                struct Point: Decodable { let latitude: Double; let longitude: Double }
                let points: [Point]?
            }
            let summary: Summary?
            let legs: [Leg]?
        }
        let routes: [Route]?
    }

    func parseRoute(_ data: Data, capturedAt: Date) throws -> ETASample {
        let decoded: RouteResponse
        do {
            decoded = try JSONDecoder().decode(RouteResponse.self, from: data)
        } catch {
            throw ProviderError.decoding("tomtom: \(error)")
        }

        guard let route = decoded.routes?.first else { throw ProviderError.noRoute }
        guard let summary = route.summary,
              let duration = summary.travelTimeInSeconds,
              let distance = summary.lengthInMeters else {
            throw ProviderError.decoding("tomtom: summary incompleto")
        }

        // TomTom entrega los puntos crudos; los reencodeamos al formato común.
        let points = (route.legs ?? []).flatMap { leg in
            (leg.points ?? []).map { Coordinate(lat: $0.latitude, lon: $0.longitude) }
        }

        return ETASample(
            provider: id,
            capturedAt: capturedAt,
            durationSeconds: duration,
            freeFlowSeconds: summary.noTrafficTravelTimeInSeconds,
            distanceMeters: distance,
            polyline: points.isEmpty ? nil : Polyline.encode(points),
            incidents: []
        )
    }

    // MARK: - Parseo de incidentes

    private struct IncidentResponse: Decodable {
        struct Incident: Decodable {
            struct Geometry: Decodable {
                let type: String?
                // Point da [lon,lat]; LineString da [[lon,lat],…]. Decodificamos
                // flexible y nos quedamos con el primer par.
                let coordinates: JSONValue?
            }
            struct Properties: Decodable {
                struct Event: Decodable {
                    let description: String?
                    let code: Int?
                }
                let iconCategory: Int?
                let magnitudeOfDelay: Int?
                let events: [Event]?
                let startTime: String?
                let endTime: String?
                let delay: Int?
            }
            let id: String?
            let geometry: Geometry?
            let properties: Properties?
        }
        let incidents: [Incident]?
    }

    func parseIncidents(_ data: Data) throws -> [TrafficIncident] {
        let decoded: IncidentResponse
        do {
            decoded = try JSONDecoder().decode(IncidentResponse.self, from: data)
        } catch {
            throw ProviderError.decoding("tomtom incidentes: \(error)")
        }

        return (decoded.incidents ?? []).enumerated().map { offset, raw in
            let props = raw.properties
            let category = Self.category(for: props?.iconCategory)
            return TrafficIncident(
                // TomTom no siempre manda id; sin uno estable el incidente
                // seguiría siendo útil, así que sintetizamos uno por posición.
                id: raw.id ?? "tomtom-\(offset)",
                category: category,
                description: props?.events?.compactMap(\.description).first,
                location: raw.geometry?.coordinates?.firstCoordinate,
                startTime: ISO8601.parse(props?.startTime),
                endTime: ISO8601.parse(props?.endTime),
                delaySeconds: props?.delay,
                severity: props?.magnitudeOfDelay
            )
        }
    }

    /// Tabla iconCategory de TomTom. Lo no mapeado cae en .unknown a propósito:
    /// inventar una categoría es peor que admitir que no la sabemos.
    static func category(for iconCategory: Int?) -> IncidentCategory {
        switch iconCategory {
        case 1: return .accident
        case 2, 4, 5, 10, 11: return .weather
        case 3: return .hazard
        case 6: return .congestion
        case 7, 8: return .closure
        case 9: return .roadworks
        case 14: return .hazard
        default: return .unknown
        }
    }
}
