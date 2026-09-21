import Foundation
import TrafficCore

/// Forma de route.json. Se mantiene separada de RouteQuery: el archivo es
/// configuración del operador, no el modelo del core.
struct RouteFile: Decodable {
    struct Point: Decodable {
        let lat: Double
        let lon: Double
        let note: String?
    }

    let id: String
    let label: String?
    let origin: Point
    let destination: Point
    let waypoints: [Point]?
    let freeFlowBaselineSeconds: Int?
    let expectedDistanceMeters: Int?
    let notes: String?

    func query() -> RouteQuery {
        RouteQuery(
            id: id,
            origin: Coordinate(lat: origin.lat, lon: origin.lon),
            destination: Coordinate(lat: destination.lat, lon: destination.lon),
            waypoints: (waypoints ?? []).map { Coordinate(lat: $0.lat, lon: $0.lon) },
            freeFlowBaselineSeconds: freeFlowBaselineSeconds,
            expectedDistanceMeters: expectedDistanceMeters
        )
    }

    static func load(_ path: String) throws -> RouteFile {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(RouteFile.self, from: data)
    }
}
