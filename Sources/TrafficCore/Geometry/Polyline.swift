import Foundation

/// Google encoded polyline, algoritmo estándar con precisión 1e-5.
public enum Polyline {

    public static func decode(_ encoded: String, precision: Int = 5) -> [Coordinate] {
        let factor = pow(10.0, Double(precision))
        var coords: [Coordinate] = []
        var index = encoded.startIndex
        var lat = 0, lon = 0

        while index < encoded.endIndex {
            guard let dLat = nextValue(encoded, &index) else { break }
            guard let dLon = nextValue(encoded, &index) else { break }
            lat += dLat
            lon += dLon
            coords.append(Coordinate(lat: Double(lat) / factor, lon: Double(lon) / factor))
        }
        return coords
    }

    public static func encode(_ coords: [Coordinate], precision: Int = 5) -> String {
        let factor = pow(10.0, Double(precision))
        var out = ""
        var prevLat = 0, prevLon = 0
        for c in coords {
            let lat = Int((c.lat * factor).rounded())
            let lon = Int((c.lon * factor).rounded())
            out += encodeValue(lat - prevLat)
            out += encodeValue(lon - prevLon)
            prevLat = lat
            prevLon = lon
        }
        return out
    }

    /// nil cuando la cadena se corta a mitad de un valor: entrada corrupta,
    /// se devuelve lo decodificado hasta ahí en vez de reventar.
    private static func nextValue(_ s: String, _ index: inout String.Index) -> Int? {
        var result = 0
        var shift = 0
        var byte = 0
        repeat {
            guard index < s.endIndex else { return nil }
            guard let ascii = s[index].asciiValue else { return nil }
            byte = Int(ascii) - 63
            guard byte >= 0 else { return nil }
            result |= (byte & 0x1F) << shift
            shift += 5
            index = s.index(after: index)
            if shift > 32 { return nil }
        } while byte >= 0x20
        return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
    }

    private static func encodeValue(_ value: Int) -> String {
        var v = value < 0 ? ~(value << 1) : (value << 1)
        var out = ""
        while v >= 0x20 {
            out.append(Character(UnicodeScalar(UInt8((0x20 | (v & 0x1F)) + 63))))
            v >>= 5
        }
        out.append(Character(UnicodeScalar(UInt8(v + 63))))
        return out
    }
}
