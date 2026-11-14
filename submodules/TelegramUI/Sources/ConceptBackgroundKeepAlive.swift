import Foundation
import AVFAudio
import UIKit
import SwiftSignalKit
import TelegramAudio

final class ConceptBackgroundKeepAlive {
    private let activePromise = ValuePromise<Bool>(false, ignoreRepeated: true)
    var isRunning: Signal<Bool, NoError> { self.activePromise.get() }

    private var player: AVAudioPlayer?
    private var timer: SwiftSignalKit.Timer?
    private var audioLease: Disposable?
    private var audioObserver: Disposable?
    private weak var wakeupManager: SharedWakeupManager?
    private var silenceURL: URL?
    private var generation = 0
    private var enabled = false
    private var ownsAudio = false

    func start(wakeupManager: SharedWakeupManager) {
        assert(Queue.mainQueue().isCurrent())
        guard !self.enabled else { return }
        self.enabled = true
        self.wakeupManager = wakeupManager
        let generation = self.generation
        self.audioObserver = (MediaManagerImpl.globalAudioSession.isActive()
        |> deliverOnMainQueue).start(next: { [weak self] active in
            guard let self, self.enabled, self.generation == generation else { return }
            // Don't push playback above a call, recording, or media already playing.
            if !active, self.audioLease == nil {
                self.acquireAudio(generation: generation)
            }
        })
        let timer = SwiftSignalKit.Timer(timeout: 10.0, repeat: true, completion: { [weak self] in
            guard let self else { return }
            if self.ownsAudio, self.player?.isPlaying != true { self.startPlayer() }
            self.activePromise.set(self.player?.isPlaying == true)
            if self.player?.isPlaying == true {
                self.wakeupManager?.allowBackgroundTimeExtension(timeout: 30.0, extendNow: true)
            }
        }, queue: .mainQueue())
        self.timer = timer
        timer.start()
    }

    func stop() {
        assert(Queue.mainQueue().isCurrent())
        self.enabled = false
        self.ownsAudio = false
        self.generation += 1
        self.audioObserver?.dispose()
        self.audioObserver = nil
        self.timer?.invalidate()
        self.timer = nil
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
                    self.startPlayer()
                }
            }, deactivate: { [weak self] _ in
                return Signal { subscriber in
                    Queue.mainQueue().async {
                        if let self, self.generation == generation {
                            self.ownsAudio = false
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
        guard let url = self.silenceURL ?? self.makeSilenceFile() else { return }
        self.silenceURL = url
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.numberOfLoops = -1
        player.volume = 1.0
        guard player.prepareToPlay(), player.play() else { return }
        self.player = player
        self.activePromise.set(true)
        self.wakeupManager?.allowBackgroundTimeExtension(timeout: 30.0, extendNow: true)
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