import Foundation

/// Forma de route.json. Se mantiene separada de RouteQuery: el archivo es
/// configuración del operador, no el modelo del core.
public struct RouteFile: Decodable, Sendable {
    public struct Point: Decodable, Sendable {
        public let lat: Double
        public let lon: Double
        public let note: String?
    }

    public let id: String
    public let label: String?
    public let origin: Point
    public let destination: Point
    public let waypoints: [Point]?
    public let freeFlowBaselineSeconds: Int?
    public let expectedDistanceMeters: Int?
    public let notes: String?
    /// Zona horaria IANA de la ruta, para clasificar lecturas por franja.
    public let timeZone: String?

    public var zone: TimeZone { timeZone.flatMap(TimeZone.init(identifier:)) ?? .current }

    public func query() -> RouteQuery {
        RouteQuery(
            id: id,
            origin: Coordinate(lat: origin.lat, lon: origin.lon),
            destination: Coordinate(lat: destination.lat, lon: destination.lon),
            waypoints: (waypoints ?? []).map { Coordinate(lat: $0.lat, lon: $0.lon) },
            freeFlowBaselineSeconds: freeFlowBaselineSeconds,
            expectedDistanceMeters: expectedDistanceMeters
        )
    }

    public static func load(_ path: String) throws -> RouteFile {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(RouteFile.self, from: data)
    }
}
