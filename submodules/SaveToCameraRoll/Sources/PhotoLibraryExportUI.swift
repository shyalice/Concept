import Foundation
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramPresentationData
import PresentationDataUtils
import AlertComponent
import ComponentFlow
import SGStrings

/// Only full media delivered to this account are eligible. Locked previews are
/// never treated as downloadable originals.
public func purchasedPhotoLibraryMediaReferences(message: EngineMessage, mediaIndex: Int? = nil) -> [AnyMediaReference] {
    guard let paidContent = message._asMessage().paidContent else { return [] }
    let reference = MessageReference(message._asMessage())
    let media: [TelegramExtendedMedia]
    if let mediaIndex {
        guard paidContent.extendedMedia.indices.contains(mediaIndex) else { return [] }
        media = [paidContent.extendedMedia[mediaIndex]]
    } else {
        media = paidContent.extendedMedia
    }
    return media.compactMap { extended -> AnyMediaReference? in
        guard case let .full(media) = extended else { return nil }
        if let image = media as? TelegramMediaImage, largestImageRepresentation(image.representations) != nil {
            return ImageMediaReference.message(message: reference, media: image).abstract
        }
        if let file = media as? TelegramMediaFile, file.isVideo || file.mimeType.hasPrefix("video/") {
            return FileMediaReference.message(message: reference, media: file).abstract
        }
        return nil
    }
}

/// Photos and videos that this account can actually fetch, including uncached
/// resources. Copy protection follows Concept's existing bypass setting.
public func photoLibraryMediaReferences(message: EngineMessage, mediaIndex: Int? = nil, peerIsCopyProtected: Bool = false) -> [AnyMediaReference] {
    let rawMessage = message._asMessage()
    guard !rawMessage.containsSecretMedia else { return [] }
    if rawMessage.paidContent != nil {
        return purchasedPhotoLibraryMediaReferences(message: message, mediaIndex: mediaIndex)
    }
    guard MiscSettingsManager.shared.shouldBypassCopyProtection || (!peerIsCopyProtected && !rawMessage.isCopyProtected()) else { return [] }
    let reference = MessageReference(rawMessage)
    return rawMessage.effectiveMedia.compactMap { media -> AnyMediaReference? in
        if let image = media as? TelegramMediaImage, largestImageRepresentation(image.representations) != nil {
            return ImageMediaReference.message(message: reference, media: image).abstract
        }
        if let file = media as? TelegramMediaFile, file.isVideo || file.mimeType.hasPrefix("video/") || file.mimeType.hasPrefix("image/") {
            return FileMediaReference.message(message: reference, media: file).abstract
        }
        return nil
    }
}

/// A persistent Telegram alert owns the export until a terminal result is shown.
/// Backgrounding or tapping outside never commits/cancels an invisible toast.
public func presentPhotoLibraryExport(context: AccountContext, peerId: EnginePeer.Id, references: [AnyMediaReference], present: @escaping (ViewController) -> Void) {
    guard !references.isEmpty else { return }
    PhotoLibraryExportSession(context: context, peerId: peerId, references: references).present(using: present)
}

private final class PhotoLibraryExportSession {
    private let context: AccountContext
    private let peerId: EnginePeer.Id
    private let references: [AnyMediaReference]
    private let presentationData: PresentationData
    private let content = Promise<[AnyComponentWithIdentity<AlertComponentEnvironment>]>()
    private let actions = Promise<[AlertScreen.Action]>()
    private let cancelEnabled = ValuePromise<Bool>(true, ignoreRepeated: true)
    private let disposable = MetaDisposable()
    private weak var controller: AlertScreen?
    private var savedCount = 0
    private var canCancel = true
    private var active = false
    private var lastText: String?

    init(context: AccountContext, peerId: EnginePeer.Id, references: [AnyMediaReference]) {
        self.context = context
        self.peerId = peerId
        self.references = references
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
    }

    private func string(_ key: String) -> String {
        return i18n(key, self.presentationData.strings.baseLanguageCode)
    }

    func present(using present: (ViewController) -> Void) {
        let controller = AlertScreen(
            configuration: AlertScreen.Configuration(dismissOnOutsideTap: false),
            contentSignal: self.content.get(),
            actionsSignal: self.actions.get(),
            updatedPresentationData: (initial: self.presentationData, signal: self.context.sharedContext.presentationData)
        )
        self.controller = controller
        // The visible alert retains the session; the session only weakly holds
        // the alert. Disposing a view cannot leave an unowned download running.
        controller.dismissed = { _ in self.disposable.dispose() }
        self.updateText(self.string("Media.Export.Downloading") + "\n0%")
        self.updateCancelAction()
        present(controller)
        self.start()
    }

    private func updateText(_ text: String) {
        guard self.lastText != text else { return }
        self.lastText = text
        self.content.set(.single([
            AnyComponentWithIdentity(id: "title", component: AnyComponent(AlertTitleComponent(title: self.string("Media.Export.Title")))),
            AnyComponentWithIdentity(id: "progress", component: AnyComponent(AlertTextComponent(content: .plain(text))))
        ]))
    }

    private func updateCancelAction() {
        self.actions.set(.single([AlertScreen.Action(
            title: self.presentationData.strings.Common_Cancel,
            action: { [weak self] in self?.cancel() },
            autoDismiss: false,
            isEnabled: self.cancelEnabled.get()
        )]))
    }

    private func start() {
        self.active = true
        self.canCancel = true
        self.cancelEnabled.set(true)
        self.updateCancelAction()
        self.updateText(self.string("Media.Export.Downloading") + "\n\(self.savedCount) / \(self.references.count)")
        var signal: Signal<(Int, SaveMediaToPhotoLibraryStatus), SaveMediaToPhotoLibraryError> = .complete()
        for index in self.savedCount ..< self.references.count {
            signal = signal |> then(saveMediaToPhotoLibrary(context: self.context, userLocation: .peer(self.peerId), mediaReference: self.references[index]) |> map { (index, $0) })
        }
        self.disposable.set((signal |> deliverOnMainQueue).start(next: { [weak self] index, status in
            guard let self, self.active else { return }
            switch status {
            case let .progress(value):
                self.canCancel = true
                let overall = (Float(index) + value) / Float(self.references.count)
                self.updateText(self.string("Media.Export.Downloading") + "\n\(index + 1) / \(self.references.count) · \(Int(overall * 100.0))%")
            case .saving:
                self.canCancel = false
                self.updateText(self.string("Media.Export.Saving") + "\n\(index + 1) / \(self.references.count)")
            case .saved:
                self.savedCount = index + 1
            }
            self.cancelEnabled.set(self.canCancel)
        }, error: { [weak self] error in
            guard let self, self.active else { return }
            self.active = false
            let key: String
            switch error {
            case .downloadFailed: key = "Media.Export.DownloadError"
            case .unsupportedMedia: key = "Media.Export.Unsupported"
            case .accessDenied: key = "Media.Export.AccessDenied"
            default: key = "Media.Export.SaveError"
            }
            self.finish(text: self.string(key), retry: true)
        }, completed: { [weak self] in
            guard let self, self.active else { return }
            self.active = false
            self.finish(text: self.string("Media.Export.Saved"), retry: false)
        }))
    }

    private func cancel() {
        guard self.active, self.canCancel else { return }
        self.active = false
        self.disposable.set(nil)
        self.finish(text: self.string("Media.Export.Cancelled"), retry: false)
    }

    private func finish(text: String, retry: Bool) {
        self.updateText(text + "\n\(self.savedCount) / \(self.references.count)")
        var actions: [AlertScreen.Action] = []
        if retry {
            actions.append(AlertScreen.Action(title: self.string("Media.Export.Retry"), type: .default, action: { [weak self] in self?.start() }, autoDismiss: false))
        }
        actions.append(AlertScreen.Action(title: self.presentationData.strings.Common_Done, type: .generic))
        self.actions.set(.single(actions))
    }

    deinit {
        self.disposable.dispose()
    }
}
