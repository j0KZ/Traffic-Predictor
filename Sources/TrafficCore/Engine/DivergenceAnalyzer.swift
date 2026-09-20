import Foundation

public enum Verdict: String, Sendable, Equatable {
    case consensus       // spreadRatio < 0.08
    case minorSpread     // 0.08 - 0.20
    case majorSpread     // > 0.20
    case insufficient    // menos de 2 fuentes vivas
}

public struct Divergence: Sendable, Equatable {
    public let median: Int
    public let spreadSeconds: Int
    public let spreadRatio: Double
    /// El que se aleja más de un 15% de la mediana.
    public let outlier: ProviderID?
    public let verdict: Verdict
    /// Proveedores excluidos por rutear por otro corredor (distancia anómala).
    public let divergentRoutes: [ProviderID]
}

public enum DivergenceAnalyzer {
    /// Una distancia que se aleja más de este factor de la mediana significa
    /// otro corredor (costa en vez de Ruta 5), no otro cálculo de tráfico.
    public static let distanceDivergenceRatio = 0.15
    public static let outlierRatio = 0.15

    public static func analyze(_ samples: [ProviderID: ETASample]) -> Divergence {
        let all = Array(samples.values)

        // Primero se apartan los que rutean por otro lado: promediar su ETA
        // contra las demás mezclaría dos rutas distintas.
        let divergent = divergentRouteProviders(all)
        let usable = all.filter { !divergent.contains($0.provider) }

        guard usable.count >= 2 else {
            let fallbackMedian = usable.first?.durationSeconds ?? 0
            return Divergence(
                median: fallbackMedian,
                spreadSeconds: 0,
                spreadRatio: 0,
                outlier: nil,
                verdict: .insufficient,
                divergentRoutes: divergent.sorted { $0.rawValue < $1.rawValue }
            )
        }

        let durations = usable.map(\.durationSeconds).sorted()
        let median = medianOf(durations)
        let spread = durations.last! - durations.first!
        let ratio = median > 0 ? Double(spread) / Double(median) : 0

        let verdict: Verdict
        switch ratio {
        case ..<0.08: verdict = .consensus
        case ..<0.20: verdict = .minorSpread
        default: verdict = .majorSpread
        }

        // El outlier solo se nombra cuando el spread es real; con consenso,
        // señalar a alguien sería ruido.
        var outlier: ProviderID?
        if verdict == .majorSpread, median > 0 {
            outlier = usable
                .map { ($0.provider, abs(Double($0.durationSeconds - median)) / Double(median)) }
                .filter { $0.1 > outlierRatio }
                .max { $0.1 < $1.1 }?.0
        }

        return Divergence(
            median: median,
            spreadSeconds: spread,
            spreadRatio: ratio,
            outlier: outlier,
            verdict: verdict,
            divergentRoutes: divergent.sorted { $0.rawValue < $1.rawValue }
        )
    }

    /// Con menos de 3 fuentes no hay mayoría que defina cuál es "el corredor
    /// correcto", así que no se excluye a nadie.
    static func divergentRouteProviders(_ samples: [ETASample]) -> [ProviderID] {
        guard samples.count >= 3 else { return [] }
        let distances = samples.map(\.distanceMeters).sorted()
        let medianDistance = medianOf(distances)
        guard medianDistance > 0 else { return [] }

        return samples
            .filter { abs(Double($0.distanceMeters - medianDistance)) / Double(medianDistance) > distanceDivergenceRatio }
            .map(\.provider)
    }

    /// Mediana baja para pares: con dos fuentes preferimos la conservadora.
    static func medianOf(_ sorted: [Int]) -> Int {
        guard !sorted.isEmpty else { return 0 }
        return sorted[(sorted.count - 1) / 2]
    }
}
