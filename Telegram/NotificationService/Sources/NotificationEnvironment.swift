import SGAppGroupIdentifier // MARK: Swiftgram
import Foundation
import PasscodeCore
import UserNotifications
import SwiftSignalKit
import TelegramCore
import BuildConfig
import OpenSSLEncryptionProvider
import TelegramUIPreferences
import WebPBinding
import LottieBinding
import GZip
import UIKit
import Intents
import PersistentStringHash
import CallKit
import AppLockState
import NotificationsPresentationData
import RangeSet
import ConvertOpusToAAC
import CoreServices
import ImageIO
import UniformTypeIdentifiers

private var installedSharedLogger = false

func setupSharedLogger(rootPath: String, path: String) {
    if !installedSharedLogger {
        installedSharedLogger = true
        Logger.setSharedLogger(Logger(rootPath: rootPath, basePath: path))
    }
}

let accountAuxiliaryMethods = AccountAuxiliaryMethods(fetchResource: { account, resource, ranges, _ in
    return nil
}, fetchResourceMediaReferenceHash: { resource in
    return .single(nil)
}, prepareSecretThumbnailData: { _ in
    return nil
}, backgroundUpload: { _, _, _ in
    return .single(nil)
})

func rootPathForBasePath(_ appGroupPath: String) -> String {
    return appGroupPath + "/telegram-data"
}

