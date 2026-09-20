import Foundation

/// El bbox trae incidentes de toda la región. Sin filtrar verías choques en
/// Valparaíso que no te afectan.
public enum RouteIncidentFilter {
    public static let defaultToleranceMeters = 300.0
    public static let defaultSpacingMeters = 500.0

    /// Submuestrea el polyline a ~1 punto cada `spacing` metros.
    /// Siempre conserva el primer y el último punto: son origen y destino.
    static func subsample(_ points: [Coordinate], spacingMeters: Double = defaultSpacingMeters) -> [Coordinate] {
        guard points.count > 2 else { return points }
        var result = [points[0]]
        var accumulated = 0.0
        for i in 1..<points.count {
            accumulated += Geo.haversineMeters(points[i - 1], points[i])
            if accumulated >= spacingMeters {
                result.append(points[i])
                accumulated = 0
            }
        }
        if result.last != points.last, let last = points.last { result.append(last) }
        return result
    }

    /// Conserva los incidentes a menos de `tolerance` del trazado y les asigna
    /// su posición sobre la ruta (0.0 origen, 1.0 destino).
    /// Un incidente sin coordenadas se descarta: no podemos afirmar que te afecte.
    public static func filter(
        _ incidents: [TrafficIncident],
        onRoute polyline: String?,
        toleranceMeters: Double = defaultToleranceMeters,
        spacingMeters: Double = defaultSpacingMeters
    ) -> [TrafficIncident] {
        guard let polyline else { return [] }
        let samples = subsample(Polyline.decode(polyline), spacingMeters: spacingMeters)
        guard samples.count > 1 else { return [] }

        var kept: [TrafficIncident] = []
        for incident in incidents {
            guard let location = incident.location else { continue }

            var bestDistance = Double.infinity
            var bestIndex = 0
            for (index, point) in samples.enumerated() {
                let distance = Geo.haversineMeters(location, point)
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }
            guard bestDistance <= toleranceMeters else { continue }

            var annotated = incident
            annotated.routeRatio = Double(bestIndex) / Double(samples.count - 1)
            kept.append(annotated)
        }
        return kept.sorted { ($0.routeRatio ?? 0) < ($1.routeRatio ?? 0) }
    }
}
