import SwiftUI
import Charts
import TrafficCore

struct MainView: View {
    let model: AppModel

    var body: some View {
        switch model.state {
        case .loading:
            ProgressView("Cargando ruta e historia…")
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 8) {
                Text("No se pudo iniciar").font(.title2.bold())
                Text(reason).font(.body.monospaced()).textSelection(.enabled)
            }
            .padding(32)
        case .ready:
            VStack(spacing: 0) {
                HeaderBar(model: model)
                Divider()
                HStack(alignment: .top, spacing: 0) {
                    ETAColumn(model: model).frame(width: 290)
                    Divider()
                    ChartPanel(model: model).frame(maxWidth: .infinity)
                    Divider()
                    IncidentColumn(incidents: model.incidents).frame(width: 320)
                }
                Divider()
                RecoveryBar(recovery: model.recovery, biases: model.biases)
            }
        }
    }
}

// MARK: - Cabecera

private struct HeaderBar: View {
    let model: AppModel

    var body: some View {
        HStack {
            Text(model.routeLabel).font(.headline)
            if let baseline = model.query?.freeFlowBaselineSeconds {
                Text("· baseline \(Format.hm(baseline))").foregroundStyle(.secondary)
            }
            Spacer()
            if !model.skippedProviders.isEmpty {
                Text("Sin credencial: \(model.skippedProviders.map(\.rawValue).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let next = model.nextRoundAt {
                Text("Próxima ronda \(Format.time(next))").font(.caption.monospacedDigit())
            } else {
                Text("Muestreando…").font(.caption)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

// MARK: - Columna izquierda: ETAs

private struct ETAColumn: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let d = model.divergence, d.verdict != .insufficient {
                    MedianCard(median: d.median, baseline: model.query?.freeFlowBaselineSeconds)
                }

                ForEach(model.sortedSamples) { sample in
                    ETACard(
                        sample: sample,
                        baseline: model.query?.freeFlowBaselineSeconds,
                        excluded: model.divergence?.divergentRoutes.contains(sample.provider) == true,
                        isOutlier: model.divergence?.outlier == sample.provider
                    )
                }

                ForEach((model.latest?.failures ?? [:]).sorted(by: { $0.key.rawValue < $1.key.rawValue }), id: \.key) { provider, reason in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(provider.rawValue.uppercased()).font(.caption.bold())
                        // El error exacto, no un resumen.
                        Text(reason).font(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled)
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                if let d = model.divergence {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Veredicto").font(.caption).foregroundStyle(.secondary)
                        Text(Format.verdict(d.verdict)).font(.callout.bold())
                        if d.verdict != .insufficient {
                            Text(String(format: "Spread %@ (%.1f%%)", Format.hm(d.spreadSeconds), d.spreadRatio * 100))
                                .font(.caption.monospacedDigit())
                        }
                        if !d.divergentRoutes.isEmpty {
                            Text("Excluidas por rutear fuera del corredor: \(d.divergentRoutes.map(\.rawValue).joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}

private struct MedianCard: View {
    let median: Int
    let baseline: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("MEDIANA").font(.caption.bold()).foregroundStyle(.secondary)
            Text(Format.hm(median)).font(.system(size: 40, weight: .semibold).monospacedDigit())
            if let baseline {
                Text("\(Format.signedMinutes(median - baseline)) sobre baseline")
                    .font(.callout.monospacedDigit())
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ETACard: View {
    let sample: ETASample
    let baseline: Int?
    let excluded: Bool
    let isOutlier: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(sample.provider.rawValue.uppercased()).font(.caption.bold())
                Spacer()
                badge
            }
            Text(Format.hm(sample.durationSeconds))
                .font(.system(size: 30, weight: .medium).monospacedDigit())
                .strikethrough(excluded)
            Text(Format.signedMinutes(sample.delaySeconds(baseline: baseline)) + " sobre baseline")
                .font(.caption.monospacedDigit())
            HStack(spacing: 8) {
                Text(String(format: "%.1f km", Double(sample.distanceMeters) / 1000))
                if let coverage = sample.trafficCoverage {
                    Text(String(format: "cobertura %.0f%%", coverage * 100))
                        .foregroundStyle(coverage < 0.5 ? .orange : .secondary)
                }
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if let coverage = sample.trafficCoverage, coverage < 0.5 {
                Text("Mayormente tiempo histórico, no medición en vivo.")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var badge: some View {
        if excluded {
            Label("ruta divergente", systemImage: "arrow.triangle.branch").font(.caption2).foregroundStyle(.orange)
        } else if isOutlier {
            Label("outlier", systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
        } else {
            Label("ok", systemImage: "checkmark.circle").font(.caption2).foregroundStyle(.green)
        }
    }
}

// MARK: - Centro: gráfico

private struct ChartPanel: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ETA por fuente (minutos)").font(.headline)
            if model.points.isEmpty {
                Spacer()
                Text("Sin muestras todavía. La primera ronda está en curso.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                Chart {
                    ForEach(model.points) { point in
                        LineMark(x: .value("Hora", point.at), y: .value("Minutos", point.minutes))
                            .foregroundStyle(by: .value("Fuente", point.series))
                        PointMark(x: .value("Hora", point.at), y: .value("Minutos", point.minutes))
                            .foregroundStyle(by: .value("Fuente", point.series))
                            .symbolSize(18)
                    }
                    if let baseline = model.query?.freeFlowBaselineSeconds {
                        RuleMark(y: .value("Baseline", Double(baseline) / 60))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(.secondary)
                            .annotation(position: .top, alignment: .leading) {
                                Text("baseline").font(.caption2).foregroundStyle(.secondary)
                            }
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartLegend(position: .top, alignment: .leading)
            }
        }
        .padding(16)
    }
}

// MARK: - Derecha: incidentes

private struct IncidentColumn: View {
    let incidents: [TrafficIncident]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Incidentes sobre la ruta").font(.headline)
            if incidents.isEmpty {
                Text("Ninguno reportado en la última ronda.").foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(incidents) { IncidentRow(incident: $0) }
                    }
                }
            }
        }
        .padding(16)
    }
}

private struct IncidentRow: View {
    let incident: TrafficIncident

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(incident.routeRatio.map { String(format: "%.0f%% del trayecto", $0 * 100) } ?? "posición ?")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Text(Format.category(incident.category)).font(.caption.bold())
            }
            Text(incident.description ?? "Sin descripción").font(.callout)
            if let delay = incident.delaySeconds {
                Text("Demora atribuida \(Format.hm(delay))").font(.caption.monospacedDigit())
            }
            // Distinción clara: un fin programado es dato, uno estimado no.
            if incident.hasReliableEnd, let end = incident.endTime {
                Label("Fin programado \(Format.time(end))", systemImage: "calendar.badge.clock")
                    .font(.caption).foregroundStyle(.green)
            } else if incident.endTime != nil {
                Label("Fin estimado por el proveedor: no confiable", systemImage: "questionmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Sin fin conocido", systemImage: "minus.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            Rectangle().fill(incident.hasReliableEnd ? Color.green : Color.orange).frame(width: 3)
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Abajo: recuperación y calibración

private struct RecoveryBar: View {
    let recovery: Recovery
    let biases: [Calibrator.Bias]

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recuperación").font(.caption.bold()).foregroundStyle(.secondary)
                Text(text).font(.callout)
            }
            Spacer()
            if !biases.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Calibración").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(biases, id: \.provider) { bias in
                        Text(String(format: "%@ vs %@: %+.0f min · %d par(es)%@",
                                    bias.provider.rawValue, bias.referenceSource,
                                    Double(bias.offsetSeconds) / 60, bias.pairs.count,
                                    bias.isUsableForCorrection ? "" : " · aún no corrige"))
                            .font(.caption.monospacedDigit())
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// Nunca un guion: si no hay estimación, se dice por qué.
    private var text: String {
        switch recovery {
        case .scheduled(let end, let source):
            return "Fin programado \(Format.time(end)) según \(source.rawValue). Confianza alta."
        case .trending(let clear, let r2):
            return String(format: "Despeje proyectado %@ (R² %.2f)", Format.time(clear), r2)
        case .unclear(let reason):
            return "Sin estimación: \(reason)."
        case .worsening(let slope) where slope < 0.5:
            return "Sin estimación: el delay está estable, no hay tendencia a despejar."
        case .worsening(let slope):
            return String(format: "Sin estimación: el delay empeora a %.1f s/min.", slope)
        case .insufficient(let needed):
            return "Sin estimación: faltan \(needed) ronda(s) para medir tendencia."
        }
    }
}
