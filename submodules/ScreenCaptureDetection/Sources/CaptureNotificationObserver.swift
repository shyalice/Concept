import Foundation

/// Capture events carry no data. Keep their Objective-C notification opaque:
/// bridging its object/userInfo into Swift Notification is unnecessary here.
/// In particular, nothing from a UIKit capture callback crosses an async queue.
final class CaptureNotificationObserver: NSObject {
    private let center: NotificationCenter
    private let lock = NSLock()
    private var action: (() -> Void)?
    private var lastTimestamp: TimeInterval?
    private let repeatInterval: TimeInterval

    init(center: NotificationCenter = .default, name: Notification.Name, repeatInterval: TimeInterval, action: @escaping () -> Void) {
        self.center = center
        self.repeatInterval = repeatInterval
        self.action = action
        super.init()
        center.addObserver(self, selector: #selector(self.received(_:)), name: name, object: nil)
    }

    @objc private func received(_ notification: NSNotification) {
        if Thread.isMainThread {
            self.deliver()
        } else {
            DispatchQueue.main.async { [weak self] in self?.deliver() }
        }
    }

    private func deliver() {
        self.lock.lock()
        guard let action = self.action else { self.lock.unlock(); return }
        let timestamp = ProcessInfo.processInfo.systemUptime
        if let previous = self.lastTimestamp, timestamp - previous < self.repeatInterval {
            self.lock.unlock()
            return
        }
        self.lastTimestamp = timestamp
        self.lock.unlock()
        action()
    }

    func clear() {
        self.lock.lock()
        self.action = nil
        self.lock.unlock()
        self.center.removeObserver(self)
    }

    deinit { self.center.removeObserver(self) }
}
