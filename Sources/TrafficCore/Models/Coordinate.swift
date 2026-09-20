import Foundation

public struct Coordinate: Codable, Sendable, Equatable, Hashable {
    public let lat: Double
    public let lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}

/// Bounding box en grados, con margen opcional.
public struct BoundingBox: Sendable, Equatable {
    public let west: Double
    public let south: Double
    public let east: Double
    public let north: Double

    public init(west: Double, south: Double, east: Double, north: Double) {
        self.west = west
        self.south = south
        self.east = east
        self.north = north
    }

    /// nil si no hay puntos: un bbox de cero puntos no significa nada.
    public init?(points: [Coordinate], marginDegrees: Double = 0.05) {
        guard let first = points.first else { return nil }
        var minLat = first.lat, maxLat = first.lat
        var minLon = first.lon, maxLon = first.lon
        for p in points.dropFirst() {
            minLat = min(minLat, p.lat); maxLat = max(maxLat, p.lat)
            minLon = min(minLon, p.lon); maxLon = max(maxLon, p.lon)
        }
        self.init(
            west:  minLon - marginDegrees,
            south: minLat - marginDegrees,
            east:  maxLon + marginDegrees,
            north: maxLat + marginDegrees
        )
    }
}
