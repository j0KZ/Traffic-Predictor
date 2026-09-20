import Foundation

public protocol TrafficProvider: Sendable {
    var id: ProviderID { get }
    func fetch(_ query: RouteQuery) async throws -> ETASample
}

enum DurationParser {
    /// Google entrega duraciones como "8340s". Sin el sufijo no es un dato válido.
    static func parseGoogleDuration(_ raw: String) throws -> Int {
        guard raw.hasSuffix("s") else {
            throw ProviderError.decoding("duración sin sufijo 's': \(raw)")
        }
        let numeric = String(raw.dropLast())
        // Google puede mandar fracciones: "8340.5s". Truncamos al segundo.
        guard let value = Double(numeric), value.isFinite, value >= 0 else {
            throw ProviderError.decoding("duración no numérica: \(raw)")
        }
        return Int(value)
    }
}

enum ISO8601 {
    /// Los proveedores mezclan con y sin fracciones de segundo.
    static func parse(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    static func string(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}
