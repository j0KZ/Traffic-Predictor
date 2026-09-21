import Foundation

/// Cuánto se aleja cada fuente de una referencia, medido sobre pares
/// tomados al mismo tiempo. Mide; no corrige hasta tener base.
public enum Calibrator {
    /// Muestra y referencia separadas por más de esto no se comparan: el
    /// tráfico cambia en minutos.
    public static let maxPairingGap: TimeInterval = 300
    /// Por debajo de esta cantidad de pares el factor se informa pero no se
    /// ofrece como corrección.
    public static let minimumPairsForCorrection = 8
    /// La referencia tiene que moverse al menos esto para que exista una
    /// curva que seguir. Con 16 s de variación de madrugada, una correlación
    /// de 1.00 es ruido de redondeo, no seguimiento.
    public static let minimumReferenceRange = 180

    public struct Pair: Sendable, Equatable {
        public let sample: Int
        public let reference: Int
        public let at: Date
    }

    public struct Bias: Sendable, Equatable {
        public let provider: ProviderID
        public let referenceSource: String
        public let pairs: [Pair]
        /// Mediana de sample/reference. <1 = la fuente es optimista.
        public let ratio: Double
        /// Mediana de sample - reference, en segundos.
        public let offsetSeconds: Int
        /// Correlación de las variaciones: ¿la fuente sigue la *curva* de la
        /// referencia? nil con menos de 3 pares o sin variación.
        public let trendCorrelation: Double?

        public var isUsableForCorrection: Bool {
            pairs.count >= Calibrator.minimumPairsForCorrection
        }

        /// ETA corregida por el factor. nil si no hay base suficiente:
        /// una corrección con 2 pares es ruido con decimales.
        public func corrected(_ durationSeconds: Int) -> Int? {
            guard isUsableForCorrection, ratio > 0 else { return nil }
            return Int((Double(durationSeconds) / ratio).rounded())
        }
    }

    public static func bias(
        samples: [ETASample],
        references: [ReferenceReading],
        maxGap: TimeInterval = maxPairingGap
    ) -> [Bias] {
        let bySource = Dictionary(grouping: references, by: \.source)
        var result: [Bias] = []

        for (source, refs) in bySource.sorted(by: { $0.key < $1.key }) {
            for provider in ProviderID.allCases {
                let own = samples.filter { $0.provider == provider }
                guard !own.isEmpty else { continue }

                // Cada referencia se empareja con la muestra más cercana en
                // el tiempo, y solo si está dentro del margen.
                let pairs: [Pair] = refs.compactMap { ref in
                    guard let nearest = own.min(by: {
                        abs($0.capturedAt.timeIntervalSince(ref.capturedAt))
                            < abs($1.capturedAt.timeIntervalSince(ref.capturedAt))
                    }), abs(nearest.capturedAt.timeIntervalSince(ref.capturedAt)) <= maxGap else {
                        return nil
                    }
                    return Pair(sample: nearest.durationSeconds, reference: ref.durationSeconds, at: ref.capturedAt)
                }.sorted { $0.at < $1.at }

                guard !pairs.isEmpty else { continue }

                let ratios = pairs.map { Double($0.sample) / Double(max($0.reference, 1)) }.sorted()
                let offsets = pairs.map { $0.sample - $0.reference }.sorted()

                result.append(Bias(
                    provider: provider,
                    referenceSource: source,
                    pairs: pairs,
                    ratio: ratios[(ratios.count - 1) / 2],
                    offsetSeconds: offsets[(offsets.count - 1) / 2],
                    trendCorrelation: trend(pairs)
                ))
            }
        }
        return result
    }

    static func trend(_ pairs: [Pair]) -> Double? {
        let refs = pairs.map(\.reference)
        guard let lo = refs.min(), let hi = refs.max(), hi - lo >= minimumReferenceRange else { return nil }
        return correlation(pairs.map { Double($0.sample) }, refs.map(Double.init))
    }

    /// Pearson. nil si alguna serie no varía: sin variación no hay curva
    /// que seguir, y un 0 o un 1 ahí sería inventado.
    static func correlation(_ xs: [Double], _ ys: [Double]) -> Double? {
        guard xs.count == ys.count, xs.count >= 3 else { return nil }
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n
        let my = ys.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (x, y) in zip(xs, ys) {
            sxy += (x - mx) * (y - my)
            sxx += (x - mx) * (x - mx)
            syy += (y - my) * (y - my)
        }
        guard sxx > 0, syy > 0 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }
}
