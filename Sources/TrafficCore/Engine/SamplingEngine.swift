import Foundation

public struct SampleRound: Sendable {
    public let capturedAt: Date
    public let samples: [ProviderID: ETASample]
    public let failures: [ProviderID: String]

    public init(capturedAt: Date, samples: [ProviderID: ETASample], failures: [ProviderID: String]) {
        self.capturedAt = capturedAt
        self.samples = samples
        self.failures = failures
    }
}

public struct SamplingCadence: Sendable {
    public var stableInterval: TimeInterval = 300    // ETA quieta
    public var activeInterval: TimeInterval = 120    // ETA moviéndose
    public var movementThreshold: TimeInterval = 180 // 3 min entre rondas
    public var adaptive: Bool = true
    public var providerTimeout: TimeInterval = 15

    public init() {}
}

public actor SamplingEngine {
    private let providers: [any TrafficProvider]
    private let store: SampleStore?
    private var cadence: SamplingCadence

    private var lastMedian: Int?
    /// Rondas que a cada proveedor le quedan por saltarse tras un 429 o 5xx.
    private var skipCounters: [ProviderID: Int] = [:]
    private var backoffRounds: [ProviderID: Int] = [:]

    public init(providers: [any TrafficProvider], store: SampleStore? = nil, cadence: SamplingCadence = SamplingCadence()) {
        self.providers = providers
        self.store = store
        self.cadence = cadence
    }

    public func runOnce(_ query: RouteQuery) async -> SampleRound {
        var samples: [ProviderID: ETASample] = [:]
        var failures: [ProviderID: String] = [:]

        // Un proveedor en backoff no se consulta, pero se registra por qué:
        // una ronda sin su dato no es lo mismo que una ronda donde respondió.
        let active = providers.filter { provider in
            if let remaining = skipCounters[provider.id], remaining > 0 {
                skipCounters[provider.id] = remaining - 1
                failures[provider.id] = "en backoff, \(remaining) ronda(s) restante(s)"
                return false
            }
            return true
        }

        let timeout = cadence.providerTimeout

        await withTaskGroup(of: (ProviderID, Result<ETASample, Error>).self) { group in
            for provider in active {
                group.addTask {
                    do {
                        let sample = try await Self.fetchWithTimeout(provider, query, seconds: timeout)
                        return (provider.id, .success(sample))
                    } catch {
                        return (provider.id, .failure(error))
                    }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let sample):
                    samples[id] = sample
                case .failure(let error):
                    failures[id] = (error as? ProviderError)?.description ?? String(describing: error)
                }
            }
        }

        // El filtrado de incidentes ocurre acá, no en el provider: es política
        // de la ruta, no del proveedor.
        for (id, sample) in samples {
            var annotated = sample
            annotated.incidents = RouteIncidentFilter.filter(sample.incidents, onRoute: sample.polyline)
            samples[id] = annotated
        }

        for provider in active {
            updateBackoff(provider.id, succeeded: samples[provider.id] != nil, failure: failures[provider.id])
        }

        let round = SampleRound(capturedAt: .now, samples: samples, failures: failures)
        try? await store?.persist(round, routeID: query.id)
        return round
    }

    /// Timeout duro por proveedor: una fuente colgada no puede retrasar la ronda.
    private static func fetchWithTimeout(
        _ provider: any TrafficProvider,
        _ query: RouteQuery,
        seconds: TimeInterval
    ) async throws -> ETASample {
        try await withThrowingTaskGroup(of: ETASample.self) { group in
            group.addTask { try await provider.fetch(query) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ProviderError.transport("timeout \(Int(seconds))s")
            }
            guard let first = try await group.next() else {
                throw ProviderError.transport("sin resultado")
            }
            group.cancelAll()
            return first
        }
    }

    /// Backoff exponencial 1, 2, 4, 8 rondas, con tope en 8.
    /// Solo lo disparan rate limit y 5xx: un 401 no se arregla esperando.
    private func updateBackoff(_ id: ProviderID, succeeded: Bool, failure: String?) {
        if succeeded {
            backoffRounds[id] = nil
            skipCounters[id] = nil
            return
        }
        guard let failure, failure.contains("rate limited") || Self.isServerError(failure) else { return }
        let next = min((backoffRounds[id] ?? 0) == 0 ? 1 : (backoffRounds[id]! * 2), 8)
        backoffRounds[id] = next
        skipCounters[id] = next
    }

    private static func isServerError(_ description: String) -> Bool {
        guard let range = description.range(of: "HTTP "),
              let status = Int(description[range.upperBound...].prefix(3)) else { return false }
        return (500...599).contains(status)
    }

    /// Intervalo hasta la próxima ronda, comparando medianas consecutivas.
    public func nextInterval(after round: SampleRound) -> TimeInterval {
        guard cadence.adaptive else { return cadence.stableInterval }

        let durations = round.samples.values.map(\.durationSeconds).sorted()
        guard !durations.isEmpty else {
            // Sin datos: no aceleres contra una API caída.
            return cadence.stableInterval
        }
        let median = DivergenceAnalyzer.medianOf(durations)
        defer { lastMedian = median }

        guard let previous = lastMedian else {
            // Primera ronda: sin referencia, muestrea rápido para formar serie.
            return cadence.activeInterval
        }
        return Double(abs(median - previous)) >= cadence.movementThreshold
            ? cadence.activeInterval
            : cadence.stableInterval
    }
}
