import Foundation

/// Pure model-picker logic for Settings. The virtual `pi-os/auto` model is an ordinary catalog
/// entry (GET /models, POST /settings/model on both hosts); here it is offered first as
/// "Auto (recommended)", and its thinking levels are shown as the routing bias they encode.
struct ModelSettingsState {
    static let autoProvider = "pi-os"
    static let autoModel = "auto"
    static let autoTitle = "Auto (recommended)"
    struct Option: Equatable { let value: String; let title: String }

    let catalog: HarnessClient.ModelCatalog
    init(catalog: HarnessClient.ModelCatalog) { self.catalog = catalog }

    static func isAuto(provider: String, modelId: String) -> Bool { provider == autoProvider && modelId == autoModel }
    static func isAuto(_ model: HarnessClient.Model) -> Bool { isAuto(provider: model.provider, modelId: model.id) }
    var hasAuto: Bool { catalog.models.contains(where: Self.isAuto) }

    /// Auto first, then every other provider alphabetically.
    var providers: [Option] {
        let others = Set(catalog.models.map(\.provider)).subtracting(hasAuto ? [Self.autoProvider] : [])
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { Option(value: $0, title: $0) }
        return (hasAuto ? [Option(value: Self.autoProvider, title: Self.autoTitle)] : []) + others
    }
    /// Models of one provider; Auto first, then by name.
    func models(provider: String) -> [HarnessClient.Model] {
        catalog.models.filter { $0.provider == provider }.sorted { lhs, rhs in
            if Self.isAuto(lhs) != Self.isAuto(rhs) { return Self.isAuto(lhs) }
            return lhs.name < rhs.name
        }
    }
    /// Auto is already named in the Provider pop-up; its Model row just says what Auto does.
    static let autoModelTitle = "Chosen per request"
    func title(_ model: HarnessClient.Model) -> String { Self.isAuto(model) ? Self.autoTitle : "\(model.name) · \(model.id)" }
    /// Auto's levels are the routing bias (low/medium/high = speed/balanced/quality).
    func efforts(_ model: HarnessClient.Model) -> [Option] {
        model.thinkingLevels.map { Option(value: $0, title: Self.isAuto(model) ? Self.biasTitle($0) : $0) }
    }
    static func biasTitle(_ level: String) -> String {
        switch level {
        case "low": return "Prefer speed"
        case "medium": return "Balanced"
        case "high": return "Prefer quality"
        default: return level.prefix(1).uppercased() + level.dropFirst()
        }
    }
    static func effortLabel(auto: Bool) -> String { auto ? "Preference" : "Reasoning effort" }

    /// Stored selection, else Auto (Node's default when nothing is stored), else the first provider.
    var initialProvider: String? {
        if let current = catalog.current, catalog.models.contains(where: { $0.provider == current.provider }) { return current.provider }
        return providers.first?.value
    }
    func initialModelIndex(provider: String) -> Int? {
        let list = models(provider: provider)
        if let current = catalog.current, current.provider == provider, let index = list.firstIndex(where: { $0.id == current.modelId }) { return index }
        return list.isEmpty ? nil : 0
    }
    func initialLevel(_ model: HarnessClient.Model) -> String? {
        if let current = catalog.current, current.provider == model.provider, current.modelId == model.id,
           model.thinkingLevels.contains(current.thinkingLevel) { return current.thinkingLevel }
        if Self.isAuto(model), model.thinkingLevels.contains("medium") { return "medium" }
        if let level = catalog.current?.thinkingLevel, model.thinkingLevels.contains(level) { return level }
        return model.thinkingLevels.first
    }
}
