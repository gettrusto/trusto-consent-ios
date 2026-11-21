import Foundation

/// Ação de uma decisão, como o coletor a grava.
public enum ConsentAction: String, Codable, Sendable, CaseIterable {
    case acceptAll = "accept_all"
    case rejectAll = "reject_all"
    case partial
    case revoke
}

/// Um cookie ou armazenamento declarado numa categoria do banner.
public struct ConsentCookie: Codable, Equatable, Sendable {
    public let name: String
    public let provider: String
    public let purpose: String
    public let expiry: String
    public let type: String
}

/// Uma finalidade do banner publicado.
public struct ConsentCategory: Codable, Equatable, Sendable {
    public let key: String
    public let name: String
    public let description: String
    /// Obrigatória: sempre concedida, não pode ser recusada.
    public let required: Bool
    public let defaultEnabled: Bool
    public let cookies: [ConsentCookie]
}

/// Aparência do banner publicado, para quem desenha a própria tela seguir a da empresa.
public struct ConsentBannerStyle: Codable, Equatable, Sendable {
    public let primaryColor: String
    public let textColor: String
    public let backgroundColor: String
    public let borderRadius: Int
}

/// O banner publicado do aplicativo (`GET /v1/app/config`).
public struct ConsentConfig: Codable, Equatable, Sendable {
    public let version: Int
    public let bannerPosition: String
    public let bannerStyle: ConsentBannerStyle
    public let privacyPolicyUrl: String
    public let categories: [ConsentCategory]
    public let consentExpiryDays: Int
    public let blockBeforeConsent: Bool
    /// Canal do titular da organização, quando publicado.
    public let holderUrl: String?
}

/// A decisão atual neste aparelho.
public struct ConsentDecision: Codable, Equatable, Sendable {
    public let action: ConsentAction
    /// Todas as categorias do banner, na ordem dele.
    public let categories: [String: Bool]
    /// Versão do banner que a pessoa viu.
    public let configVersion: Int
    public let decidedAt: Date
    /// Recibo do coletor, quando a decisão já foi gravada.
    public internal(set) var consentId: String?
    public internal(set) var expiresAt: Date?
    /// Prazo do banner no momento da decisão, para o vencimento antes do recibo.
    let consentExpiryDays: Int
    /// Identificador local, que liga a decisão ao item da fila.
    let localId: UUID

    /// Já gravada pelo coletor.
    public var isRecorded: Bool { consentId != nil }
}

/// Erros do SDK.
public enum TrustoConsentError: Error, Equatable, Sendable {
    /// `configure` não foi chamado.
    case notConfigured
    /// A chave não tem o formato `trusto_pk_{test|live}_…`.
    case invalidPublishableKey
    /// O identificador do aplicativo (bundle id) não está disponível.
    case missingAppIdentifier
    /// O coletor recusou a chave: ausente, retirada, vencida ou de outro ambiente.
    case invalidAppKey
    /// A chave é de outro aplicativo ou de outra plataforma.
    case appMismatch
    /// Sem banner publicado para o aplicativo.
    case consentNotEnabled
    case rateLimited
    /// O coletor não respondeu e não há configuração guardada.
    case unavailable
    case invalidResponse
    /// Categoria que não existe no banner.
    case unknownCategory(String)
    /// Tentativa de recusar uma categoria obrigatória.
    case requiredCategoryRefused(String)
}
