import Foundation

public enum Recovery: Sendable, Equatable {
    case scheduled(endsAt: Date, source: ProviderID)
    case trending(estimatedClearAt: Date, rSquared: Double)
    case unclear(reason: String)
    case worsening(slopeSecondsPerMinute: Double)
    case insufficient(samplesNeeded: Int)
}

/// Acá no se inventa. Si no hay base para estimar, se dice por qué.
public enum RecoveryEstimator {
    public static let minimumSamples = 4
    public static let minimumRSquared = 0.5

    public struct DelayPoint: Sendable, Equatable {
        public let at: Date
        public let delaySeconds: Int

        public init(at: Date, delaySeconds: Int) {
            self.at = at
            self.delaySeconds = delaySeconds
        }
    }

    /// Orden de preferencia: dato del proveedor > tendencia medida > nada.
    public static func estimate(
        incidents: [TrafficIncident],
        incidentSources: [String: ProviderID] = [:],
        series: [DelayPoint],
        now: Date = .now
    ) -> Recovery {
        // 1. Evento programado con fin confiable: es un dato, no una estimación.
        let scheduled = incidents
            .filter { $0.hasReliableEnd }
            .compactMap { incident -> (Date, ProviderID)? in
                guard let end = incident.endTime, end > now else { return nil }
                return (end, incidentSources[incident.id] ?? .tomtom)
            }
            .max { $0.0 < $1.0 }

        if let (endsAt, source) = scheduled {
            return .scheduled(endsAt: endsAt, source: source)
        }

        // 2. Tendencia medida sobre la serie.
        guard series.count >= minimumSamples else {
            return .insufficient(samplesNeeded: minimumSamples - series.count)
        }

        let ordered = series.sorted { $0.at < $1.at }
        guard let origin = ordered.first?.at else {
            return .insufficient(samplesNeeded: minimumSamples)
        }

        // x en minutos desde la primera muestra, y en segundos de delay.
        let xs = ordered.map { $0.at.timeIntervalSince(origin) / 60 }
        let ys = ordered.map { Double($0.delaySeconds) }

        guard let fit = linearFit(xs: xs, ys: ys) else {
            return .unclear(reason: "todas las muestras caen en el mismo instante")
        }

        if fit.slope >= 0 {
            return .worsening(slopeSecondsPerMinute: fit.slope)
        }
        guard fit.rSquared >= minimumRSquared else {
            return .unclear(reason: String(format: "tendencia poco clara (R²=%.2f)", fit.rSquared))
        }

        // Minutos desde la primera muestra hasta que el delay cruza cero.
        let currentDelay = ys.last!
        let minutesToClear = -currentDelay / fit.slope
        guard minutesToClear.isFinite, minutesToClear >= 0 else {
            return .unclear(reason: "la proyección no cruza cero")
        }

        let lastAt = ordered.last!.at
        return .trending(
            estimatedClearAt: lastAt.addingTimeInterval(minutesToClear * 60),
            rSquared: fit.rSquared
        )
    }

    struct Fit: Equatable {
        let slope: Double
        let intercept: Double
        let rSquared: Double
    }

    /// nil cuando no hay varianza en x: una recta vertical no tiene pendiente.
    static func linearFit(xs: [Double], ys: [Double]) -> Fit? {
        guard xs.count == ys.count, xs.count >= 2 else { return nil }
        let n = Double(xs.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n

        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for (x, y) in zip(xs, ys) {
            sxx += (x - meanX) * (x - meanX)
            sxy += (x - meanX) * (y - meanY)
            syy += (y - meanY) * (y - meanY)
        }
        guard sxx > 0 else { return nil }

        let slope = sxy / sxx
        let intercept = meanY - slope * meanX
        // Serie perfectamente plana: la recta la explica entera.
        let rSquared = syy > 0 ? (sxy * sxy) / (sxx * syy) : 1.0
        return Fit(slope: slope, intercept: intercept, rSquared: rSquared)
    }
}
