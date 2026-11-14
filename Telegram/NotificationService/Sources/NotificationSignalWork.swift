import Foundation
import SwiftSignalKit

extension Signal {
    /// Register before starting: a synchronous completion can close the request
    /// before start returns its disposable. MetaDisposable closes that race.
    func start(request: NotificationRequestWork, next: ((T) -> Void)? = nil, error: ((E) -> Void)? = nil, completed: (() -> Void)? = nil) -> Disposable {
        let disposable = MetaDisposable()
        request.addCancellation { disposable.dispose() }
        guard !request.isCancelled else { return disposable }
        disposable.set(self.start(next: { value in
            guard !request.isCancelled else { return }
            next?(value)
        }, error: { value in
            guard !request.isCancelled else { return }
            error?(value)
        }, completed: {
            guard !request.isCancelled else { return }
            completed?()
        }))
        return disposable
    }
}

