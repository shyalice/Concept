import Foundation
import UIKit

/// One public HTTPS catalog, never a request for the profile being viewed.
/// Lookups are memory-only and safe on asynchronous layout queues.
public final class ConceptBadgeService {
    public static let shared = ConceptBadgeService()
    public static let changed = Notification.Name("Concept.BadgesChanged")
    public static let endpoint = URL(string: "https://push.killed.wtf/v3/badges")!
    public static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "Concept.Badges.Enabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "Concept.Badges.Enabled")
            shared.setActive(newValue && UIApplication.shared.applicationState == .active)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    private let lock = NSLock()
    private var catalog: ConceptBadgeCatalog?
    private let queue = DispatchQueue(label: "Concept.Badges")
    private var timer: DispatchSourceTimer?
    private var task: URLSessionDataTask?
    private var generation = 0
    private let session: URLSession
    private let cache: URL?
    private var lastAttempt = Date.distantPast
    private var etag: String?
    private var active = false
    private var highestRevision: Int64

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
        self.cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("ConceptBadges-v3.json")
        self.highestRevision = Int64(UserDefaults.standard.integer(forKey: "Concept.Badges.Revision"))
        if let cache, let data = try? Data(contentsOf: cache) {
            self.catalog = ConceptBadgeCatalog.decode(data, minimumRevision: self.highestRevision, now: Date())
        }
    }

    public func badge(peerId: String) -> ConceptBadge? {
        guard Self.isEnabled else { return nil }
        self.lock.lock(); defer { self.lock.unlock() }
        guard let catalog, catalog.expires > Int64(Date().timeIntervalSince1970) else { return nil }
        return catalog.badges[peerId]
    }

    public func setActive(_ active: Bool) {
        self.queue.async {
            self.active = active && Self.isEnabled
            self.timer?.cancel(); self.timer = nil
            guard self.active else { self.generation += 1; self.task?.cancel(); self.task = nil; return }
            self.fetch(force: false)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 300, repeating: 300, leeway: .seconds(30))
            timer.setEventHandler { [weak self] in self?.fetch(force: false) }
            self.timer = timer; timer.resume()
        }
    }

    public func refresh() { self.queue.async { self.fetch(force: true) } }

    private func fetch(force: Bool) {
        self.lock.lock()
        let expired = self.catalog.map { $0.expires <= Int64(Date().timeIntervalSince1970) } ?? false
        if expired { self.catalog = nil; self.etag = nil }
        self.lock.unlock()
        if expired { DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) } }
        guard self.active, self.task == nil, force || Date().timeIntervalSince(self.lastAttempt) >= 60 else { return }
        self.lastAttempt = Date()
        var request = URLRequest(url: Self.endpoint)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("cuteangelgirl/1.0", forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let generation = self.generation
        let task = self.session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                guard generation == self.generation else { return }
                self.task = nil
                guard self.active, Self.isEnabled, error == nil, let response = response as? HTTPURLResponse else { return }
                if response.statusCode == 304 { return }
                guard response.statusCode == 200, let data,
                      let catalog = ConceptBadgeCatalog.decode(data, minimumRevision: self.highestRevision, now: Date()) else { return }
                self.highestRevision = catalog.revision
                UserDefaults.standard.set(catalog.revision, forKey: "Concept.Badges.Revision")
                self.etag = response.value(forHTTPHeaderField: "ETag")
                self.lock.lock(); self.catalog = catalog; self.lock.unlock()
                if let cache = self.cache { try? data.write(to: cache, options: .atomic) }
                DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
            }
        }
        self.task = task; task.resume()
    }
}
