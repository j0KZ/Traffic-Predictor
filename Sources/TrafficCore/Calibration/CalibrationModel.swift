import Foundation

/// Un par muestra/referencia con el contexto que decide cuánto corregir.
public struct TaggedPair: Sendable, Equatable {
    public let provider: ProviderID
    public let route: String
    public let band: BandKey
    public let at: Date
    /// log(referencia / muestra): el factor que llevaría la fuente a Waze.
    /// En logaritmo, pasarse un 20% y quedarse corto un 20% pesan igual.
    public let logCorrection: Double
    /// Los tiempos originales, mientras existan. Se pierden al podar: los
    /// términos de Mapbox y TomTom no permiten guardar sus respuestas más
    /// allá de la ventana corta, pero sí este cociente, que es nuestro.
    public let pair: Calibrator.Pair?

    public init(provider: ProviderID, route: String, band: BandKey, pair: Calibrator.Pair) {
        self.provider = provider
        self.route = route
        self.band = band
        self.at = pair.at
        self.pair = pair
        self.logCorrection = log(Double(max(pair.reference, 1)) / Double(max(pair.sample, 1)))
    }

    /// Par ya reducido a su coeficiente, sin los tiempos originales.
    public init(provider: ProviderID, route: String, band: BandKey, at: Date, logCorrection: Double) {
        self.provider = provider
        self.route = route
        self.band = band
        self.at = at
        self.pair = nil
        self.logCorrection = logCorrection
    }
}

/// Corrige cada fuente hacia la referencia y las mezcla según qué tan bien
/// vienen acertando. El sesgo es propio de cada ruta: el de otras ciudades
/// no se traslada (probado dejando cada ciudad fuera), así que el factor de
/// una franja se apoya en el de la misma ruta en otras franjas, y ese en
/// "no corregir".
public struct CalibrationModel: Sendable {
    /// Pares que "valen" el apoyo del nivel superior. Bajo: con 1 lectura de
    /// Waze el error de Mapbox corregido baja de 7.7% a 2.7% y con 2 a 1.6%
    /// (63 pares, 17 rutas), así que la evidencia propia manda pronto.
    public static let shrinkage = 0.25

    /// Error supuesto de cada fuente sin historia propia. Mapbox crudo acierta
    /// 7% en ciudades nunca vistas. TomTom falla peor y además en la punta
    /// se dispara (x2 en Tel Aviv): sin historia pesa poco.
    public static let priorError: [ProviderID: Double] = [.mapbox: 0.07, .tomtom: 0.35]

    private let pairs: [TaggedPair]

    public init(pairs: [TaggedPair]) {
        self.pairs = pairs
    }

    /// Factor multiplicativo para una fuente en una ruta y franja.
    public func factor(provider: ProviderID, route: String, band: BandKey) -> Double {
        let own = pairs.filter { $0.provider == provider }

        // Nivel ruta: todas las franjas de esa ruta, encogido hacia 0 (sin corregir).
        let onRoute = own.filter { $0.route == route }
        let routeLog = Self.shrunkMean(onRoute.map(\.logCorrection), toward: 0)

        // Nivel ruta+franja: encogido hacia el de la ruta.
        let local = onRoute.filter { $0.band == band }
        let localLog = Self.shrunkMean(local.map(\.logCorrection), toward: routeLog)

        return exp(localLog)
    }

    /// Error relativo típico de la fuente ya corregida, en esa ruta y franja.
    /// nil sin pares propios: no hay con qué medirlo.
    public func residualError(provider: ProviderID, route: String, band: BandKey) -> Double? {
        let f = factor(provider: provider, route: route, band: band)
        let onRoute = pairs.filter { $0.provider == provider && $0.route == route }
        let scoped = onRoute.contains { $0.band == band } ? onRoute.filter { $0.band == band } : onRoute
        guard !scoped.isEmpty else { return nil }
        // |muestra·f − referencia| / referencia = |f / e^logCorrection − 1|,
        // así que el coeficiente basta: no hacen falta los tiempos originales.
        let errors = scoped.map { abs(f / exp($0.logCorrection) - 1) }
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
            // Sin historia propia, el error típico de la fuente en rutas nuevas.
            let error = residualError(provider: provider, route: route, band: band)
                ?? Self.priorError[provider] ?? 0.15
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
        evaluate(pairs) { "\($0.route)|\($0.at.timeIntervalSince1970)" }
    }

    /// Deja fuera una ruta completa: el modelo solo sabe de otras ciudades
    /// en la misma franja. Mide si la calibración sirve para una ruta nueva.
    public static func leaveOneRouteOut(_ pairs: [TaggedPair]) -> Result? {
        evaluate(pairs) { $0.route }
    }

    /// Predice cada lectura usando SOLO las anteriores en el tiempo. Es la
    /// única forma de saber si el factor sirve para la próxima medición:
    /// dejar una fuera se apoya en lecturas del futuro, que en la vida real
    /// no existen. Mide 7.4% contra 5.6% del optimista (74 lecturas).
    public static func forwardInTime(_ pairs: [TaggedPair]) -> Result? {
        let withTimes = pairs.filter { $0.pair != nil }
        let grouped: [String: [TaggedPair]] = Dictionary(grouping: withTimes) {
            "\($0.route)|\($0.at.timeIntervalSince1970)"
        }
        let events: [[TaggedPair]] = grouped.values.sorted {
            let a: Date = $0.first?.at ?? .distantPast
            let b: Date = $1.first?.at ?? .distantPast
            return a < b
        }
        guard events.count >= 2 else { return nil }

        var rawErrors: [ProviderID: [Double]] = [:]
        var medianErrors: [Double] = []
        var calibratedErrors: [Double] = []

        for (index, event) in events.enumerated() {
            guard let first = event.first, let firstPair = first.pair else { continue }
            let reference = Double(firstPair.reference)
            // Entrena con todo lo ocurrido antes de esta lectura.
            let training = events[..<index].flatMap { $0 }
            // Sin historia propia de la ruta no hay nada que evaluar: el
            // factor sería 1 y mediríamos la fuente cruda, no la calibración.
            guard training.contains(where: { $0.route == first.route }) else { continue }
            let model = CalibrationModel(pairs: training)

            var samples: [ProviderID: Int] = [:]
            for p in event { if let q = p.pair { samples[p.provider] = q.sample } }
            guard !samples.isEmpty else { continue }

            for (provider, value) in samples {
                rawErrors[provider, default: []].append(abs(Double(value) - reference) / reference)
            }
            let sorted = samples.values.sorted()
            medianErrors.append(abs(Double(sorted[sorted.count / 2]) - reference) / reference)

            if let predicted = model.predict(samples: samples, route: first.route, band: first.band) {
                calibratedErrors.append(abs(Double(predicted) - reference) / reference)
            }
        }

        func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
        guard !calibratedErrors.isEmpty else { return nil }
        return Result(
            readings: calibratedErrors.count,
            rawError: rawErrors.mapValues(mean),
            rawMedianError: mean(medianErrors),
            calibratedError: mean(calibratedErrors)
        )
    }

    private static func evaluate(_ pairs: [TaggedPair], holdout: (TaggedPair) -> String) -> Result? {
        // Un "evento" es una lectura de referencia: misma ruta y mismo instante.
        let events = Dictionary(grouping: pairs.filter { $0.pair != nil }) {
            "\($0.route)|\($0.at.timeIntervalSince1970)"
        }
        guard events.count >= 2 else { return nil }

        var rawErrors: [ProviderID: [Double]] = [:]
        var medianErrors: [Double] = []
        var calibratedErrors: [Double] = []

        for (_, event) in events {
            guard let first = event.first, let firstPair = first.pair else { continue }
            let reference = Double(firstPair.reference)
            let heldOut = holdout(first)
            let training = pairs.filter { holdout($0) != heldOut }
            let model = CalibrationModel(pairs: training)

            var samples: [ProviderID: Int] = [:]
            for p in event { if let q = p.pair { samples[p.provider] = q.sample } }
            guard !samples.isEmpty else { continue }

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
