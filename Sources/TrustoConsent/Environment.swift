import Foundation
#if canImport(Security)
import Security
#endif

// Infraestrutura do SDK, toda interna: o aplicativo usa só `TrustoConsent`. Os testes trocam
// cada peça por `@testable import`.

/// Transporte HTTP. O padrão usa `URLSession` efêmera.
protocol ConsentHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession` sem cookies, sem cache e sem credenciais guardadas, com teto no corpo da resposta.
struct URLSessionTransport: ConsentHTTPTransport {
    /// O maior corpo que o coletor manda é o banner, bem abaixo disto.
    static let maxResponseBytes = 256 * 1024

    private let session: URLSession

    init(timeout: TimeInterval = 10) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw TrustoConsentError.invalidResponse }
        if http.expectedContentLength > Int64(Self.maxResponseBytes) { throw TrustoConsentError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            // Lê no máximo um byte além do teto: resposta maior nunca vai inteira para a memória.
            if data.count > Self.maxResponseBytes { throw TrustoConsentError.invalidResponse }
        }
        return (data, http)
    }
}

/// Resultado da leitura do armazenamento seguro. `unavailable` é diferente de `notFound`: o
/// Keychain antes do primeiro desbloqueio não diz que o identificador não existe.
enum SecureRead: Equatable {
    case value(String)
    case notFound
    case unavailable
}

/// Armazenamento seguro do identificador do visitante.
protocol ConsentSecureStore: Sendable {
    func read(_ key: String) -> SecureRead
    /// `true` se gravou.
    func write(_ key: String, value: String) -> Bool
}

/// Keychain do aparelho, só neste aparelho e depois do primeiro desbloqueio. Não vai para backup
/// de outro aparelho.
struct KeychainSecureStore: ConsentSecureStore {
    private let service: String

    init(service: String = "io.gettrusto.consent") {
        self.service = service
    }

    func read(_ key: String) -> SecureRead {
        #if canImport(Security)
        var query = base(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else { return .unavailable }
            return .value(value)
        case errSecItemNotFound:
            return .notFound
        default:
            // errSecInteractionNotAllowed (antes do primeiro desbloqueio) e qualquer outra falha.
            return .unavailable
        }
        #else
        return .unavailable
        #endif
    }

    func write(_ key: String, value: String) -> Bool {
        #if canImport(Security)
        let data = Data(value.utf8)
        // Atualiza no lugar: nunca há um instante sem o identificador, como havia com apagar e inserir.
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(base(key) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var attributes = base(key)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
        #else
        return false
        #endif
    }

    private func base(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

/// Arquivos do SDK: decisão, fila e último banner. Em `Application Support`, fora do backup.
protocol ConsentFileStore: Sendable {
    func load(_ name: String) -> Data?
    func save(_ name: String, data: Data)
    func remove(_ name: String)
}

struct DirectoryFileStore: ConsentFileStore {
    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("TrustoConsent", isDirectory: true)
        }
    }

    func load(_ name: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    func save(_ name: String, data: Data) {
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

    func remove(_ name: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
}

/// Relógio injetável.
protocol ConsentClock: Sendable {
    func now() -> Date
}

struct SystemClock: ConsentClock {
    func now() -> Date { Date() }
}

/// Agenda o próximo reenvio. Injetável para o teste conferir o prazo sem esperar.
protocol RetryScheduler: Sendable {
    /// Chama `work` depois de `delay` segundos. O retorno cancela.
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () async -> Void) -> ScheduledRetry
}

final class ScheduledRetry: @unchecked Sendable {
    private let onCancel: () -> Void
    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    func cancel() { onCancel() }
}

/// Tarefas do Swift, enquanto o app roda. Com o app fechado, o próximo `configure` retoma a fila.
struct TaskRetryScheduler: RetryScheduler {
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () async -> Void) -> ScheduledRetry {
        let task = Task.detached(priority: .utility) {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            if Task.isCancelled { return }
            await work()
        }
        return ScheduledRetry { task.cancel() }
    }
}
