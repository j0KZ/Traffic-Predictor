import Foundation

/// Franja horaria en la hora local de la ruta. La precisión de una fuente
/// depende de cuándo se mide: de madrugada todas aciertan; en la punta se
/// separan.
public enum TimeBand: String, CaseIterable, Sendable, Comparable {
    case madrugada      // 00-06
    case puntaManana    // 06-10
    case mediodia       // 10-16
    case puntaTarde     // 16-20
    case noche          // 20-24

    public var label: String {
        switch self {
        case .madrugada: return "madrugada"
        case .puntaManana: return "punta mañana"
        case .mediodia: return "mediodía"
        case .puntaTarde: return "punta tarde"
        case .noche: return "noche"
        }
    }

    public static func of(_ date: Date, in timeZone: TimeZone) -> TimeBand {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        switch calendar.component(.hour, from: date) {
        case 0..<6: return .madrugada
        case 6..<10: return .puntaManana
        case 10..<16: return .mediodia
        case 16..<20: return .puntaTarde
        default: return .noche
        }
    }

    public static func < (a: TimeBand, b: TimeBand) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// Franja más tipo de día: la punta de un domingo no es la de un lunes.
public struct BandKey: Hashable, Sendable, Comparable {
    public let band: TimeBand
    public let weekend: Bool

    public init(band: TimeBand, weekend: Bool) {
        self.band = band
        self.weekend = weekend
    }

    public static func of(_ date: Date, in timeZone: TimeZone) -> BandKey {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return BandKey(band: .of(date, in: timeZone), weekend: calendar.isDateInWeekend(date))
    }

    public var label: String { "\(band.label) · \(weekend ? "fin de semana" : "día hábil")" }

    public static func < (a: BandKey, b: BandKey) -> Bool {
        a.weekend != b.weekend ? !a.weekend : a.band < b.band
    }
}
