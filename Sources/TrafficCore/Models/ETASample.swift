import Foundation

public struct ETASample: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let provider: ProviderID
    public let capturedAt: Date
    /// Con tráfico.
    public let durationSeconds: Int
    /// Sin tráfico, si el proveedor lo entrega.
    public let freeFlowSeconds: Int?
    public let distanceMeters: Int
    /// Encoded, para dibujar. Ya normalizado a Google encoded polyline.
    public let polyline: String?
    public var incidents: [TrafficIncident]

    public init(
        id: UUID = UUID(),
        provider: ProviderID,
        capturedAt: Date = .now,
        durationSeconds: Int,
        freeFlowSeconds: Int? = nil,
        distanceMeters: Int,
        polyline: String? = nil,
        incidents: [TrafficIncident] = []
    ) {
        self.id = id
        self.provider = provider
        self.capturedAt = capturedAt
        self.durationSeconds = durationSeconds
        self.freeFlowSeconds = freeFlowSeconds
        self.distanceMeters = distanceMeters
        self.polyline = polyline
        self.incidents = incidents
    }

    /// Sobrecosto por tráfico segun el free-flow del proveedor. nil si no lo dio.
    public var delaySeconds: Int? {
        guard let ff = freeFlowSeconds else { return nil }
        return max(0, durationSeconds - ff)
    }

    /// Sobrecosto contra el baseline del operador, que manda sobre el del proveedor.
    public func delaySeconds(baseline: Int?) -> Int? {
        guard let baseline else { return delaySeconds }
        return max(0, durationSeconds - baseline)
    }
}
