import Foundation
import ArgumentParser
import TrafficCore

@main
struct TrafficLensCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trafficlens-cli",
        abstract: "Compara ETA en vivo de varias fuentes sobre una ruta fija."
    )

    @Option(name: .long, help: "Ruta en JSON (origen, destino, waypoints, baseline).")
    var route: String = "route.json"

    @Option(name: .long, help: "Número de rondas de muestreo.")
    var rounds: Int = 3

    @Option(name: .long, help: "Segundos entre rondas. Ignorado si --adaptive.")
    var interval: Int = 180

    @Option(name: .long, help: "Archivo SQLite donde persistir.")
    var db: String = "trafficlens.sqlite"

    @Flag(name: .long, help: "Usa la cadencia adaptativa en vez de --interval.")
    var adaptive = false

    @Flag(name: .long, help: "Incluye Google Routes (requiere billing activo).")
    var withGoogle = false

    func run() async throws {
        let file = try RouteFile.load(route)
        let query = file.query()

        let credentials = CredentialStore()
        var providers: [any TrafficProvider] = []
        var skipped: [String] = []

        // Solo se consultan las fuentes con credencial: una fuente sin key
        // falla cada ronda y ensucia la estadística de fallas.
        for (id, make) in Self.available(withGoogle: withGoogle) {
            if (try? credentials.apiKey(for: id)) != nil {
                providers.append(make())
            } else {
                skipped.append(id.rawValue)
            }
        }

        guard !providers.isEmpty else {
            throw ValidationError("Ninguna fuente tiene credencial. Revisa .env.")
        }

        print("Ruta: \(file.label ?? file.id)")
        print("Fuentes activas: \(providers.map(\.id.rawValue).joined(separator: ", "))")
        if !skipped.isEmpty {
            print("Sin credencial, omitidas: \(skipped.joined(separator: ", "))")
        }
        if let baseline = query.freeFlowBaselineSeconds {
            print("Baseline de flujo libre: \(Report.hms(baseline))")
        }
        if let expected = query.expectedDistanceMeters {
            print(String(format: "Distancia esperada del corredor: %.1f km", Double(expected) / 1000))
        } else {
            print("Sin distancia esperada: no se podrá excluir ruteo por otro corredor.")
        }

        let store = try SampleStore(path: db)
        let engine = SamplingEngine(providers: providers, store: store)

        var series: [RecoveryEstimator.DelayPoint] = []
        var allIncidents: [TrafficIncident] = []
        var incidentSources: [String: ProviderID] = [:]

        for index in 1...rounds {
            let round = await engine.runOnce(query)
            print(Report.round(round, query: query, index: index, total: rounds))

            let divergence = DivergenceAnalyzer.analyze(
                round.samples, expectedDistanceMeters: query.expectedDistanceMeters
            )
            // Solo entra a la serie lo medido sobre el corredor real.
            if divergence.verdict != .insufficient, let baseline = query.freeFlowBaselineSeconds {
                series.append(.init(
                    at: round.capturedAt,
                    delaySeconds: max(0, divergence.median - baseline)
                ))
            }
            for sample in round.samples.values {
                for incident in sample.incidents {
                    if incidentSources.updateValue(sample.provider, forKey: incident.id) == nil {
                        allIncidents.append(incident)
                    }
                }
            }

            guard index < rounds else { break }
            let wait = adaptive ? await engine.nextInterval(after: round) : TimeInterval(interval)
            print("  … siguiente ronda en \(Int(wait))s\n")
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }

        print(Report.recovery(RecoveryEstimator.estimate(
            incidents: allIncidents,
            incidentSources: incidentSources,
            series: series
        )))
        print("Persistido en \(db)\n")
    }

    private static func available(withGoogle: Bool) -> [(ProviderID, () -> any TrafficProvider)] {
        var list: [(ProviderID, () -> any TrafficProvider)] = [
            (.tomtom, { TomTomProvider() }),
            (.here,   { HereProvider() }),
            (.mapbox, { MapboxProvider() }),
        ]
        if withGoogle {
            list.append((.google, { GoogleRoutesProvider() }))
        }
        return list
    }
}
