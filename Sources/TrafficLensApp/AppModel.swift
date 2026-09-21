import Foundation
import Observation
import TrafficCore

/// Estado de la ventana. Muestrea en un loop propio y lee la historia de
/// SQLite al arrancar, para que el gráfico no empiece vacío.
@MainActor
@Observable
final class AppModel {
    struct Point: Identifiable, Equatable {
        let id = UUID()
        let series: String
        let at: Date
        let minutes: Double
    }

    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var state: LoadState = .loading
    private(set) var routeLabel = ""
    private(set) var query: RouteQuery?
    private(set) var latest: SampleRound?
    private(set) var divergence: Divergence?
    private(set) var recovery: Recovery = .insufficient(samplesNeeded: RecoveryEstimator.minimumSamples)
    private(set) var points: [Point] = []
    private(set) var biases: [Calibrator.Bias] = []
    private(set) var nextRoundAt: Date?
    private(set) var activeProviders: [ProviderID] = []
    private(set) var skippedProviders: [ProviderID] = []

    private var engine: SamplingEngine?
    private var store: SampleStore?
    private var loop: Task<Void, Never>?
    private var series: [RecoveryEstimator.DelayPoint] = []

    let routePath: String
    let dbPath: String

    init(routePath: String, dbPath: String) {
        self.routePath = routePath
        self.dbPath = dbPath
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.bootstrap()
            await self?.run()
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    private func bootstrap() async {
        do {
            let file = try RouteFile.load(routePath)
            let query = file.query()
            let store = try SampleStore(path: dbPath)

            let credentials = CredentialStore()
            var providers: [any TrafficProvider] = []
            let candidates: [(ProviderID, () -> any TrafficProvider)] = [
                (.tomtom, { TomTomProvider() }),
                (.here, { HereProvider() }),
                (.mapbox, { MapboxProvider() }),
                (.google, { GoogleRoutesProvider() }),
            ]
            for (id, make) in candidates {
                if (try? credentials.apiKey(for: id)) != nil {
                    providers.append(make())
                    activeProviders.append(id)
                } else {
                    skippedProviders.append(id)
                }
            }

            self.routeLabel = file.label ?? file.id
            self.query = query
            self.store = store
            self.engine = SamplingEngine(providers: providers, store: store)

            try await loadHistory()
            state = providers.isEmpty
                ? .failed("Ninguna fuente tiene credencial. Carga .env antes de abrir la app.")
                : .ready
        } catch {
            state = .failed("No se pudo iniciar: \(error)")
        }
    }

    private func run() async {
        guard case .ready = state, let engine, let query else { return }
        while !Task.isCancelled {
            let round = await engine.runOnce(query)
            apply(round)
            let wait = await engine.nextInterval(after: round)
            nextRoundAt = Date().addingTimeInterval(wait)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    /// Últimas 6 horas de muestras y lecturas de referencia.
    private func loadHistory() async throws {
        guard let store, let query else { return }
        let to = Date()
        let from = to.addingTimeInterval(-6 * 3600)
        let samples = try await store.samples(routeID: query.id, from: from, to: to)
        let references = try await store.references(routeID: query.id, from: from, to: to)

        points = samples.map { Point(series: $0.provider.rawValue, at: $0.capturedAt, minutes: Double($0.durationSeconds) / 60) }
            + references.map { Point(series: $0.source, at: $0.capturedAt, minutes: Double($0.durationSeconds) / 60) }
        biases = Calibrator.bias(samples: samples, references: references)

        // Reconstruye la serie de delay por ronda: muestras que comparten
        // minuto son la misma ronda.
        if let baseline = query.freeFlowBaselineSeconds {
            let rounds = Dictionary(grouping: samples) { Int($0.capturedAt.timeIntervalSince1970 / 60) }
            series = rounds.keys.sorted().compactMap { key in
                guard let group = rounds[key] else { return nil }
                let byProvider = Dictionary(group.map { ($0.provider, $0) }, uniquingKeysWith: { a, _ in a })
                let d = DivergenceAnalyzer.analyze(byProvider, expectedDistanceMeters: query.expectedDistanceMeters)
                guard d.verdict != .insufficient else { return nil }
                return .init(at: group[0].capturedAt, delaySeconds: max(0, d.median - baseline))
            }
        }
    }

    private func apply(_ round: SampleRound) {
        guard let query else { return }
        latest = round
        let d = DivergenceAnalyzer.analyze(round.samples, expectedDistanceMeters: query.expectedDistanceMeters)
        divergence = d

        for sample in round.samples.values {
            points.append(Point(series: sample.provider.rawValue, at: sample.capturedAt,
                                minutes: Double(sample.durationSeconds) / 60))
        }
        if d.verdict != .insufficient, let baseline = query.freeFlowBaselineSeconds {
            series.append(.init(at: round.capturedAt, delaySeconds: max(0, d.median - baseline)))
        }

        var sources: [String: ProviderID] = [:]
        for sample in round.samples.values {
            for incident in sample.incidents { sources[incident.id] = sample.provider }
        }
        recovery = RecoveryEstimator.estimate(incidents: incidents, incidentSources: sources, series: series)
    }

    /// Incidentes de la última ronda, deduplicados y ordenados por posición.
    var incidents: [TrafficIncident] {
        var seen = Set<String>()
        return (latest?.samples.values.flatMap(\.incidents) ?? [])
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.routeRatio ?? 0) < ($1.routeRatio ?? 0) }
    }

    /// Muestras de la última ronda, ordenadas por ETA.
    var sortedSamples: [ETASample] {
        (latest?.samples.values.map { $0 } ?? []).sorted { $0.durationSeconds < $1.durationSeconds }
    }
}
