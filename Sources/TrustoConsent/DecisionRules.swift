import Foundation

/// As mesmas regras que o coletor aplica (`checkDecision`): todas as categorias do banner e só
/// elas, obrigatória sempre concedida, e a ação descrevendo as escolhas. Montar a decisão aqui
/// evita mandar ao coletor algo que ele recusaria.
enum DecisionRules {
    enum Intent {
        case acceptAll
        case rejectAll
        case revoke
        case custom([String: Bool])
    }

    static func build(_ intent: Intent, config: ConsentConfig) throws -> (ConsentAction, [String: Bool]) {
        let optional = config.categories.filter { !$0.required }
        var categories: [String: Bool] = [:]
        switch intent {
        case .acceptAll:
            for category in config.categories { categories[category.key] = true }
            return (.acceptAll, categories)
        case .rejectAll, .revoke:
            for category in config.categories { categories[category.key] = category.required }
            return (isRevoke(intent) ? .revoke : .rejectAll, categories)
        case .custom(let chosen):
            let known = Set(config.categories.map(\.key))
            if let unknown = chosen.keys.sorted().first(where: { !known.contains($0) }) {
                throw TrustoConsentError.unknownCategory(unknown)
            }
            for category in config.categories {
                if category.required {
                    if chosen[category.key] == false { throw TrustoConsentError.requiredCategoryRefused(category.key) }
                    categories[category.key] = true
                } else {
                    // Finalidade não informada não é concedida: consentimento é ato positivo.
                    categories[category.key] = chosen[category.key] ?? false
                }
            }
            let granted = optional.filter { categories[$0.key] == true }.count
            let action: ConsentAction = granted == optional.count ? .acceptAll : granted == 0 ? .rejectAll : .partial
            return (action, categories)
        }
    }

    /// Confere uma decisão contra o banner, como o coletor. `true` se ele a aceitaria.
    static func isValid(action: ConsentAction, categories: [String: Bool], config: ConsentConfig) -> Bool {
        let expected = config.categories.map(\.key)
        guard categories.count == expected.count, expected.allSatisfy({ categories[$0] != nil }) else { return false }
        if config.categories.contains(where: { $0.required && categories[$0.key] != true }) { return false }
        let optional = config.categories.filter { !$0.required }
        let granted = optional.filter { categories[$0.key] == true }.count
        switch action {
        case .acceptAll: return granted == optional.count
        case .rejectAll, .revoke: return granted == 0
        case .partial: return granted > 0 && granted < optional.count
        }
    }

    private static func isRevoke(_ intent: Intent) -> Bool {
        if case .revoke = intent { return true }
        return false
    }
}
