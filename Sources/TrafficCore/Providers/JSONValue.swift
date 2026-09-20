import Foundation

/// GeoJSON mezcla formas: Point trae [lon,lat] y LineString trae [[lon,lat],…].
/// Decodificamos sin comprometernos a una y extraemos el primer par.
indirect enum JSONValue: Decodable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Double.self) {
            self = .number(v)
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            self = .null
        }
    }

    /// Primer par [lon, lat] que aparezca, a cualquier profundidad.
    /// Devuelve nil si las coordenadas vienen nulas o malformadas.
    var firstCoordinate: Coordinate? {
        guard case .array(let items) = self, let head = items.first else { return nil }

        if case .number(let lon) = head, items.count >= 2, case .number(let lat) = items[1] {
            guard lat.isFinite, lon.isFinite,
                  (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
            return Coordinate(lat: lat, lon: lon)
        }
        return head.firstCoordinate
    }
}
