import Foundation
import ArgumentParser
import TrafficCore

/// Una ronda sobre varias rutas a la vez. Pensado para calibrar en muchas
/// ciudades: sin incidentes por defecto, para no gastar esa cuota.
struct Sweep: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Una ronda en paralelo sobre varias rutas.")

    @Option(name: .long, parsing: .upToNextOption, help: "Archivos de ruta.") var routes: [String]
    @Option(name: .long) var db: String = "trafficlens.sqlite"
    @Flag(name: .long, help: "Consulta también incidentes (gasta cuota de TomTom).") var incidents = false
    @Option(name: .long, help: "Rutas consultadas a la vez.") var maxConcurrent: Int = 3

    func run() async throws {
        let files = try routes.map { try RouteFile.load($0) }
        let store = try SampleStore(path: db)
        let credentials = CredentialStore()
        let withIncidents = incidents

        var providers: [any TrafficProvider] = []
        if (try? credentials.apiKey(for: .tomtom)) != nil { providers.append(TomTomProvider(fetchIncidents: withIncidents)) }
        if (try? credentials.apiKey(for: .here)) != nil { providers.append(HereProvider(fetchIncidents: withIncidents)) }
        if (try? credentials.apiKey(for: .mapbox)) != nil { providers.append(MapboxProvider()) }
        guard !providers.isEmpty else { throw ValidationError("Ninguna fuente tiene credencial.") }

        // Un motor por ruta: el backoff de un proveedor en una ciudad no
        // debe dejarlo fuera en las demás.
        let engines = files.map { _ in SamplingEngine(providers: providers, store: store) }
        let limit = max(1, maxConcurrent)

        // Rutas en paralelo, pero de a `limit`: el plan gratis de TomTom
        // limita las consultas por segundo.
        let rounds = await withTaskGroup(of: (Int, SampleRound).self) { group in
            var out: [(Int, SampleRound)] = []
            var next = 0
            for _ in 0..<min(limit, files.count) {
                let i = next; next += 1
                group.addTask { (i, await engines[i].runOnce(files[i].query())) }
            }
            for await item in group {
                out.append(item)
                if next < files.count {
                    let i = next; next += 1
                    group.addTask { (i, await engines[i].runOnce(files[i].query())) }
                }
            }
            return out.sorted { $0.0 < $1.0 }
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
        print("Barrido \(stamp)")
        for (index, round) in rounds {
            let file = files[index]
            let band = BandKey.of(round.capturedAt, in: file.zone)
            var line = Report.pad(file.id, 22) + Report.pad(band.band.label, 14)
            for provider in providers.map(\.id) {
                if let s = round.samples[provider] {
                    line += Report.pad("\(provider.rawValue) \(Report.hms(s.durationSeconds)) \(String(format: "%.1fkm", Double(s.distanceMeters) / 1000))", 30)
                } else {
                    line += Report.pad("\(provider.rawValue) ERROR", 30)
                }
            }
            print(line)
            for (provider, reason) in round.failures {
                print("    \(provider.rawValue): \(reason)")
            }
        }
    }
}
