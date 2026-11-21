import Foundation
@testable import TrustoConsent

let validKey = "trusto_pk_test_" + String(repeating: "A", count: 32)
let bundleId = "br.com.acme.app"

/// Respostas programadas por caminho, e o registro de cada requisição.
final class FakeTransport: ConsentHTTPTransport, @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: Data
        static func json(_ status: Int, _ object: Any) -> Reply {
            Reply(status: status, body: try! JSONSerialization.data(withJSONObject: object))
        }
        static let offline = Reply(status: -1, body: Data())
    }

    private let lock = NSLock()
    private var replies: [String: [Reply]] = [:]
    private var fallback: [String: Reply] = [:]
    private(set) var requests: [URLRequest] = []

    /// Respostas em ordem para o caminho; a última se repete.
    func on(_ path: String, _ sequence: Reply...) {
        lock.lock()
        replies[path] = Array(sequence.dropLast())
        fallback[path] = sequence.last
        lock.unlock()
    }

    func requests(to path: String) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter { $0.url?.path == path }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        requests.append(request)
        let path = request.url?.path ?? ""
        let reply: Reply?
        if var queued = replies[path], !queued.isEmpty {
            reply = queued.removeFirst()
            replies[path] = queued
        } else {
            reply = fallback[path]
        }
        lock.unlock()
        guard let reply, reply.status > 0 else { throw URLError(.notConnectedToInternet) }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (reply.body, response)
    }
}

final class MemorySecureStore: ConsentSecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    /// Simula o Keychain antes do primeiro desbloqueio.
    var unavailable = false
    private(set) var writes = 0
    func read(_ key: String) -> SecureRead {
        lock.lock(); defer { lock.unlock() }
        if unavailable { return .unavailable }
        return values[key].map(SecureRead.value) ?? .notFound
    }
    func write(_ key: String, value: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if unavailable { return false }
        writes += 1
        values[key] = value
        return true
    }
    func value(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
}

/// Guarda o que foi agendado, sem rodar: o teste decide quando enviar.
final class FakeScheduler: RetryScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var delays: [TimeInterval] = []
    private(set) var cancelled = 0
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () async -> Void) -> ScheduledRetry {
        lock.lock(); delays.append(delay); lock.unlock()
        return ScheduledRetry { [weak self] in self?.lock.lock(); self?.cancelled += 1; self?.lock.unlock() }
    }
    var last: TimeInterval? { lock.lock(); defer { lock.unlock() }; return delays.last }
}

/// Disco em memória, compartilhável entre instâncias para simular o app reaberto.
final class MemoryFileStore: ConsentFileStore, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var files: [String: Data] = [:]
    func load(_ name: String) -> Data? { lock.lock(); defer { lock.unlock() }; return files[name] }
    func save(_ name: String, data: Data) { lock.lock(); files[name] = data; lock.unlock() }
    func remove(_ name: String) { lock.lock(); files[name] = nil; lock.unlock() }
}

final class ManualClock: ConsentClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
}

func configJSON(version: Int = 2, expiryDays: Int = 365) -> [String: Any] {
    [
        "version": version,
        "bannerPosition": "bottom",
        "bannerStyle": ["primaryColor": "#B45309", "textColor": "#292524", "backgroundColor": "#FFFFFF", "borderRadius": 12],
        "privacyPolicyUrl": "https://acme.com.br/privacidade",
        "categories": [
            ["key": "necessary", "name": "N", "description": "", "required": true, "defaultEnabled": true, "cookies": []],
            ["key": "analytics", "name": "A", "description": "", "required": false, "defaultEnabled": false, "cookies": []],
            ["key": "marketing", "name": "M", "description": "", "required": false, "defaultEnabled": false, "cookies": []],
        ],
        "consentExpiryDays": expiryDays,
        "blockBeforeConsent": true,
    ]
}

let receiptJSON: [String: Any] = ["consentId": "c0ffee00-0000-4000-8000-000000000000", "expiresAt": "2027-10-16T00:00:00.000Z"]

struct Harness {
    let transport = FakeTransport()
    let secure = MemorySecureStore()
    let files = MemoryFileStore()
    let clock = ManualClock()
    let scheduler = FakeScheduler()

    func make() throws -> TrustoConsent {
        try TrustoConsent(
            publishableKey: validKey,
            endpoint: URL(string: "https://consent.example")!,
            appIdentifier: bundleId,
            transport: transport,
            secureStore: secure,
            fileStore: files,
            clock: clock,
            scheduler: scheduler
        )
    }
}
