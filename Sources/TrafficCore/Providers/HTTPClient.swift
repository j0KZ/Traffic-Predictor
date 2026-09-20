import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Toda la red del core entra por acá. Los tests inyectan un stub.
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(timeout: TimeInterval = 15) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.transport("respuesta no HTTP")
            }
            return (data, http)
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }
    }
}

extension HTTPClient {
    /// Traduce el status en el error tipado que corresponde, o devuelve el cuerpo.
    /// Un 200 con cuerpo vacío es un fallo de decodificación, no un éxito.
    func fetchJSONBody(_ request: URLRequest, provider: ProviderID) async throws -> Data {
        let (data, http) = try await send(request)

        switch http.statusCode {
        case 200...299:
            guard !data.isEmpty else {
                throw ProviderError.decoding("200 con cuerpo vacío")
            }
            return data
        case 429:
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            throw ProviderError.rateLimited(retryAfter: retryAfter)
        default:
            throw ProviderError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "<cuerpo no utf8>"
            )
        }
    }
}
