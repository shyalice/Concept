import Foundation
import AVFAudio
import UIKit
import SwiftSignalKit
import TelegramAudio
import ConceptNotifications

final class ConceptBackgroundKeepAlive: NSObject, AVAudioPlayerDelegate {
    private let activePromise = ValuePromise<Bool>(false, ignoreRepeated: true)
    var isRunning: Signal<Bool, NoError> { self.activePromise.get() }

    private var player: AVAudioPlayer?
    private var watchdog: DispatchSourceTimer?
    private var recovery: DispatchWorkItem?
    private var recoveryAttempt = 0
    private var audioLease: Disposable?
    private var audioObserver: Disposable?
    private weak var wakeupManager: SharedWakeupManager?
    private var silenceURL: URL?
    private var generation = 0
    private var enabled = false
    private var ownsAudio = false

    func start(wakeupManager: SharedWakeupManager) {
        assert(Queue.mainQueue().isCurrent())
        guard BackgroundNotificationSettings.isEnabled, UIApplication.shared.applicationState == .background, !self.enabled else { return }
        self.enabled = true
        self.recoveryAttempt = 0
        self.wakeupManager = wakeupManager
        let generation = self.generation
        self.audioObserver = (MediaManagerImpl.globalAudioSession.isActive()
        |> deliverOnMainQueue).start(next: { [weak self] active in
            guard let self, self.enabled, self.generation == generation else { return }
            // Don't push playback above a call, recording, or media already playing.
            if !active, self.audioLease == nil, self.recoveryAttempt < 3 {
                self.acquireAudio(generation: generation)
            }
        })
    }

    func stop() {
        assert(Queue.mainQueue().isCurrent())
        self.enabled = false
        self.ownsAudio = false
        self.generation += 1
        self.audioObserver?.dispose()
        self.audioObserver = nil
        self.watchdog?.cancel()
        self.watchdog = nil
        self.recovery?.cancel()
        self.recovery = nil
        self.recoveryAttempt = 0
        self.player?.stop()
        self.player = nil
        self.activePromise.set(false)
        self.audioLease?.dispose()
        self.audioLease = nil
        self.wakeupManager = nil
    }

    private func acquireAudio(generation: Int) {
        self.audioLease = MediaManagerImpl.globalAudioSession.push(
            audioSessionType: .play(mixWithOthers: true), once: false,
            activate: { [weak self] _ in
                Queue.mainQueue().async {
                    guard let self, self.enabled, self.generation == generation else { return }
                    self.ownsAudio = true
                    self.startWatchdog()
                    self.startPlayer()
                }
            }, deactivate: { [weak self] _ in
                return Signal { subscriber in
                    Queue.mainQueue().async {
                        if let self, self.generation == generation {
                            self.ownsAudio = false
                            self.watchdog?.cancel()
                            self.watchdog = nil
                            self.recovery?.cancel()
                            self.recovery = nil
                            self.player?.stop()
                            self.player = nil
                            self.activePromise.set(false)
                        }
                        subscriber.putCompletion()
                    }
                    return EmptyDisposable
                }
            }
        )
    }

    private func startPlayer() {
        guard self.enabled, self.ownsAudio, BackgroundNotificationSettings.isEnabled,
              UIApplication.shared.applicationState == .background else { return }
        guard self.player?.isPlaying != true else { return }
        guard let url = self.silenceURL ?? self.makeSilenceFile(),
              let player = try? AVAudioPlayer(contentsOf: url) else { self.scheduleRecovery(); return }
        self.silenceURL = url
        player.delegate = self
        player.numberOfLoops = -1
        player.volume = 1.0
        guard player.prepareToPlay(), player.play() else { self.scheduleRecovery(); return }
        self.player = player
        self.recoveryAttempt = 0
        self.activePromise.set(true)
        self.wakeupManager?.allowBackgroundTimeExtension(timeout: 30.0, extendNow: true)
    }

    private func startWatchdog() {
        guard self.watchdog == nil else { return }
        let generation = self.generation
        let watchdog = DispatchSource.makeTimerSource(queue: .main)
        // Safety net for an unreported player stop, not a network/read-state poll.
        // Coalesce this infrequent check with other system work where possible.
        watchdog.schedule(deadline: .now() + 60.0, repeating: 60.0, leeway: .seconds(15))
        watchdog.setEventHandler { [weak self] in
            guard let self, self.generation == generation else { return }
            self.checkPlayback()
        }
        self.watchdog = watchdog
        watchdog.resume()
    }

    private func checkPlayback() {
        guard self.enabled else { return }
        guard BackgroundNotificationSettings.isEnabled, UIApplication.shared.applicationState == .background else {
            self.stop()
            return
        }
        if self.ownsAudio, self.player?.isPlaying != true, self.recovery == nil {
            self.scheduleRecovery()
        }
    }

    private func scheduleRecovery() {
        guard self.enabled, self.ownsAudio, self.recovery == nil else { return }
        self.activePromise.set(false)
        guard self.recoveryAttempt < 3 else {
            self.ownsAudio = false
            self.watchdog?.cancel()
            self.watchdog = nil
            self.audioLease?.dispose()
            self.audioLease = nil
            return
        }
        self.recoveryAttempt += 1
        let generation = self.generation
        let recovery = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation else { return }
            self.recovery = nil
            self.startPlayer()
        }
        self.recovery = recovery
        Queue.mainQueue().after(Double(self.recoveryAttempt) * 15.0) { recovery.perform() }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.handlePlayerStopped(player)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        self.handlePlayerStopped(player)
    }

    private func handlePlayerStopped(_ player: AVAudioPlayer) {
        Queue.mainQueue().async { [weak self, weak player] in
            guard let self, let player, self.player === player else { return }
            self.player = nil
            self.activePromise.set(false)
            self.scheduleRecovery()
        }
    }

    private func makeSilenceFile() -> URL? {
        guard let cachesPath = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first else {
            return nil
        }
        let directory = URL(fileURLWithPath: cachesPath).appendingPathComponent("ConceptKeepAlive", isDirectory: true)
        let url = directory.appendingPathComponent("silence.wav")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attributes[.size] as? NSNumber, size.intValue == 16044 {
            return url
        }
        let _ = try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        guard let data = ConceptBackgroundKeepAlive.silentWAVData() else {
            return nil
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return url
    }

    private static func silentWAVData(sampleRate: UInt32 = 8000, seconds: UInt32 = 1) -> Data? {
        let sampleCount = sampleRate * seconds
        let dataSize = sampleCount * 2
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(littleEndian: UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(littleEndian: UInt32(16))
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: sampleRate)
        data.append(littleEndian: sampleRate * 2)
        data.append(littleEndian: UInt16(2))
        data.append(littleEndian: UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        data.append(littleEndian: dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { buffer in
            self.append(contentsOf: buffer)
        }
    }
}