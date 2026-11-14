import Foundation
import Photos
import UniformTypeIdentifiers
import ImageIO
import SwiftSignalKit
import TelegramCore
import AccountContext
import DeviceAccess

public enum SaveMediaToPhotoLibraryError: Error {
    case unsupportedMedia
    case downloadFailed
    case accessDenied
    case fileUnavailable
    case saveFailed
}

public enum SaveMediaToPhotoLibraryStatus {
    case progress(Float)
    case saving
    case saved
}

/// Uses the account's normal resource fetch/revalidation and reports Photos' real
/// completion result. Cancelling stops the fetch; an already committed Photos
/// transaction is allowed to finish and cleans up its temporary file.
public func saveMediaToPhotoLibrary(context: AccountContext, userLocation: MediaResourceUserLocation, mediaReference: AnyMediaReference) -> Signal<SaveMediaToPhotoLibraryStatus, SaveMediaToPhotoLibraryError> {
    return Signal { subscriber in
        let cancelled = Atomic<Bool>(value: false)
        let beganSaving = Atomic<Bool>(value: false)
        let fetchDisposable = MetaDisposable()

        DeviceAccess.authorizeAccess(to: .mediaLibrary(.save), presentationData: context.sharedContext.currentPresentationData.with { $0 }, present: { controller, arguments in
            context.sharedContext.presentGlobalController(controller, arguments)
        }, openSettings: context.sharedContext.applicationBindings.openSettings, { authorized in
            guard !cancelled.with({ $0 }) else { return }
            guard authorized else {
                subscriber.putError(.accessDenied)
                return
            }
            fetchDisposable.set((fetchMediaDataWithErrors(context: context, userLocation: userLocation, mediaReference: mediaReference)
            |> deliverOn(Queue.concurrentDefaultQueue())).start(next: { state, isImage in
                guard !cancelled.with({ $0 }), !beganSaving.with({ $0 }) else { return }
                switch state {
                case let .progress(progress):
                    subscriber.putNext(.progress(max(0.0, min(1.0, progress))))
                case let .data(data):
                    guard data.isComplete, !beganSaving.swap(true) else { return }
                    let contentType: UTType?
                    if isImage, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: data.path) as CFURL, nil), let type = CGImageSourceGetType(source) {
                        contentType = UTType(type as String)
                    } else if let file = mediaReference.media as? TelegramMediaFile {
                        contentType = UTType(mimeType: file.mimeType)
                    } else {
                        contentType = nil
                    }
                    let suffix = contentType?.preferredFilenameExtension ?? (isImage ? "jpg" : "mp4")
                    let temporaryURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
                    do {
                        try FileManager.default.copyItem(at: URL(fileURLWithPath: data.path), to: temporaryURL)
                    } catch {
                        subscriber.putError(.fileUnavailable)
                        return
                    }
                    fetchDisposable.dispose()
                    guard !cancelled.with({ $0 }) else {
                        try? FileManager.default.removeItem(at: temporaryURL)
                        return
                    }
                    Queue.mainQueue().async {
                        guard !cancelled.with({ $0 }) else {
                            try? FileManager.default.removeItem(at: temporaryURL)
                            return
                        }
                        // Deliver the non-cancellable state on the main queue
                        // before submitting Photos' irreversible transaction.
                        subscriber.putNext(.saving)
                        PHPhotoLibrary.shared().performChanges({
                            let options = PHAssetResourceCreationOptions()
                            options.uniformTypeIdentifier = contentType?.identifier
                            PHAssetCreationRequest.forAsset().addResource(with: isImage ? .photo : .video, fileURL: temporaryURL, options: options)
                        }, completionHandler: { success, _ in
                            try? FileManager.default.removeItem(at: temporaryURL)
                            Queue.mainQueue().async {
                                guard !cancelled.with({ $0 }) else { return }
                                if success {
                                    subscriber.putNext(.saved)
                                    subscriber.putCompletion()
                                } else {
                                    subscriber.putError(.saveFailed)
                                }
                            }
                        })
                    }
                }
            }, error: { error in
                subscriber.putError(error)
            }))
        })

        return ActionDisposable {
            _ = cancelled.swap(true)
            fetchDisposable.dispose()
        }
    }
}
