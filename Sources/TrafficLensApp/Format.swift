import Foundation
import TrafficCore

enum Format {
    static func hm(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
    }

    static func signedMinutes(_ seconds: Int?) -> String {
        guard let seconds else { return "sin baseline" }
        return String(format: "%+.0f min", Double(seconds) / 60)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func verdict(_ v: Verdict) -> String {
        switch v {
        case .consensus: return "Consenso"
        case .minorSpread: return "Dispersión menor"
        case .majorSpread: return "Dispersión mayor: confía en la mediana, no en el mínimo"
        case .insufficient: return "Insuficiente: menos de 2 fuentes sobre el corredor"
        }
    }

    static func category(_ c: IncidentCategory) -> String {
        switch c {
        case .accident: return "Accidente"
        case .congestion: return "Congestión"
        case .roadworks: return "Obras"
        case .closure: return "Cierre"
        case .weather: return "Clima"
        case .hazard: return "Peligro"
        case .event: return "Evento"
        case .unknown: return "Sin categoría"
        }
    }
}
