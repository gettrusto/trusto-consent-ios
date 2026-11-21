import Foundation
#if canImport(Security)
import Security
#endif

/// Transporte HTTP. Injetável para teste; o padrão usa `URLSession` efêmera.
public protocol ConsentHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession` sem cookies, sem cache e sem credenciais guardadas.
public struct URLSessionTransport: ConsentHTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 10) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TrustoConsentError.invalidResponse }
        return (data, http)
    }
}

/// Armazenamento seguro do identificador do visitante.
public protocol ConsentSecureStore: Sendable {
    func read(_ key: String) -> String?
    func write(_ key: String, value: String)
}

/// Keychain do aparelho, só neste aparelho e depois do primeiro desbloqueio. Não vai para backup
/// de outro aparelho.
public struct KeychainSecureStore: ConsentSecureStore {
    private let service: String

    public init(service: String = "io.gettrusto.consent") {
        self.service = service
    }

    public func read(_ key: String) -> String? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }

    public func write(_ key: String, value: String) {
        #if canImport(Security)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
        #endif
    }
}

/// Arquivos do SDK: decisão, fila e último banner. Em `Application Support`, fora do backup.
public protocol ConsentFileStore: Sendable {
    func load(_ name: String) -> Data?
    func save(_ name: String, data: Data)
    func remove(_ name: String)
}

public struct DirectoryFileStore: ConsentFileStore {
    private let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("TrustoConsent", isDirectory: true)
        }
    }

    public func load(_ name: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    public func save(_ name: String, data: Data) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var url = directory.appendingPathComponent(name)
            try data.write(to: url, options: [.atomic])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        } catch {
            // Falha de disco não derruba o app: a decisão segue em memória e a fila é refeita.
        }
    }

    public func remove(_ name: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
}

/// Relógio injetável.
public protocol ConsentClock: Sendable {
    func now() -> Date
}

public struct SystemClock: ConsentClock {
    public init() {}
    public func now() -> Date { Date() }
}
