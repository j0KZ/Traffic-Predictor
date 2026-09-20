import Foundation

public enum ProviderError: Error, Sendable, Equatable {
    case missingCredential(ProviderID)
    case http(status: Int, body: String)
    case decoding(String)
    case noRoute
    case rateLimited(retryAfter: TimeInterval?)
    case transport(String)
}

extension ProviderError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .missingCredential(let p):
            return "falta credencial para \(p.rawValue)"
        case .http(let status, let body):
            let trimmed = body.count > 400 ? String(body.prefix(400)) + "…" : body
            return "HTTP \(status): \(trimmed)"
        case .decoding(let detail):
            return "decodificación: \(detail)"
        case .noRoute:
            return "sin ruta viable"
        case .rateLimited(let retry):
            return retry.map { "rate limited, reintentar en \($0)s" } ?? "rate limited"
        case .transport(let detail):
            return "transporte: \(detail)"
        }
    }
}
