import Foundation
import XCTest
@testable import TrafficCore

/// HTTPClient de prueba: responde desde un guion, sin tocar la red.
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    struct Reply {
        let status: Int
        let data: Data
        let headers: [String: String]

        init(status: Int = 200, data: Data = Data(), headers: [String: String] = [:]) {
            self.status = status
            self.data = data
            self.headers = headers
        }
    }

    private let lock = NSLock()
    private var queue: [Reply]
    /// Respuesta usada cuando la cola se agota: permite no guionizar la segunda
    /// llamada de incidentes cuando el test solo mira la ruta.
    private let fallback: Reply?
    private(set) var requests: [URLRequest] = []

    init(replies: [Reply], fallback: Reply? = nil) {
        self.queue = replies
        self.fallback = fallback
    }

    convenience init(fixture: String, status: Int = 200) {
        self.init(replies: [Reply(status: status, data: Fixtures.data(fixture))],
                  fallback: Reply(status: 200, data: Data("{}".utf8)))
    }

    /// Síncrona a propósito: tomar el lock dentro de un contexto async es
    /// un error en Swift 6.
    private func nextReply(for request: URLRequest) -> Reply? {
        lock.withLock {
            requests.append(request)
            return queue.isEmpty ? fallback : queue.removeFirst()
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = nextReply(for: request)

        guard let reply else {
            throw ProviderError.transport("stub sin respuesta para \(request.url?.absoluteString ?? "?")")
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: reply.status,
            httpVersion: nil,
            headerFields: reply.headers
        )!
        return (reply.data, response)
    }
}

/// Cliente que nunca responde: para probar el timeout del motor.
struct HangingHTTPClient: HTTPClient {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        throw ProviderError.transport("no debería llegar acá")
    }
}

enum Fixtures {
    static func data(_ relativePath: String) -> Data {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(relativePath)", withExtension: nil),
              let data = try? Data(contentsOf: url) else {
            fatalError("fixture no encontrada: \(relativePath)")
        }
        return data
    }
}

extension CredentialStore {
    /// Credenciales falsas para tests: nunca tocan Keychain real vacío.
    static func stub() -> CredentialStore {
        CredentialStore(environment: [
            "TRAFFICLENS_GOOGLE_KEY": "test-google",
            "TRAFFICLENS_TOMTOM_KEY": "test-tomtom",
            "TRAFFICLENS_HERE_KEY": "test-here",
        ])
    }
}

/// Proveedor controlable, para los tests del motor.
struct FakeProvider: TrafficProvider {
    let id: ProviderID
    let result: Result<ETASample, ProviderError>
    var delay: TimeInterval = 0

    func fetch(_ query: RouteQuery) async throws -> ETASample {
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        return try result.get()
    }
}

func makeSample(
    _ provider: ProviderID,
    duration: Int,
    freeFlow: Int? = 6300,
    distance: Int = 179000,
    polyline: String? = nil,
    incidents: [TrafficIncident] = []
) -> ETASample {
    ETASample(
        provider: provider,
        durationSeconds: duration,
        freeFlowSeconds: freeFlow,
        distanceMeters: distance,
        polyline: polyline,
        incidents: incidents
    )
}

let testQuery = RouteQuery(
    id: "maitencillo-lascondes-r5n",
    origin: Coordinate(lat: -32.6558, lon: -71.4390),
    destination: Coordinate(lat: -33.4089, lon: -70.5680),
    waypoints: [Coordinate(lat: -32.7870, lon: -71.1890)],
    freeFlowBaselineSeconds: 6300
)
