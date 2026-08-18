import AVFoundation
import AppKit
import CoreAudio
import Foundation

struct MacOSSystemSoundCatalog {
    static let systemSoundsDirectory = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)

    private static let soundExtensions: Set<String> = ["aiff", "aif", "wav", "caf", "snd"]

    static func names(
        in directory: URL = Self.systemSoundsDirectory,
        fileManager: FileManager = .default
    ) -> [String] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let names = files.compactMap { file -> String? in
            guard
                let isRegularFile = try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                isRegularFile == true,
                Self.soundExtensions.contains(file.pathExtension.lowercased())
            else {
                return nil
            }

            let name = file.deletingPathExtension().lastPathComponent
            return name.isEmpty ? nil : name
        }

        return Array(Set(names)).sorted()
    }
}

nonisolated struct IndependentVolumePlaybackState: Equatable {
    private(set) var activePlaybackCount = 0
    private var originalSystemVolume: Float?

    mutating func beginPlayback(currentSystemVolume: Float) -> Bool {
        guard currentSystemVolume > 0.001 else { return false }
        if self.activePlaybackCount == 0 {
            self.originalSystemVolume = currentSystemVolume
        }
        self.activePlaybackCount += 1
        return true
    }

    mutating func finishPlayback() -> Float? {
        guard self.activePlaybackCount > 0 else { return nil }
        self.activePlaybackCount -= 1
        guard self.activePlaybackCount == 0 else { return nil }

        let volume = self.originalSystemVolume
        self.originalSystemVolume = nil
        return volume
    }
}

final class TranscriptionSoundPlayer {
    static let shared = TranscriptionSoundPlayer()

    private let playbackQueue = DispatchQueue(label: "app.fluidvoice.transcription-sounds", qos: .userInteractive)
    private var players: [String: AVAudioPlayer] = [:]
    private var systemPlayers: [String: NSSound] = [:]
    private var independentVolumePlaybackState = IndependentVolumePlaybackState()

    private init() {}

    func playStartSound() {
        let settings = SettingsStore.shared
        guard settings.enableTranscriptionSounds else { return }
        if let systemSoundName = settings.transcriptionStartSystemSoundName {
            self.playSystemSound(
                name: systemSoundName,
                desiredVolume: settings.transcriptionSoundVolume,
                independentVolume: settings.transcriptionSoundIndependentVolume
            )
            return
        }
        let selected = settings.transcriptionStartSound
        guard let soundName = selected.startSoundFileName else { return }
        self.play(
            soundName: soundName,
            desiredVolume: settings.transcriptionSoundVolume,
            independentVolume: settings.transcriptionSoundIndependentVolume
        )
    }

    func playStopSound() {
        let settings = SettingsStore.shared
        guard settings.enableTranscriptionSounds else { return }
        if let systemSoundName = settings.transcriptionEndSystemSoundName {
            self.playSystemSound(
                name: systemSoundName,
                desiredVolume: settings.transcriptionSoundVolume,
                independentVolume: settings.transcriptionSoundIndependentVolume
            )
            return
        }
        let selected = settings.transcriptionEndSound
        guard let soundName = selected.soundFileName else { return }
        self.play(
            soundName: soundName,
            desiredVolume: settings.transcriptionSoundVolume,
            independentVolume: settings.transcriptionSoundIndependentVolume
        )
    }

    func playPreview(systemSoundName: String) {
        let settings = SettingsStore.shared
        self.playSystemSound(
            name: systemSoundName,
            desiredVolume: settings.transcriptionSoundVolume,
            independentVolume: settings.transcriptionSoundIndependentVolume
        )
    }

    /// Preview a specific sound at the current volume setting (used in Settings UI).
    func playPreview(sound: SettingsStore.TranscriptionStartSound) {
        guard let soundName = sound.startSoundFileName else { return }
        let settings = SettingsStore.shared
        self.play(
            soundName: soundName,
            desiredVolume: settings.transcriptionSoundVolume,
            independentVolume: settings.transcriptionSoundIndependentVolume
        )
    }

    func playPreview(sound: SettingsStore.TranscriptionEndSound) {
        guard let soundName = sound.soundFileName else { return }
        let settings = SettingsStore.shared
        self.play(
            soundName: soundName,
            desiredVolume: settings.transcriptionSoundVolume,
            independentVolume: settings.transcriptionSoundIndependentVolume
        )
    }

    /// Preview current sound at a specific volume (used when slider is released).
    func playPreviewAtVolume(_ volume: Float) {
        let settings = SettingsStore.shared
        if let systemSoundName = settings.transcriptionStartSystemSoundName {
            self.playSystemSound(
                name: systemSoundName,
                desiredVolume: volume,
                independentVolume: settings.transcriptionSoundIndependentVolume
            )
            return
        }
        if let soundName = settings.transcriptionStartSound.startSoundFileName {
            self.play(
                soundName: soundName,
                desiredVolume: volume,
                independentVolume: settings.transcriptionSoundIndependentVolume
            )
            return
        }
        if let systemSoundName = settings.transcriptionEndSystemSoundName {
            self.playSystemSound(
                name: systemSoundName,
                desiredVolume: volume,
                independentVolume: settings.transcriptionSoundIndependentVolume
            )
            return
        }
        guard let soundName = settings.transcriptionEndSound.soundFileName else { return }
        self.play(
            soundName: soundName,
            desiredVolume: volume,
            independentVolume: settings.transcriptionSoundIndependentVolume
        )
    }

    private func play(
        soundName: String,
        desiredVolume: Float,
        independentVolume: Bool
    ) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        DebugLogger.shared.benchmark(
            "APP_BENCH",
            message: "sound_play_request sound=\(soundName)",
            source: "AppBenchmark"
        )

        guard let url = Bundle.main.url(forResource: soundName, withExtension: "m4a") else {
            DebugLogger.shared.error("Missing sound resource: \(soundName).m4a", source: "TranscriptionSoundPlayer")
            return
        }

        self.playbackQueue.async { [weak self] in
            self?.playOnPlaybackQueue(
                soundName: soundName,
                url: url,
                desiredVolume: desiredVolume,
                independentVolume: independentVolume,
                startedAt: startedAt
            )
        }
    }

    private func playOnPlaybackQueue(
        soundName: String,
        url: URL,
        desiredVolume: Float,
        independentVolume: Bool,
        startedAt: TimeInterval
    ) {
        guard self.beginIndependentVolumePlayback(
            ifEnabled: independentVolume,
            desiredVolume: desiredVolume
        ) else { return }

        do {
            let player: AVAudioPlayer
            if let existing = self.players[soundName] {
                player = existing
            } else {
                player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                self.players[soundName] = player
            }

            player.currentTime = 0
            if independentVolume {
                player.volume = 1.0
            } else {
                player.volume = desiredVolume
            }
            player.play()
            DebugLogger.shared.benchmark(
                "APP_BENCH",
                message: "sound_play_dispatched sound=\(soundName) elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded()))",
                source: "AppBenchmark"
            )

            self.scheduleIndependentVolumeRestoration(
                ifEnabled: independentVolume,
                duration: player.duration
            )
        } catch {
            self.restoreIndependentVolumeAfterFailure(ifEnabled: independentVolume)
            DebugLogger.shared.error(
                "Failed to play sound \(soundName).m4a: \(error.localizedDescription)",
                source: "TranscriptionSoundPlayer"
            )
        }
    }

    private func playSystemSound(
        name: String,
        desiredVolume: Float,
        independentVolume: Bool
    ) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        DebugLogger.shared.benchmark(
            "APP_BENCH",
            message: "sound_play_request sound=\(name) backend=system",
            source: "AppBenchmark"
        )

        self.playbackQueue.async { [weak self] in
            self?.playSystemSoundOnPlaybackQueue(
                name: name,
                desiredVolume: desiredVolume,
                independentVolume: independentVolume,
                startedAt: startedAt
            )
        }
    }

    private func playSystemSoundOnPlaybackQueue(
        name: String,
        desiredVolume: Float,
        independentVolume: Bool,
        startedAt: TimeInterval
    ) {
        let sound: NSSound
        if let existing = self.systemPlayers[name] {
            sound = existing
        } else {
            guard let created = NSSound(named: name) else {
                DebugLogger.shared.error(
                    "Missing macOS system sound: \(name)",
                    source: "TranscriptionSoundPlayer"
                )
                return
            }
            sound = created
            self.systemPlayers[name] = created
        }

        guard self.beginIndependentVolumePlayback(
            ifEnabled: independentVolume,
            desiredVolume: desiredVolume
        ) else { return }

        sound.currentTime = 0
        sound.volume = independentVolume ? 1.0 : desiredVolume
        guard sound.play() else {
            self.restoreIndependentVolumeAfterFailure(ifEnabled: independentVolume)
            DebugLogger.shared.error(
                "Failed to play macOS system sound: \(name)",
                source: "TranscriptionSoundPlayer"
            )
            return
        }

        DebugLogger.shared.benchmark(
            "APP_BENCH",
            message: "sound_play_dispatched sound=\(name) backend=system elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded()))",
            source: "AppBenchmark"
        )
        self.scheduleIndependentVolumeRestoration(
            ifEnabled: independentVolume,
            duration: sound.duration
        )
    }

    private func beginIndependentVolumePlayback(
        ifEnabled: Bool,
        desiredVolume: Float
    ) -> Bool {
        guard ifEnabled else { return true }
        let currentSystemVolume = Self.getSystemVolume()
        guard self.independentVolumePlaybackState.beginPlayback(
            currentSystemVolume: currentSystemVolume
        ) else {
            return false
        }
        Self.setSystemVolume(desiredVolume)
        return true
    }

    private func restoreIndependentVolumeAfterFailure(ifEnabled: Bool) {
        guard ifEnabled,
              let originalVolume = self.independentVolumePlaybackState.finishPlayback()
        else { return }
        Self.setSystemVolume(originalVolume)
    }

    private func scheduleIndependentVolumeRestoration(ifEnabled: Bool, duration: TimeInterval) {
        guard ifEnabled else { return }
        // Overlapping cues share one restoration group. The original system volume is
        // restored only after the last playback completes.
        self.playbackQueue.asyncAfter(deadline: .now() + duration + 0.05) { [weak self] in
            guard let self,
                  let originalVolume = self.independentVolumePlaybackState.finishPlayback()
            else { return }
            Self.setSystemVolume(originalVolume)
        }
    }

    // MARK: - System Volume via CoreAudio

    private static func getDefaultOutputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    static func getSystemVolume() -> Float {
        guard let deviceID = getDefaultOutputDeviceID() else { return 1.0 }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume: Float32 = 1.0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else { return 1.0 }
        return volume
    }

    private static func setSystemVolume(_ volume: Float) {
        guard let deviceID = getDefaultOutputDeviceID() else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var vol = Float32(max(0, min(1, volume)))
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &vol)
        if status != noErr {
            DebugLogger.shared.error("Failed to set system volume: OSStatus \(status)", source: "TranscriptionSoundPlayer")
        }
    }
}
