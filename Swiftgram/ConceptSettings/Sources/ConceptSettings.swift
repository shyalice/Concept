import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramUIPreferences

extension ApplicationSpecificSharedDataKeys {
    public static let conceptSettings = applicationSpecificPreferencesKey(900)
}

public struct ConceptSettings: Codable, Equatable {
    public let hideAllSecretsOnDeviceShake: Bool
    public let hideAllSecretsOnManualAppLock: Bool
    
    public static var defaultSettings: ConceptSettings {
        return ConceptSettings(
            hideAllSecretsOnDeviceShake: true,
            hideAllSecretsOnManualAppLock: true
        )
    }
    
    public init(hideAllSecretsOnDeviceShake: Bool, hideAllSecretsOnManualAppLock: Bool) {
        self.hideAllSecretsOnDeviceShake = hideAllSecretsOnDeviceShake
        self.hideAllSecretsOnManualAppLock = hideAllSecretsOnManualAppLock
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)
        self.hideAllSecretsOnDeviceShake = try container.decodeIfPresent(Bool.self, forKey: "hideAllSecretsOnDeviceShake") ?? true
        self.hideAllSecretsOnManualAppLock = try container.decodeIfPresent(Bool.self, forKey: "hideAllSecretsOnManualAppLock") ?? true
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)
        try container.encode(self.hideAllSecretsOnDeviceShake, forKey: "hideAllSecretsOnDeviceShake")
        try container.encode(self.hideAllSecretsOnManualAppLock, forKey: "hideAllSecretsOnManualAppLock")
    }
    
    public init(_ entry: PreferencesEntry?) {
        self = entry?.get(ConceptSettings.self) ?? .defaultSettings
    }
    
    public func withUpdated(
        hideAllSecretsOnDeviceShake: Bool? = nil,
        hideAllSecretsOnManualAppLock: Bool? = nil
    ) -> ConceptSettings {
        return ConceptSettings(
            hideAllSecretsOnDeviceShake: hideAllSecretsOnDeviceShake ?? self.hideAllSecretsOnDeviceShake,
            hideAllSecretsOnManualAppLock: hideAllSecretsOnManualAppLock ?? self.hideAllSecretsOnManualAppLock
        )
    }
}

public func updateConceptSettings(_ accountManager: AccountManager<TelegramAccountManagerTypes>, _ f: @escaping (ConceptSettings) -> ConceptSettings) -> Signal<Void, NoError> {
    return accountManager.transaction { transaction -> Void in
        transaction.updateSharedData(ApplicationSpecificSharedDataKeys.conceptSettings, { current in
            let updated = f(ConceptSettings(current))
            return PreferencesEntry(updated)
        })
    }
}
