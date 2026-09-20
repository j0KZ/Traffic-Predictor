import Foundation
import Security

/// Keychain primero, variable de entorno como fallback. Nunca en el código.
public struct CredentialStore: Sendable {
    public static let service = "dev.j0kz.trafficlens"

    private let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func apiKey(for provider: ProviderID) throws -> String {
        if let fromKeychain = Self.keychainValue(account: provider.rawValue),
           !fromKeychain.isEmpty {
            return fromKeychain
        }
        let variable = "TRAFFICLENS_\(provider.rawValue.uppercased())_KEY"
        if let fromEnv = environment[variable]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fromEnv.isEmpty {
            return fromEnv
        }
        throw ProviderError.missingCredential(provider)
    }

    static func keychainValue(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
