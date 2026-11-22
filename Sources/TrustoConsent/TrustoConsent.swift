import Foundation

/// SDK de consentimento da Trusto para iOS, modo sem tela.
///
/// O aplicativo desenha a própria tela de consentimento; o SDK busca o banner publicado,
/// guarda a decisão no aparelho, avisa quem precisa ligar ou desligar SDKs de terceiros e
/// grava a prova no coletor, com reenvio automático quando o aparelho estiver sem rede.
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
    /// Chave recusada (401) ou rota fora do ar (404) no envio: o documento do app pode voltar
    /// (reconciliação parada, posse caída por um tempo). Espera longa, até o teto da fila.
    static let longRetry: TimeInterval = 3_600

    private static let keyPattern = try! NSRegularExpression(pattern: "^trusto_pk_(test|live)_[A-Za-z0-9_-]{32}$")
    private static let sharedLock = NSLock()
    private static var sharedInstance: TrustoConsent?

    // MARK: Configuração

    /// Configura a instância compartilhada. Chame no início do app; chamar de novo com a mesma
    /// chave e o mesmo endereço devolve a mesma instância.
    @discardableResult
    public static func configure(publishableKey: String, endpoint: URL = defaultEndpoint) throws -> TrustoConsent {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let current = sharedInstance, current.publishableKey == publishableKey, current.endpoint == endpoint {
            return current
        }
        // Valida antes de encerrar a anterior: chave ou endereço inválidos a mantêm em uso.
        guard isValidPublishableKey(publishableKey) else { throw TrustoConsentError.invalidPublishableKey }
        guard isValidEndpoint(endpoint) else { throw TrustoConsentError.invalidEndpoint }
        guard let bundle = Bundle.main.bundleIdentifier, !bundle.isEmpty else { throw TrustoConsentError.missingAppIdentifier }
        // Outra chave ou outro endereço: a anterior para de enviar, de avisar e de gravar antes
        // de a nova ler o disco, para duas instâncias nunca disputarem os mesmos arquivos.
        sharedInstance?.shutdown()
        sharedInstance = nil
        let instance = try TrustoConsent(publishableKey: publishableKey, endpoint: endpoint)
        sharedInstance = instance
        return instance
    }

    /// A instância de `configure`. Antes dele, `TrustoConsentError.notConfigured`.
    public static var shared: TrustoConsent {
        get throws {
            sharedLock.lock()
            defer { sharedLock.unlock() }
            guard let instance = sharedInstance else { throw TrustoConsentError.notConfigured }
            return instance
        }
    }

    /// `true` se a chave tem o formato da chave publicável. Não consulta a rede.
    public static func isValidPublishableKey(_ key: String) -> Bool {
        keyPattern.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
    }

    /// `test` ou `live`, do prefixo da chave.
    static func environment(of key: String) -> String {
        guard let match = keyPattern.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)),
              let range = Range(match.range(at: 1), in: key) else { return "unknown" }
        return String(key[range])
    }

    /// O coletor sem diferença de maiúsculas no esquema e no host, nem barra final.
    static func collectorKey(_ url: URL) -> String {
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? "")\(port)\(path)"
    }

    /// Só `https`. `http` apenas para `localhost` e `127.0.0.1`, em teste no próprio Mac.
    static func isValidEndpoint(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if url.user != nil || url.password != nil { return false }
        if scheme == "https" { return true }
        return scheme == "http" && (host == "localhost" || host == "127.0.0.1")
    }

    private let publishableKey: String
    private let endpoint: URL
    private let appIdentifier: String
    private let transport: ConsentHTTPTransport
    private let secureStore: ConsentSecureStore
    private let files: ConsentFileStore
    private let clock: ConsentClock
    private let scheduler: RetryScheduler
    private let device: DeviceInfo

    private let lock = NSLock()
    /// Disco: uma gravação por vez, cada uma com o estado mais novo no momento em que grava. Uma
    /// fila só para todas as instâncias: a limpeza de escopo de uma nova espera a gravação que a
    /// anterior já tenha começado.
    private static let ioQueue = DispatchQueue(label: "io.gettrusto.consent.io")
    /// Keychain: lido e criado uma vez, fora do lock principal.
    private let visitorLock = NSLock()
    private var visitor: String?

    private var cachedConfig: CachedConfig?
    private var latestVersion: Int?
    private var currentDecision: ConsentDecision?
    private var queue: [QueuedRecord]
    private var flushing = false
    private var closed = false
    private var pendingRetry: (id: UUID, handle: ScheduledRetry)?
    private var observers: [UUID: (DispatchQueue, (ConsentDecision?) -> Void)] = [:]

    init(
        publishableKey: String,
        endpoint: URL = TrustoConsent.defaultEndpoint,
        appIdentifier: String? = Bundle.main.bundleIdentifier,
        transport: ConsentHTTPTransport = URLSessionTransport(),
        secureStore: ConsentSecureStore = KeychainSecureStore(),
        fileStore: ConsentFileStore = DirectoryFileStore(),
        clock: ConsentClock = SystemClock(),
        scheduler: RetryScheduler = TaskRetryScheduler()
    ) throws {
        guard TrustoConsent.isValidPublishableKey(publishableKey) else { throw TrustoConsentError.invalidPublishableKey }
        guard TrustoConsent.isValidEndpoint(endpoint) else { throw TrustoConsentError.invalidEndpoint }
        guard let appIdentifier, !appIdentifier.isEmpty else { throw TrustoConsentError.missingAppIdentifier }
        self.publishableKey = publishableKey
        self.endpoint = endpoint
        self.appIdentifier = appIdentifier
        self.transport = transport
        self.secureStore = secureStore
        self.files = fileStore
        self.clock = clock
        self.scheduler = scheduler
        self.device = DeviceInfo.current()
        // Banner, decisão e fila valem para um ambiente da chave (teste ou produção). Trocar de
        // ambiente na mesma instalação (só acontece em desenvolvimento) descarta o que veio do
        // outro: decidir sobre o banner dele, ou mandar a fila dele com a chave nova, gravaria
        // prova na organização errada. Trocar de coletor descarta só o banner em cache: a fila
        // e a decisão continuam, para uma mudança de endereço numa versão nova nunca apagar
        // prova ainda não enviada. A rotação da chave mantém tudo.
        let scope = Scope(environment: Self.environment(of: publishableKey), collector: Self.collectorKey(endpoint))
        Self.ioQueue.sync {
            let previous = Persisted.decode(Scope.self, fileStore.load(Persisted.scope))
            guard previous != scope else { return }
            if let previous {
                let otherEnvironment = previous.environment != scope.environment
                if otherEnvironment {
                    fileStore.remove(Persisted.decision)
                    fileStore.remove(Persisted.queue)
                }
                if otherEnvironment || previous.collector != scope.collector {
                    fileStore.remove(Persisted.config)
                    fileStore.remove(Persisted.meta)
                }
            }
            fileStore.save(Persisted.scope, data: Persisted.encode(scope))
        }
        // O estado volta do disco: a decisão e os envios pendentes sobrevivem ao app fechar.
        currentDecision = Persisted.decode(ConsentDecision.self, fileStore.load(Persisted.decision))
        queue = Persisted.decode([QueuedRecord].self, fileStore.load(Persisted.queue)) ?? []
        cachedConfig = Persisted.decode(CachedConfig.self, fileStore.load(Persisted.config))
        latestVersion = Persisted.decode(Meta.self, fileStore.load(Persisted.meta))?.latestVersion ?? cachedConfig?.config.version
        // Fila de uma execução anterior: o envio recomeça sozinho, sem esperar o app pedir.
        scheduleNextRetry()
    }

    /// Para de enviar e de avisar. Usado quando `configure` troca de chave ou de endereço.
    func shutdown() {
        let retry: ScheduledRetry? = withLock {
            closed = true
            observers.removeAll()
            let retry = pendingRetry?.handle
            pendingRetry = nil
            return retry
        }
        retry?.cancel()
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
            persistState()
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

    /// A finalidade está concedida agora. Obrigatória, sempre; opcional, só com decisão dentro
    /// do prazo e sobre a versão do banner que está no ar. Sem decisão, com ela vencida ou com
    /// outra versão do banner publicada, nenhuma opcional está até a pessoa decidir de novo.
    public func isGranted(_ categoryKey: String) -> Bool {
        withLock {
            if cachedConfig?.config.categories.contains(where: { $0.key == categoryKey && $0.required }) == true { return true }
            guard let decision = currentDecision else { return false }
            if decision.requiredKeys.contains(categoryKey) { return true }
            if isExpired(decision, now: clock.now()) { return false }
            if let latest = latestVersion, latest != decision.configVersion { return false }
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
            requiredKeys: config.categories.filter(\.required).map(\.key),
            localId: UUID()
        )
        // O identificador do visitante entra só na hora do envio: com o Keychain indisponível
        // (antes do primeiro desbloqueio), o item espera em vez de sair com outro identificador.
        let payload = RecordPayload(
            action: action.rawValue,
            categories: categories,
            configVersion: config.version,
            app: .init(platform: "ios", identifier: appIdentifier, sdkVersion: Self.sdkVersion, os: device.os, device: device.device)
        )
        let item = QueuedRecord(id: UUID(), decisionId: decision.localId, payload: payload, createdAt: now, attempts: 0, nextAttemptAt: now)

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

    /// Envia ao coletor as decisões pendentes, em ordem. O SDK já chama sozinho quando o prazo de
    /// reenvio vence, enquanto o app roda; chamar de novo não tem efeito colateral.
    public func flush() async {
        let start: Bool = withLock {
            if flushing || closed { return false }
            flushing = true
            return true
        }
        guard start else { return }

        while let item = nextDue() {
            let outcome = await send(item)
            if !handle(outcome, for: item) { break }
        }
        withLock { flushing = false }
        scheduleNextRetry()
    }

    /// O primeiro da fila, e só ele, se o prazo dele venceu. Uma decisão mais nova nunca passa à
    /// frente de uma mais velha: para o coletor, o registro mais novo é o que vale.
    private func nextDue() -> QueuedRecord? {
        withLock {
            if closed { return nil }
            let now = clock.now()
            pruneQueue(now: now)
            guard let first = queue.first, first.nextAttemptAt <= now else { return nil }
            return first
        }
    }

    private enum SendOutcome {
        case recorded(consentId: String, expiresAt: Date?)
        case discarded
        case outdated(version: Int?)
        case terminal
        case retry
        case retryLong
    }

    private func send(_ item: QueuedRecord) async -> SendOutcome {
        guard let visitorId = resolveVisitorId() else { return .retry }
        let body = RecordBody(
            visitorId: visitorId,
            action: item.payload.action,
            categories: item.payload.categories,
            configVersion: item.payload.configVersion,
            app: item.payload.app
        )
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/app/records"))
        request.httpMethod = "POST"
        applyHeaders(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Persisted.encodeWire(body)
        guard let (data, response) = try? await transport.send(request) else { return .retry }
        switch response.statusCode {
        case 201:
            // Gravado: sem recibo legível, sai da fila do mesmo jeito.
            guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data) else { return .terminal }
            return .recorded(consentId: receipt.consentId, expiresAt: Persisted.parseDate(receipt.expiresAt))
        case 202:
            return .discarded
        case 409:
            let version = (try? JSONDecoder().decode(Outdated.self, from: data))?.version
            return .outdated(version: version)
        case 400, 403, 413:
            // A decisão em si é recusada: reenviar não muda a resposta.
            return .terminal
        case 408, 429, 500...599:
            return .retry
        default:
            // 401, 404 e o que mais vier: o documento do app pode voltar ao ar. A prova espera.
            return .retryLong
        }
    }

    /// Aplica o resultado. `false` para parar a rodada (sem rede, coletor fora do ar).
    private func handle(_ outcome: SendOutcome, for item: QueuedRecord) -> Bool {
        var changedDecision = false
        var dropConfigFile = false
        let keepGoing: Bool = withLock {
            switch outcome {
            case .retry, .retryLong:
                guard let index = queue.firstIndex(where: { $0.id == item.id }) else { return false }
                queue[index].attempts += 1
                let backoff = min(Self.retryBase * pow(2, Double(queue[index].attempts - 1)), Self.retryCap)
                let delay: TimeInterval
                if case .retryLong = outcome { delay = max(backoff, Self.longRetry) } else { delay = backoff }
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
                dropConfigFile = true
                // Sem a versão nova no corpo, -1 basta para nenhuma decisão guardada casar.
                latestVersion = version ?? -1
                if currentDecision?.localId == item.decisionId { changedDecision = true }
                return true
            case .discarded, .terminal:
                queue.removeAll { $0.id == item.id }
                return true
            }
        }
        if dropConfigFile { Self.ioQueue.sync { if !isClosed { files.remove(Persisted.config) } } }
        persistState()
        if changedDecision { notify() }
        return keepGoing
    }

    /// Agenda a próxima rodada para o prazo do primeiro da fila, enquanto o app roda.
    private func scheduleNextRetry() {
        let (next, previous): (Date?, ScheduledRetry?) = withLock {
            let previous = pendingRetry?.handle
            pendingRetry = nil
            return (closed ? nil : queue.first?.nextAttemptAt, previous)
        }
        previous?.cancel()
        guard let next else { return }
        let delay = max(0, next.timeIntervalSince(clock.now()))
        let id = UUID()
        let scheduled = scheduler.schedule(after: delay) { [weak self] in await self?.fireRetry(id) }
        let stale: ScheduledRetry? = withLock {
            if closed { return scheduled }
            pendingRetry = (id, scheduled)
            return nil
        }
        stale?.cancel()
    }

    /// A rodada agendada: sai da vaga antes de enviar, para o reagendamento ao fim do `flush`
    /// não cancelar a própria tarefa no meio do envio.
    private func fireRetry(_ id: UUID) async {
        let mine: Bool = withLock {
            guard pendingRetry?.id == id else { return false }
            pendingRetry = nil
            return true
        }
        if mine { await flush() }
    }

    // MARK: Observadores

    /// Chamado agora com a decisão atual e depois a cada mudança, na fila indicada.
    @discardableResult
    public func observe(on queue: DispatchQueue = .main, _ handler: @escaping (ConsentDecision?) -> Void) -> ConsentObservation {
        let id = UUID()
        let current: ConsentDecision? = withLock {
            if !closed { observers[id] = (queue, handler) }
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

    /// Identificador aleatório do visitante neste aparelho, criado no primeiro uso. `nil` com o
    /// Keychain indisponível: nunca um identificador novo só porque a leitura falhou.
    func resolveVisitorId() -> String? {
        visitorLock.lock()
        defer { visitorLock.unlock() }
        if let visitor { return visitor }
        switch secureStore.read(Persisted.visitorKey) {
        case .value(let existing) where UUID(uuidString: existing) != nil:
            visitor = existing.lowercased()
            return visitor
        case .notFound, .value:
            // Ausente (ou ilegível como UUID): cria. Só vale depois de gravado.
            let created = UUID().uuidString.lowercased()
            guard secureStore.write(Persisted.visitorKey, value: created) else { return nil }
            visitor = created
            return created
        case .unavailable:
            return nil
        }
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

    /// Grava o estado na fila serial de disco. O retrato é tirado dentro dela: a última gravação
    /// é sempre a do estado mais novo, e duas gravações não terminam na ordem inversa.
    private func persistState() {
        Self.ioQueue.sync {
            // Encerrada, a instância não grava: a que a substituiu é a dona dos arquivos.
            let (stopped, decision, pending, latest, config) = withLock { (closed, currentDecision, queue, latestVersion, cachedConfig) }
            if stopped { return }
            if let decision { files.save(Persisted.decision, data: Persisted.encode(decision)) } else { files.remove(Persisted.decision) }
            files.save(Persisted.queue, data: Persisted.encode(pending))
            files.save(Persisted.meta, data: Persisted.encode(Meta(latestVersion: latest)))
            if let config { files.save(Persisted.config, data: Persisted.encode(config)) }
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Pendentes na fila. Para teste e diagnóstico.
    var pendingCount: Int { withLock { queue.count } }

    var isClosed: Bool { withLock { closed } }

    /// Só para teste: esquece a instância compartilhada.
    static func resetSharedForTesting() {
        sharedLock.lock()
        sharedInstance?.shutdown()
        sharedInstance = nil
        sharedLock.unlock()
    }
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

/// Ambiente da chave e coletor dos arquivos guardados. Nunca a chave inteira: a rotação não
/// muda o escopo.
struct Scope: Codable, Equatable {
    let environment: String
    let collector: String
}

/// A decisão sem o identificador do visitante, que entra na hora do envio.
struct RecordPayload: Codable, Equatable {
    let action: String
    let categories: [String: Bool]
    let configVersion: Int
    let app: RecordBody.App
}

struct QueuedRecord: Codable, Equatable {
    let id: UUID
    let decisionId: UUID
    let payload: RecordPayload
    let createdAt: Date
    var attempts: Int
    var nextAttemptAt: Date
}

/// O corpo de `POST /v1/app/records`, sem nenhum campo além dos do contrato.
struct RecordBody: Encodable {
    struct App: Codable, Equatable {
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
    static let scope = "scope.json"
    static let visitorKey = "visitorId"

    /// Versão do formato dos arquivos. Arquivo de outra versão é descartado (o SDK que o
    /// escreveu é mais novo ou mais velho que este); sem versão, também.
    static let formatVersion = 1

    private struct Envelope<T: Codable>: Codable {
        let v: Int
        let value: T
    }

    private struct VersionOnly: Decodable {
        let v: Int
    }

    static func encode<T: Codable>(_ value: T) -> Data {
        (try? encoder().encode(Envelope(v: formatVersion, value: value))) ?? Data()
    }

    static func decode<T: Codable>(_ type: T.Type, _ data: Data?) -> T? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let version = try? decoder.decode(VersionOnly.self, from: data), version.v == formatVersion else { return nil }
        return try? decoder.decode(Envelope<T>.self, from: data).value
    }

    /// O corpo enviado ao coletor: o contrato puro, sem envelope.
    static func encodeWire<T: Encodable>(_ value: T) -> Data {
        (try? encoder().encode(value)) ?? Data()
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    static func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }
}
