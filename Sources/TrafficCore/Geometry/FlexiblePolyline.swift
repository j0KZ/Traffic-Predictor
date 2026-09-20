import Foundation

/// Decodificador de HERE flexible polyline.
/// Port del algoritmo de referencia de heremaps/flexible-polyline.
/// Solo decodifica: no necesitamos emitir este formato.
public enum FlexiblePolyline {

    public enum DecodeError: Error, Sendable, Equatable {
        case empty
        case unsupportedVersion(Int)
        case truncated
        case invalidCharacter(Character)
    }

    private static let decodingTable: [Int] = [
        62, -1, -1, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, -1, -1, -1, -1, -1, -1,
        -1,  0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15, 16, 17,
        18, 19, 20, 21, 22, 23, 24, 25, -1, -1, -1, -1, 63, -1, 26, 27, 28, 29, 30,
        31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49,
        50, 51,
    ]

    /// Devuelve los puntos 2D. La tercera dimensión (altitud, nivel) se lee y descarta.
    public static func decode(_ encoded: String) throws -> [Coordinate] {
        guard !encoded.isEmpty else { throw DecodeError.empty }

        let chars = Array(encoded)
        var index = 0

        let header = try decodeHeader(chars, &index)
        guard header.version == 1 else {
            throw DecodeError.unsupportedVersion(header.version)
        }

        let latFactor = pow(10.0, Double(header.precision))
        // La tercera dimensión usa su propio factor; la leemos para avanzar bien
        // el cursor aunque no guardemos el valor.
        var lat = 0, lon = 0, third = 0
        var coords: [Coordinate] = []

        while index < chars.count {
            guard let dLat = try decodeSigned(chars, &index) else { break }
            guard let dLon = try decodeSigned(chars, &index) else { throw DecodeError.truncated }
            lat += dLat
            lon += dLon

            if header.thirdDim != 0 {
                guard let dThird = try decodeSigned(chars, &index) else { throw DecodeError.truncated }
                third += dThird
            }

            coords.append(Coordinate(lat: Double(lat) / latFactor, lon: Double(lon) / latFactor))
        }
        return coords
    }

    private struct Header {
        let version: Int
        let precision: Int
        let thirdDim: Int
        let thirdDimPrecision: Int
    }

    private static func decodeHeader(_ chars: [Character], _ index: inout Int) throws -> Header {
        let version = try decodeUnsigned(chars, &index)
        let encodedHeader = try decodeUnsigned(chars, &index)
        return Header(
            version: version,
            precision: encodedHeader & 15,
            thirdDim: (encodedHeader >> 4) & 7,
            thirdDimPrecision: (encodedHeader >> 7) & 15
        )
    }

    private static func decodeUnsigned(_ chars: [Character], _ index: inout Int) throws -> Int {
        var result = 0
        var shift = 0
        while index < chars.count {
            let value = try tableValue(chars[index])
            index += 1
            result |= (value & 0x1F) << shift
            if (value & 0x20) == 0 { return result }
            shift += 5
            if shift > 64 { throw DecodeError.truncated }
        }
        // Se acabó la cadena con el bit de continuación puesto: valor a medias.
        throw DecodeError.truncated
    }

    private static func decodeSigned(_ chars: [Character], _ index: inout Int) throws -> Int? {
        guard index < chars.count else { return nil }
        let value = try decodeUnsigned(chars, &index)
        return (value & 1) != 0 ? ~(value >> 1) : (value >> 1)
    }

    private static func tableValue(_ c: Character) throws -> Int {
        guard let ascii = c.asciiValue else { throw DecodeError.invalidCharacter(c) }
        let offset = Int(ascii) - 45
        guard offset >= 0, offset < decodingTable.count else {
            throw DecodeError.invalidCharacter(c)
        }
        let value = decodingTable[offset]
        guard value >= 0 else { throw DecodeError.invalidCharacter(c) }
        return value
    }
}
