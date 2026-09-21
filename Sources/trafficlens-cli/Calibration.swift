import Foundation
import ArgumentParser
import TrafficCore

struct Reference: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Registra una lectura de referencia (Waze, viaje real…)."
    )

    @Option(name: .long) var route: String = "route.json"
    @Option(name: .long) var db: String = "trafficlens.sqlite"
    @Option(name: .long, help: "Nombre de la fuente: waze, apple, viaje-real…") var source: String = "waze"
    @Option(name: .long, help: "ETA como 2h07m, 127m o segundos.") var eta: String
    @Option(name: .long, help: "Distancia en km.") var km: Double?
    @Option(name: .long, help: "Momento de la lectura en ISO8601. Por defecto, ahora.") var at: String?
    @Option(name: .long) var note: String?

    func run() async throws {
        let file = try RouteFile.load(route)
        guard let seconds = DurationInput.parse(eta) else {
            throw ValidationError("ETA ilegible: \(eta). Usa 2h07m, 127m o segundos.")
        }
        var capturedAt = Date()
        if let at {
            guard let parsed = ISO8601DateFormatter().date(from: at) else {
                throw ValidationError("Fecha ilegible: \(at)")
            }
            capturedAt = parsed
        }

        let reading = ReferenceReading(
            routeID: file.id, source: source, capturedAt: capturedAt,
            durationSeconds: seconds, distanceMeters: km.map { Int($0 * 1000) }, note: note
        )
        try await SampleStore(path: db).persist(reading)
        print("Registrada: \(source) \(Report.hms(seconds)) @ \(ISO8601DateFormatter().string(from: capturedAt))")
    }
}

struct Calibrate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sesgo de cada fuente contra las referencias, por ruta y por franja horaria."
    )

    @Option(name: .long, parsing: .upToNextOption, help: "Archivos de ruta.") var routes: [String] = ["route.json"]
    @Option(name: .long) var db: String = "trafficlens.sqlite"
    @Option(name: .long, help: "Días hacia atrás a considerar.") var days: Int = 30

    private struct Tagged {
        let provider: ProviderID
        let source: String
        let route: String
        let band: BandKey
        let pair: Calibrator.Pair
    }

    func run() async throws {
        let store = try SampleStore(path: db)
        let to = Date()
        let from = to.addingTimeInterval(-Double(days) * 86_400)

        // Se empareja dentro de cada ruta; recién después se juntan los pares.
        var tagged: [Tagged] = []
        for path in routes {
            let file = try RouteFile.load(path)
            let samples = try await store.samples(routeID: file.id, from: from, to: to)
            let references = try await store.references(routeID: file.id, from: from, to: to)
            for (source, refs) in Dictionary(grouping: references, by: \.source) {
                for provider in ProviderID.allCases {
                    for pair in Calibrator.pairs(provider: provider, samples: samples, references: refs) {
                        tagged.append(Tagged(provider: provider, source: source, route: file.id,
                                             band: .of(pair.at, in: file.zone), pair: pair))
                    }
                }
            }
        }

        guard !tagged.isEmpty else {
            print("Sin pares: ninguna muestra cae a menos de 5 min de una lectura de referencia en la misma ruta.")
            return
        }
        print("Pares totales: \(tagged.count)  ·  rutas: \(Set(tagged.map(\.route)).count)\n")

        print("══ Por franja horaria (hora local de cada ruta)\n")
        print("  " + Report.pad("FRANJA", 34) + Report.pad("FUENTE", 9) + Report.pad("PARES", 7)
              + Report.pad("ERROR", 9) + Report.pad("SESGO", 12) + "RUTAS")
        for band in Set(tagged.map(\.band)).sorted() {
            for provider in ProviderID.allCases {
                let group = tagged.filter { $0.band == band && $0.provider == provider }
                guard let bias = Calibrator.summarize(provider: provider, source: group.first?.source ?? "",
                                                     pairs: group.map(\.pair)),
                      let mae = Calibrator.medianAbsoluteError(bias.pairs) else { continue }
                let direction = bias.ratio < 1 ? "optimista" : "pesimista"
                print("  " + Report.pad(band.label, 34) + Report.pad(provider.rawValue, 9)
                      + Report.pad("\(bias.pairs.count)", 7)
                      + Report.pad(String(format: "%.1f%%", mae * 100), 9)
                      + Report.pad(String(format: "%.0f%% %@", abs(1 - bias.ratio) * 100, direction), 12)
                      + Set(group.map(\.route)).sorted().joined(separator: ", "))
            }
        }

        print("\n══ Por ruta\n")
        for route in Set(tagged.map(\.route)).sorted() {
            for provider in ProviderID.allCases {
                let group = tagged.filter { $0.route == route && $0.provider == provider }
                guard let bias = Calibrator.summarize(provider: provider, source: group.first?.source ?? "",
                                                     pairs: group.map(\.pair)) else { continue }
                var line = "  " + Report.pad(route, 24) + Report.pad(provider.rawValue, 9)
                    + Report.pad("\(bias.pairs.count) par(es)", 12)
                    + Report.pad(String(format: "factor %.3f", bias.ratio), 15)
                    + Report.pad(Report.signedMinutes(bias.offsetSeconds), 12)
                if let r = bias.trendCorrelation {
                    line += String(format: "tendencia %.2f", r)
                } else {
                    line += "tendencia —"
                }
                print(line)
            }
        }
        print("\nERROR = error relativo mediano contra la referencia (menor es mejor).")
        print("Tendencia — = menos de 3 pares o la referencia no se movió ≥3 min.")
        print("Correcciones: se ofrecen desde \(Calibrator.minimumPairsForCorrection) pares por fuente y franja.")
    }
}

enum DurationInput {
    /// Acepta "2h07m", "2h", "127m", "7620s" o "7620".
    static func parse(_ raw: String) -> Int? {
        let text = raw.lowercased().replacingOccurrences(of: " ", with: "")
        if let plain = Int(text) { return plain }
        if text.hasSuffix("s"), let v = Int(text.dropLast()) { return v }

        var total = 0
        var number = ""
        var sawUnit = false
        for ch in text {
            if ch.isNumber {
                number.append(ch)
            } else {
                guard let v = Int(number) else { return nil }
                switch ch {
                case "h": total += v * 3600
                case "m": total += v * 60
                default: return nil
                }
                number = ""
                sawUnit = true
            }
        }
        guard sawUnit, number.isEmpty else { return nil }
        return total
    }
}
