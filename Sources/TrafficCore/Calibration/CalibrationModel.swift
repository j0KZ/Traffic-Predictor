import Foundation

/// Un par muestra/referencia con el contexto que decide cuánto corregir.
public struct TaggedPair: Sendable, Equatable {
    public let provider: ProviderID
    public let route: String
    public let band: BandKey
    public let pair: Calibrator.Pair

    public init(provider: ProviderID, route: String, band: BandKey, pair: Calibrator.Pair) {
        self.provider = provider
        self.route = route
        self.band = band
        self.pair = pair
    }

    /// log(referencia / muestra): el factor que llevaría la fuente a Waze.
    /// En logaritmo, pasarse un 20% y quedarse corto un 20% pesan igual.
    var logCorrection: Double {
        log(Double(max(pair.reference, 1)) / Double(max(pair.sample, 1)))
    }
}

/// Corrige cada fuente hacia la referencia y las mezcla según qué tan bien
/// vienen acertando. Con poca evidencia corrige poco: el factor de una
/// ciudad se apoya en el de su franja, y el de la franja en "no corregir".
public struct CalibrationModel: Sendable {
    /// Pares que "valen" el apoyo del nivel superior. Con k pares propios,
    /// el factor local pesa la mitad.
    public static let shrinkage = 4.0

    private let pairs: [TaggedPair]

    public init(pairs: [TaggedPair]) {
        self.pairs = pairs
    }

    /// Factor multiplicativo para una fuente en una ruta y franja.
    public func factor(provider: ProviderID, route: String, band: BandKey) -> Double {
        let own = pairs.filter { $0.provider == provider }

        // Nivel franja: todas las rutas de esa franja, encogido hacia 0 (sin corregir).
        let inBand = own.filter { $0.band == band }
        let bandLog = Self.shrunkMean(inBand.map(\.logCorrection), toward: 0)

        // Nivel ruta+franja: encogido hacia el de la franja.
        let local = inBand.filter { $0.route == route }
        let localLog = Self.shrunkMean(local.map(\.logCorrection), toward: bandLog)

        return exp(localLog)
    }

    /// Error relativo típico de la fuente ya corregida, en esa ruta y franja.
    /// nil sin pares propios: no hay con qué medirlo.
    public func residualError(provider: ProviderID, route: String, band: BandKey) -> Double? {
        let f = factor(provider: provider, route: route, band: band)
        let local = pairs.filter { $0.provider == provider && $0.band == band }
        let scoped = local.contains { $0.route == route } ? local.filter { $0.route == route } : local
        guard !scoped.isEmpty else { return nil }
        let errors = scoped.map { abs(Double($0.pair.sample) * f - Double($0.pair.reference)) / Double(max($0.pair.reference, 1)) }
        return errors.reduce(0, +) / Double(errors.count)
    }

    /// ETA calibrada: cada fuente corregida, mezcladas con peso inverso a su
    /// error. nil sin muestras.
    public func predict(samples: [ProviderID: Int], route: String, band: BandKey) -> Int? {
        guard !samples.isEmpty else { return nil }
        var weighted = 0.0
        var totalWeight = 0.0
        for (provider, duration) in samples {
            let corrected = Double(duration) * factor(provider: provider, route: route, band: band)
            // Sin historia propia, peso neutro: no se premia ni castiga lo que no se midió.
            let error = residualError(provider: provider, route: route, band: band) ?? 0.15
            let weight = 1 / max(error, 0.02)
            weighted += corrected * weight
            totalWeight += weight
        }
        return Int((weighted / totalWeight).rounded())
    }

    static func shrunkMean(_ values: [Double], toward prior: Double) -> Double {
        let n = Double(values.count)
        guard n > 0 else { return prior }
        let mean = values.reduce(0, +) / n
        return (n * mean + shrinkage * prior) / (n + shrinkage)
    }
}

/// Validación dejando uno fuera: cada lectura de referencia se predice con
/// un modelo que no la vio. Es la única forma honesta de saber si calibrar
/// acerca a Waze o solo memoriza.
public enum CalibrationEvaluation {
    public struct Result: Sendable {
        public let readings: Int
        /// Error relativo medio por método.
        public let rawError: [ProviderID: Double]
        public let rawMedianError: Double
        public let calibratedError: Double
    }

    /// Deja fuera cada lectura. Optimista si las lecturas de una ruta están
    /// muy juntas en el tiempo: sus vecinas quedan en el entrenamiento.
    public static func leaveOneOut(_ pairs: [TaggedPair]) -> Result? {
        evaluate(pairs) { "\($0.route)|\($0.pair.at.timeIntervalSince1970)" }
    }

    /// Deja fuera una ruta completa: el modelo solo sabe de otras ciudades
    /// en la misma franja. Mide si la calibración sirve para una ruta nueva.
    public static func leaveOneRouteOut(_ pairs: [TaggedPair]) -> Result? {
        evaluate(pairs) { $0.route }
    }

    private static func evaluate(_ pairs: [TaggedPair], holdout: (TaggedPair) -> String) -> Result? {
        // Un "evento" es una lectura de referencia: misma ruta y mismo instante.
        let events = Dictionary(grouping: pairs) { "\($0.route)|\($0.pair.at.timeIntervalSince1970)" }
        guard events.count >= 2 else { return nil }

        var rawErrors: [ProviderID: [Double]] = [:]
        var medianErrors: [Double] = []
        var calibratedErrors: [Double] = []

        for (_, event) in events {
            guard let first = event.first else { continue }
            let reference = Double(first.pair.reference)
            let heldOut = holdout(first)
            let training = pairs.filter { holdout($0) != heldOut }
            let model = CalibrationModel(pairs: training)

            var samples: [ProviderID: Int] = [:]
            for p in event { samples[p.provider] = p.pair.sample }

            for (provider, value) in samples {
                rawErrors[provider, default: []].append(abs(Double(value) - reference) / reference)
            }
            let sorted = samples.values.sorted()
            let median = Double(sorted[sorted.count / 2])
            medianErrors.append(abs(median - reference) / reference)

            if let predicted = model.predict(samples: samples, route: first.route, band: first.band) {
                calibratedErrors.append(abs(Double(predicted) - reference) / reference)
            }
        }

        func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
        return Result(
            readings: events.count,
            rawError: rawErrors.mapValues(mean),
            rawMedianError: mean(medianErrors),
            calibratedError: mean(calibratedErrors)
        )
    }
}
