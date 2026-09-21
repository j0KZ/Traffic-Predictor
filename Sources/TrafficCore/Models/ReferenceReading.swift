import Foundation

/// Lectura de una fuente externa que no se consulta por API (Waze, Apple
/// Maps, un viaje real cronometrado). Es la vara contra la que se calibra.
public struct ReferenceReading: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let routeID: String
    /// "waze", "apple", "viaje-real"…: texto libre a propósito, no ProviderID.
    public let source: String
    public let capturedAt: Date
    public let durationSeconds: Int
    public let distanceMeters: Int?
    public let note: String?

    public init(
        id: UUID = UUID(),
        routeID: String,
        source: String,
        capturedAt: Date = .now,
        durationSeconds: Int,
        distanceMeters: Int? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.routeID = routeID
        self.source = source
        self.capturedAt = capturedAt
        self.durationSeconds = durationSeconds
        self.distanceMeters = distanceMeters
        self.note = note
    }
}
