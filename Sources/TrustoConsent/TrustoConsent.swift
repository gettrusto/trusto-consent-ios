import Foundation

/// SDK de consentimento da Trusto para iOS, modo sem tela (ADR 0135, M2).
///
/// O aplicativo desenha a própria tela de consentimento; o SDK busca o banner publicado,
/// guarda a decisão no aparelho, avisa quem precisa ligar ou desligar SDKs de terceiros e
/// grava a prova no coletor, com reenvio quando o aparelho estiver sem rede.
public final class TrustoConsent: @unchecked Sendable {
    public static let sdkVersion = "0.1.0"
    public static let defaultEndpoint = URL(string: "https://consent.gettrusto.io")!

    /// Prazo do banner em cache antes de buscar de novo.
    static let configTTL: TimeInterval = 60
    /// Fila: no máximo isto de decisões pendentes, e nenhuma mais velha que 30 dias.
    static let maxQueue = 50
    static let maxQueueAge: TimeInterval = 30 * 86_400
    /// Reenvio: 5 s, 10 s, 20 s... até 1 h.
    static let retryBase: TimeInterval = 5
    static let retryCap: TimeInterval = 3_600

    private static let keyPattern = try! NSRegularExpression(pattern: "^trusto_pk_(test|live)_[A-Za-z0-9_-]{32}$")
    private static let sharedLock = NSLock()
    private static var sharedInstance: TrustoConsent?

    // MARK: Configuração

    /// Configura a instância compartilhada. Chame uma vez, no início do app.
    @discardableResult
    public static func configure(publishableKey: String, endpoint: URL = defaultEndpoint) throws -> TrustoConsent {
        let instance = try TrustoConsent(publishableKey: publishableKey, endpoint: endpoint)
        sharedLock.lock()
        sharedInstance = instance
        sharedLock.unlock()
        return instance
    }

    /// A instância de `configure`. Antes dele, um erro de programação.
    public static var shared: TrustoConsent {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        guard let instance = sharedInstance else {
            preconditionFailure("TrustoConsent.configure(publishableKey:) precisa ser chamado antes de TrustoConsent.shared")
        }
        return instance
    }

    /// `true` se a chave tem o formato da chave publicável. Não consulta a rede.
    public static func isValidPublishableKey(_ key: String) -> Bool {
        keyPattern.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
    }

    private let publishableKey: String
    private let endpoint: URL
    private let appIdentifier: String
    private let transport: ConsentHTTPTransport
    private let secureStore: ConsentSecureStore
    private let files: ConsentFileStore
    private let clock: ConsentClock
    private let device: DeviceInfo

    private let lock = NSLock()
    private var cachedConfig: CachedConfig?
    private var latestVersion: Int?
    private var currentDecision: ConsentDecision?
    private var queue: [QueuedRecord]
    private var flushing = false
    private var observers: [UUID: (DispatchQueue, (ConsentDecision?) -> Void)] = [:]

    public init(
        publishableKey: String,
        endpoint: URL = TrustoConsent.defaultEndpoint,
        appIdentifier: String? = Bundle.main.bundleIdentifier,
        transport: ConsentHTTPTransport = URLSessionTransport(),
        secureStore: ConsentSecureStore = KeychainSecureStore(),
        fileStore: ConsentFileStore = DirectoryFileStore(),
        clock: ConsentClock = SystemClock()
    ) throws {
        guard TrustoConsent.isValidPublishableKey(publishableKey) else { throw TrustoConsentError.invalidPublishableKey }
        guard let appIdentifier, !appIdentifier.isEmpty else { throw TrustoConsentError.missingAppIdentifier }
        self.publishableKey = publishableKey
        self.endpoint = endpoint
        self.appIdentifier = appIdentifier
        self.transport = transport
        self.secureStore = secureStore
        self.files = fileStore
        self.clock = clock
        self.device = DeviceInfo.current()
        // O estado volta do disco: a decisão e os envios pendentes sobrevivem ao app fechar.
        currentDecision = Persisted.decode(ConsentDecision.self, fileStore.load(Persisted.decision))
        queue = Persisted.decode([QueuedRecord].self, fileStore.load(Persisted.queue)) ?? []
        cachedConfig = Persisted.decode(CachedConfig.self, fileStore.load(Persisted.config))
        latestVersion = Persisted.decode(Meta.self, fileStore.load(Persisted.meta))?.latestVersion ?? cachedConfig?.config.version
    }

    // MARK: Banner

    /// O banner publicado do aplicativo. Usa o cache de 60 s; sem rede ou com o coletor fora do
    /// ar, o último banner guardado.
    public func loadConfig() async throws -> ConsentConfig {
        let now = clock.now()
        if let cached = withLock({ cachedConfig }), now.timeIntervalSince(cached.fetchedAt) < Self.configTTL, now >= cached.fetchedAt {
            return cached.config
        }
        do {
            return try await fetchConfig(now: now)
        } catch let error as TrustoConsentError where error == .rateLimited || error == .unavailable {
            if let stale = withLock({ cachedConfig }) { return stale.config }
            throw error
        }
    }

    private func fetchConfig(now: Date) async throws -> ConsentConfig {
        var components = URLComponents(url: endpoint.appendingPathComponent("v1/app/config"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "platform", value: "ios"), URLQueryItem(name: "app", value: appIdentifier)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        applyHeaders(&request)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw TrustoConsentError.unavailable
        }
        switch response.statusCode {
        case 200:
            guard let config = try? JSONDecoder().decode(ConsentConfig.self, from: data) else { throw TrustoConsentError.invalidResponse }
            let cached = CachedConfig(config: config, fetchedAt: now)
            withLock {
                cachedConfig = cached
                latestVersion = config.version
            }
            files.save(Persisted.config, data: Persisted.encode(cached))
            files.save(Persisted.meta, data: Persisted.encode(Meta(latestVersion: config.version)))
            return config
        case 401: throw TrustoConsentError.invalidAppKey
        case 403: throw TrustoConsentError.appMismatch
        case 404: throw TrustoConsentError.consentNotEnabled
        case 429: throw TrustoConsentError.rateLimited
        default:
            if response.statusCode >= 500 { throw TrustoConsentError.unavailable }
            throw TrustoConsentError.invalidResponse
        }
    }

    // MARK: Decisão

    /// A decisão atual neste aparelho, ou `nil`.
    public var decision: ConsentDecision? { withLock { currentDecision } }

    /// `true` quando é preciso perguntar: sem decisão, decisão de outra versão do banner ou vencida.
    public var needsConsent: Bool {
        withLock {
            guard let decision = currentDecision else { return true }
            if isExpired(decision, now: clock.now()) { return true }
            if let latest = latestVersion, latest != decision.configVersion { return true }
            return false
        }
    }

    /// A finalidade está concedida pela decisão atual e dentro do prazo. Sem decisão, nada está.
    public func isGranted(_ categoryKey: String) -> Bool {
        withLock {
            guard let decision = currentDecision, !isExpired(decision, now: clock.now()) else { return false }
            return decision.categories[categoryKey] == true
        }
    }

    /// Aceita todas as finalidades do banner.
    @discardableResult
    public func acceptAll() async throws -> ConsentDecision { try await decide(.acceptAll) }

    /// Recusa todas as finalidades opcionais. As obrigatórias seguem concedidas.
    @discardableResult
    public func rejectAll() async throws -> ConsentDecision { try await decide(.rejectAll) }

    /// Grava as escolhas da pessoa. Finalidade opcional não informada fica recusada; recusar uma
    /// obrigatória ou citar uma que não existe no banner é erro.
    @discardableResult
    public func save(categories: [String: Bool]) async throws -> ConsentDecision { try await decide(.custom(categories)) }

    /// Revoga o consentimento: só as finalidades obrigatórias ficam, e a revogação também é gravada como prova.
    @discardableResult
    public func revoke() async throws -> ConsentDecision { try await decide(.revoke) }

    private func decide(_ intent: DecisionRules.Intent) async throws -> ConsentDecision {
        let config = try await loadConfig()
        let (action, categories) = try DecisionRules.build(intent, config: config)
        let now = clock.now()
        let decision = ConsentDecision(
            action: action,
            categories: categories,
            configVersion: config.version,
            decidedAt: now,
            consentId: nil,
            expiresAt: nil,
            consentExpiryDays: config.consentExpiryDays,
            localId: UUID()
        )
        let body = RecordBody(
            visitorId: visitorId(),
            action: action.rawValue,
            categories: categories,
            configVersion: config.version,
            app: .init(platform: "ios", identifier: appIdentifier, sdkVersion: Self.sdkVersion, os: device.os, device: device.device)
        )
        let item = QueuedRecord(id: UUID(), decisionId: decision.localId, body: Persisted.encode(body), createdAt: now, attempts: 0, nextAttemptAt: now)

        // Primeiro no aparelho: o app respeita a escolha na hora, com ou sem rede.
        withLock {
            currentDecision = decision
            latestVersion = config.version
            queue.append(item)
            pruneQueue(now: now)
        }
        persistState()
        notify()
        await flush()
        return self.decision ?? decision
    }

    // MARK: Envio

    /// Envia ao coletor as decisões pendentes cujo prazo de reenvio venceu.
    public func flush() async {
        let start: Bool = withLock {
            if flushing { return false }
            flushing = true
            return true
        }
        guard start else { return }
        defer { withLock { flushing = false } }

        while let item = nextDue() {
            let outcome = await send(item)
            if !handle(outcome, for: item) { break }
        }
    }

    private func nextDue() -> QueuedRecord? {
        withLock {
            let now = clock.now()
            pruneQueue(now: now)
            return queue.first(where: { $0.nextAttemptAt <= now })
        }
    }

    private enum SendOutcome {
        case recorded(consentId: String, expiresAt: Date?)
        case discarded
        case outdated(version: Int?)
        case terminal
        case retry
    }

    private func send(_ item: QueuedRecord) async -> SendOutcome {
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/app/records"))
        request.httpMethod = "POST"
        applyHeaders(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = item.body
        guard let (data, response) = try? await transport.send(request) else { return .retry }
        switch response.statusCode {
        case 201:
            guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data) else { return .terminal }
            return .recorded(consentId: receipt.consentId, expiresAt: Persisted.parseDate(receipt.expiresAt))
        case 202:
            return .discarded
        case 409:
            let version = (try? JSONDecoder().decode(Outdated.self, from: data))?.version
            return .outdated(version: version)
        case 408, 429:
            return .retry
        case 500...599:
            return .retry
        default:
            return .terminal
        }
    }

    /// Aplica o resultado. `false` para parar a rodada (sem rede, coletor fora do ar).
    private func handle(_ outcome: SendOutcome, for item: QueuedRecord) -> Bool {
        var changedDecision = false
        let keepGoing: Bool = withLock {
            switch outcome {
            case .retry:
                guard let index = queue.firstIndex(where: { $0.id == item.id }) else { return false }
                queue[index].attempts += 1
                let delay = min(Self.retryBase * pow(2, Double(queue[index].attempts - 1)), Self.retryCap)
                queue[index].nextAttemptAt = clock.now().addingTimeInterval(delay)
                return false
            case .recorded(let consentId, let expiresAt):
                queue.removeAll { $0.id == item.id }
                if currentDecision?.localId == item.decisionId {
                    currentDecision?.consentId = consentId
                    currentDecision?.expiresAt = expiresAt
                    changedDecision = true
                }
                return true
            case .outdated(let version):
                // O banner mudou: a decisão foi sobre outro banner. Volta a perguntar.
                queue.removeAll { $0.id == item.id }
                cachedConfig = nil
                // Sem a versão nova no corpo, -1 basta para nenhuma decisão guardada casar.
                latestVersion = version ?? -1
                if currentDecision?.localId == item.decisionId { changedDecision = true }
                return true
            case .discarded, .terminal:
                queue.removeAll { $0.id == item.id }
                return true
            }
        }
        if case .outdated = outcome { files.remove(Persisted.config) }
        persistState()
        if changedDecision { notify() }
        return keepGoing
    }

    // MARK: Observadores

    /// Chamado agora com a decisão atual e depois a cada mudança, na fila indicada.
    @discardableResult
    public func observe(on queue: DispatchQueue = .main, _ handler: @escaping (ConsentDecision?) -> Void) -> ConsentObservation {
        let id = UUID()
        let current: ConsentDecision? = withLock {
            observers[id] = (queue, handler)
            return currentDecision
        }
        queue.async { handler(current) }
        return ConsentObservation { [weak self] in
            self?.withLock { _ = self?.observers.removeValue(forKey: id) }
        }
    }

    private func notify() {
        let (decision, targets) = withLock { (currentDecision, Array(observers.values)) }
        for (queue, handler) in targets { queue.async { handler(decision) } }
    }

    // MARK: Internos

    /// Identificador aleatório do visitante neste aparelho, criado no primeiro uso.
    func visitorId() -> String {
        if let existing = secureStore.read(Persisted.visitorKey), UUID(uuidString: existing) != nil {
            return existing.lowercased()
        }
        let created = UUID().uuidString.lowercased()
        secureStore.write(Persisted.visitorKey, value: created)
        return created
    }

    private func applyHeaders(_ request: inout URLRequest) {
        request.setValue("Bearer \(publishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TrustoConsentSDK/\(Self.sdkVersion) (iOS)", forHTTPHeaderField: "User-Agent")
    }

    private func isExpired(_ decision: ConsentDecision, now: Date) -> Bool {
        if let expiresAt = decision.expiresAt { return expiresAt <= now }
        return decision.decidedAt.addingTimeInterval(TimeInterval(decision.consentExpiryDays) * 86_400) <= now
    }

    /// Chamado com o lock.
    private func pruneQueue(now: Date) {
        queue.removeAll { now.timeIntervalSince($0.createdAt) > Self.maxQueueAge }
        if queue.count > Self.maxQueue { queue.removeFirst(queue.count - Self.maxQueue) }
    }

    private func persistState() {
        let (decision, pending, latest) = withLock { (currentDecision, queue, latestVersion) }
        if let decision { files.save(Persisted.decision, data: Persisted.encode(decision)) } else { files.remove(Persisted.decision) }
        files.save(Persisted.queue, data: Persisted.encode(pending))
        files.save(Persisted.meta, data: Persisted.encode(Meta(latestVersion: latest)))
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Pendentes na fila. Para teste e diagnóstico.
    var pendingCount: Int { withLock { queue.count } }
}

/// Cancela a observação de `observe`.
public final class ConsentObservation: @unchecked Sendable {
    private let onCancel: () -> Void
    private var cancelled = false
    private let lock = NSLock()

    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }

    public func cancel() {
        lock.lock()
        let run = !cancelled
        cancelled = true
        lock.unlock()
        if run { onCancel() }
    }
}

// MARK: Formatos

struct CachedConfig: Codable {
    let config: ConsentConfig
    let fetchedAt: Date
}

struct Meta: Codable {
    let latestVersion: Int?
}

struct QueuedRecord: Codable, Equatable {
    let id: UUID
    let decisionId: UUID
    let body: Data
    let createdAt: Date
    var attempts: Int
    var nextAttemptAt: Date
}

/// O corpo de `POST /v1/app/records`, sem nenhum campo além dos do contrato.
struct RecordBody: Encodable {
    struct App: Encodable {
        let platform: String
        let identifier: String
        let sdkVersion: String
        let os: String
        let device: String?
    }

    let visitorId: String
    let action: String
    let categories: [String: Bool]
    let configVersion: Int
    let app: App
}

struct Receipt: Decodable {
    let consentId: String
    let expiresAt: String
}

struct Outdated: Decodable {
    let version: Int
}

enum Persisted {
    static let decision = "decision.json"
    static let queue = "queue.json"
    static let config = "config.json"
    static let meta = "meta.json"
    static let visitorKey = "visitorId"

    static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return (try? encoder.encode(value)) ?? Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(type, from: data)
    }

    static func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }
}
