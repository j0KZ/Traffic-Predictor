import Foundation

public struct RouteQuery: Sendable, Equatable {
    public let id: String
    public let origin: Coordinate
    public let destination: Coordinate
    /// Fuerza el corredor. Vacío = ruteo libre.
    public let waypoints: [Coordinate]
    /// nil = ahora.
    public let departAt: Date?
    /// 6300 para Ruta 5 Norte. Dato del operador, no del proveedor.
    public let freeFlowBaselineSeconds: Int?
    /// Distancia conocida del corredor. Con esto se detecta al que rutea por
    /// la costa aunque haya solo dos fuentes: no hace falta mayoría si se
    /// sabe cuánto mide el camino correcto.
    public let expectedDistanceMeters: Int?

    public init(
        id: String,
        origin: Coordinate,
        destination: Coordinate,
        waypoints: [Coordinate] = [],
        departAt: Date? = nil,
        freeFlowBaselineSeconds: Int? = nil,
        expectedDistanceMeters: Int? = nil
    ) {
        self.id = id
        self.origin = origin
        self.destination = destination
        self.waypoints = waypoints
        self.departAt = departAt
        self.freeFlowBaselineSeconds = freeFlowBaselineSeconds
        self.expectedDistanceMeters = expectedDistanceMeters
    }
}
