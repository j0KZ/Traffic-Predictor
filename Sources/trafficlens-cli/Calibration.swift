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
        abstract: "Sesgo de cada fuente contra las lecturas de referencia."
    )

    @Option(name: .long) var route: String = "route.json"
    @Option(name: .long) var db: String = "trafficlens.sqlite"
    @Option(name: .long, help: "Días hacia atrás a considerar.") var days: Int = 30

    func run() async throws {
        let file = try RouteFile.load(route)
        let store = try SampleStore(path: db)
        let to = Date()
        let from = to.addingTimeInterval(-Double(days) * 86_400)

        let samples = try await store.samples(routeID: file.id, from: from, to: to)
        let references = try await store.references(routeID: file.id, from: from, to: to)
        print("Muestras: \(samples.count)  ·  Lecturas de referencia: \(references.count)\n")

        let biases = Calibrator.bias(samples: samples, references: references)
        guard !biases.isEmpty else {
            print("Sin pares: ninguna muestra cae a menos de 5 min de una lectura de referencia.")
            return
        }

        for bias in biases {
            let direction = bias.ratio < 1 ? "optimista" : "pesimista"
            print("\(bias.provider.rawValue) vs \(bias.referenceSource)  (\(bias.pairs.count) par(es))")
            print(String(format: "  factor: %.3f  → %.1f%% %@", bias.ratio, abs(1 - bias.ratio) * 100, direction))
            print("  diferencia mediana: \(Report.signedMinutes(bias.offsetSeconds))")
            if let r = bias.trendCorrelation {
                let reading = r > 0.8 ? "sigue la curva" : r > 0.4 ? "la sigue a medias" : "no la sigue"
                print(String(format: "  correlación de tendencia: %.2f (%@)", r, reading))
            } else {
                print("  correlación de tendencia: sin datos (menos de 3 pares o serie plana)")
            }
            if bias.isUsableForCorrection {
                print("  corrección utilizable")
            } else {
                let missing = Calibrator.minimumPairsForCorrection - bias.pairs.count
                print("  corrección NO utilizable: faltan \(missing) par(es)")
            }
            print("")
        }
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
