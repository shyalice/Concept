import Foundation

public extension ConceptTextReplacement {
    static let settingsChanged = Notification.Name("Concept.TextReplacementChanged")
    static var isEnabled: Bool {
        get { ConceptSettingsStorage.shared.defaults.bool(forKey: "Concept.TextReplacement.Enabled") }
        set { ConceptSettingsStorage.shared.defaults.set(newValue, forKey: "Concept.TextReplacement.Enabled"); NotificationCenter.default.post(name: settingsChanged, object: nil) }
    }
    static var rules: [ConceptTextReplacementRule] {
        get {
            guard let data = ConceptSettingsStorage.shared.defaults.data(forKey: "Concept.TextReplacement.Rules"), data.count <= 1048576 else { return [] }
            return (try? JSONDecoder().decode([ConceptTextReplacementRule].self, from: data)) ?? []
        }
        set {
            guard newValue.count <= 100, let data = try? JSONEncoder().encode(newValue), data.count <= 1048576 else { return }
            ConceptSettingsStorage.shared.defaults.set(data, forKey: "Concept.TextReplacement.Rules")
            NotificationCenter.default.post(name: settingsChanged, object: nil)
        }
    }

}
