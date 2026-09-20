import Foundation
import TrafficCore

/// Formato de salida. Un instrumento de medición: números crudos, sin adornos.
enum Report {

    /// Padding propio: String(format:) con %-8s obliga a pasar por C.
    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    static func hms(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return h > 0 ? String(format: "%dh%02dm%02ds", h, m, s) : String(format: "%dm%02ds", m, s)
    }

    static func signedMinutes(_ seconds: Int?) -> String {
        guard let seconds else { return "—" }
        let minutes = Double(seconds) / 60
        return String(format: "%+.1f min", minutes)
    }

    static func round(_ round: SampleRound, query: RouteQuery, index: Int, total: Int) -> String {
        var out = ""
        let stamp = ISO8601DateFormatter().string(from: round.capturedAt)
        out += "\n══ Ronda \(index)/\(total) — \(stamp)\n\n"

        let divergence = DivergenceAnalyzer.analyze(
            round.samples,
            expectedDistanceMeters: query.expectedDistanceMeters
        )

        out += "  " + pad("FUENTE", 8) + pad("ETA", 12) + pad("vs BASELINE", 13)
             + pad("DISTANCIA", 12) + pad("COBERTURA", 11) + "ESTADO\n"
        out += "  " + String(repeating: "─", count: 74) + "\n"

        // Ordenadas por ETA: la comparación es el punto.
        for sample in round.samples.values.sorted(by: { $0.durationSeconds < $1.durationSeconds }) {
            var status = "ok"
            if divergence.divergentRoutes.contains(sample.provider) {
                status = "RUTA DIVERGENTE (excluida)"
            } else if sample.provider == divergence.outlier {
                status = "outlier"
            }
            out += "  " + pad(sample.provider.rawValue, 8)
                 + pad(hms(sample.durationSeconds), 12)
                 + pad(signedMinutes(sample.delaySeconds(baseline: query.freeFlowBaselineSeconds)), 13)
                 + pad(String(format: "%.1f km", Double(sample.distanceMeters) / 1000), 12)
                 + pad(sample.trafficCoverage.map { String(format: "%.0f%%", $0 * 100) } ?? "—", 11)
                 + status + "\n"
        }

        for (provider, reason) in round.failures.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            // El error exacto, no un resumen.
            out += "  " + pad(provider.rawValue, 8) + "ERROR: \(reason)\n"
        }

        out += "\n  Veredicto: \(verdictText(divergence))\n"
        if divergence.verdict != .insufficient {
            out += "  Mediana: \(hms(divergence.median))"
            out += "  ·  Spread: \(hms(divergence.spreadSeconds))"
            out += String(format: " (%.1f%%)\n", divergence.spreadRatio * 100)
        }

        // Una fuente con poca cobertura no está midiendo tráfico: está
        // devolviendo su tiempo histórico. Decirlo sin adornos.
        for sample in round.samples.values.sorted(by: { $0.provider.rawValue < $1.provider.rawValue }) {
            if let coverage = sample.trafficCoverage, coverage < 0.5 {
                out += String(
                    format: "  ⚠ %@ tiene datos de tráfico en solo %.0f%% del trazado: su ETA es\n    mayormente tiempo histórico, no medición en vivo.\n",
                    sample.provider.rawValue, coverage * 100
                )
            }
        }

        out += incidentsText(round)
        return out
    }

    private static func verdictText(_ d: Divergence) -> String {
        var text: String
        switch d.verdict {
        case .consensus:    text = "CONSENSO — las fuentes concuerdan"
        case .minorSpread:  text = "DISPERSIÓN MENOR"
        case .majorSpread:
            text = "DISPERSIÓN MAYOR — confía en la mediana, no en el mínimo"
            if let outlier = d.outlier { text += " (outlier: \(outlier.rawValue))" }
        case .insufficient: text = "INSUFICIENTE — menos de 2 fuentes sobre el corredor"
        }
        if !d.divergentRoutes.isEmpty {
            let names = d.divergentRoutes.map(\.rawValue).joined(separator: ", ")
            text += "\n  Excluidas por rutear fuera del corredor: \(names)"
        }
        return text
    }

    private static func incidentsText(_ round: SampleRound) -> String {
        // Un mismo incidente puede venir de dos fuentes; se muestra una vez.
        var seen = Set<String>()
        var rows: [(TrafficIncident, ProviderID)] = []
        for sample in round.samples.values {
            for incident in sample.incidents where seen.insert(incident.id).inserted {
                rows.append((incident, sample.provider))
            }
        }
        guard !rows.isEmpty else {
            return "\n  Incidentes sobre la ruta: ninguno reportado\n"
        }

        var out = "\n  Incidentes sobre la ruta (\(rows.count)):\n"
        for (incident, provider) in rows.sorted(by: { ($0.0.routeRatio ?? 0) < ($1.0.routeRatio ?? 0) }) {
            let position = incident.routeRatio.map { String(format: "%.0f%%", $0 * 100) } ?? "?"
            out += "    [\(position) del trayecto] \(incident.category.rawValue.uppercased())"
            out += " · \(incident.description ?? "sin descripción")"
            out += " · vía \(provider.rawValue)\n"
            if let delay = incident.delaySeconds {
                out += "        demora atribuida: \(hms(delay))\n"
            }
            if incident.hasReliableEnd, let end = incident.endTime {
                out += "        fin programado: \(ISO8601DateFormatter().string(from: end))\n"
            }
        }
        return out
    }

    static func recovery(_ recovery: Recovery) -> String {
        var out = "\n══ Recuperación\n\n"
        switch recovery {
        case .scheduled(let endsAt, let source):
            out += "  Fin programado: \(ISO8601DateFormatter().string(from: endsAt))"
            out += "  (dato de \(source.rawValue), confianza alta)\n"
        case .trending(let clearAt, let rSquared):
            out += "  Proyección de despeje: \(ISO8601DateFormatter().string(from: clearAt))"
            out += String(format: "  (R²=%.2f)\n", rSquared)
        case .unclear(let reason):
            // Se dice por qué, en vez de mostrar un guion.
            out += "  Sin estimación: \(reason)\n"
        case .worsening(let slope):
            out += String(format: "  Sin estimación: empeorando a %.1f s/min\n", slope)
        case .insufficient(let needed):
            out += "  Sin estimación: faltan \(needed) muestra(s) para medir tendencia\n"
        }
        return out
    }
}
