import Foundation

public enum IncidentCategory: String, Codable, Sendable {
    case accident, congestion, roadworks, closure, weather, hazard, event, unknown

    /// Solo los eventos programados traen un fin en el que se pueda confiar.
    public var isScheduled: Bool {
        self == .roadworks || self == .closure || self == .event
    }
}

public struct TrafficIncident: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let category: IncidentCategory
    /// El "por qué". Google no lo entrega; TomTom y HERE sí.
    public let description: String?
    public let location: Coordinate?
    public let startTime: Date?
    public let endTime: Date?
    public let delaySeconds: Int?
    /// 0-4 normalizado.
    public let severity: Int?
    /// Posición sobre la ruta: 0.0 = origen, 1.0 = destino. nil si no se filtró aún.
    public var routeRatio: Double?

    public init(
        id: String,
        category: IncidentCategory,
        description: String? = nil,
        location: Coordinate? = nil,
        startTime: Date? = nil,
        endTime: Date? = nil,
        delaySeconds: Int? = nil,
        severity: Int? = nil,
        routeRatio: Double? = nil
    ) {
        self.id = id
        self.category = category
        self.description = description
        self.location = location
        self.startTime = startTime
        self.endTime = endTime
        self.delaySeconds = delaySeconds
        self.severity = severity
        self.routeRatio = routeRatio
    }

    public var hasReliableEnd: Bool {
        endTime != nil && category.isScheduled
    }
}
