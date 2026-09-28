@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class TranscriptionSoundSettingsTests: XCTestCase {
    private let enableTranscriptionSoundsKey = "EnableTranscriptionSounds"
    private let transcriptionStartSoundKey = "TranscriptionStartSound"
    private let transcriptionEndSoundKey = "TranscriptionEndSound"
    private let transcriptionStartSystemSoundNameKey = "TranscriptionStartSystemSoundName"
    private let transcriptionEndSystemSoundNameKey = "TranscriptionEndSystemSoundName"

    func testMacOSSystemSoundCatalogReturnsSortedUniqueSoundNames() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for filename in ["Tink.aiff", "Ping.AIFF", "Ping.wav", "notes.txt", ".hidden"] {
            XCTAssertTrue(
                FileManager.default.createFile(
                    atPath: directory.appendingPathComponent(filename).path,
                    contents: Data()
                )
            )
        }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Nested.aiff"),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(
            MacOSSystemSoundCatalog.names(in: directory),
            ["Ping", "Tink"]
        )
    }

    func testTranscriptionSoundNoneOptionsHaveNoFiles() {
        XCTAssertEqual(SettingsStore.TranscriptionStartSound.none.displayName, "None")
        XCTAssertNil(SettingsStore.TranscriptionStartSound.none.startSoundFileName)
        XCTAssertEqual(SettingsStore.TranscriptionEndSound.none.displayName, "None")
        XCTAssertNil(SettingsStore.TranscriptionEndSound.none.soundFileName)
    }

    func testFreshInstallSeedsMacOSBlowAndPopCues() throws {
        let suiteName = "TranscriptionSoundSeed-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SettingsStore.seedDefaultTranscriptionSoundsIfNeeded(in: defaults)

        XCTAssertEqual(defaults.string(forKey: self.transcriptionStartSystemSoundNameKey), "Blow")
        XCTAssertEqual(defaults.string(forKey: self.transcriptionEndSystemSoundNameKey), "Pop")
        XCTAssertEqual(defaults.string(forKey: self.transcriptionStartSoundKey), SettingsStore.TranscriptionStartSound.none.rawValue)
        XCTAssertEqual(defaults.string(forKey: self.transcriptionEndSoundKey), SettingsStore.TranscriptionEndSound.none.rawValue)
    }

    func testSeedingKeepsAnExistingCueChoice() throws {
        let suiteName = "TranscriptionSoundSeed-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(SettingsStore.TranscriptionStartSound.fluidSfx2.rawValue, forKey: self.transcriptionStartSoundKey)

        SettingsStore.seedDefaultTranscriptionSoundsIfNeeded(in: defaults)

        XCTAssertEqual(defaults.string(forKey: self.transcriptionStartSoundKey), SettingsStore.TranscriptionStartSound.fluidSfx2.rawValue)
        XCTAssertNil(defaults.string(forKey: self.transcriptionStartSystemSoundNameKey))
        XCTAssertNil(defaults.string(forKey: self.transcriptionEndSystemSoundNameKey))
    }

    func testTranscriptionSoundToggleDoesNotOverwriteSelections() {
        self.withRestoredDefaults(keys: [self.enableTranscriptionSoundsKey, self.transcriptionStartSoundKey]) {
            let defaults = UserDefaults.standard
            defaults.set(false, forKey: self.enableTranscriptionSoundsKey)
            defaults.set(SettingsStore.TranscriptionStartSound.fluidSfx1.rawValue, forKey: self.transcriptionStartSoundKey)

            XCTAssertFalse(SettingsStore.shared.enableTranscriptionSounds)
            XCTAssertEqual(SettingsStore.shared.transcriptionStartSound, .fluidSfx1)

            SettingsStore.shared.enableTranscriptionSounds = true
            XCTAssertTrue(SettingsStore.shared.enableTranscriptionSounds)
            XCTAssertEqual(SettingsStore.shared.transcriptionStartSound, .fluidSfx1)
        }
    }

    func testTranscriptionEndSoundMigratesFromLegacyPairedStartCue() {
        self.withRestoredDefaults(keys: [self.transcriptionStartSoundKey, self.transcriptionEndSoundKey]) {
            let defaults = UserDefaults.standard
            defaults.set(SettingsStore.TranscriptionStartSound.fluidSfx0.rawValue, forKey: self.transcriptionStartSoundKey)
            defaults.removeObject(forKey: self.transcriptionEndSoundKey)

            XCTAssertEqual(SettingsStore.shared.transcriptionEndSound, .fluidSfx0)
            XCTAssertEqual(
                defaults.string(forKey: self.transcriptionEndSoundKey),
                SettingsStore.TranscriptionEndSound.fluidSfx0.rawValue
            )
        }
    }

    func testTranscriptionEndSoundMigratesLegacyUnpairedCueToNone() {
        self.withRestoredDefaults(keys: [self.transcriptionStartSoundKey, self.transcriptionEndSoundKey]) {
            let defaults = UserDefaults.standard
            defaults.set(SettingsStore.TranscriptionStartSound.fluidSfx2.rawValue, forKey: self.transcriptionStartSoundKey)
            defaults.removeObject(forKey: self.transcriptionEndSoundKey)

            XCTAssertEqual(SettingsStore.shared.transcriptionEndSound, .none)
        }
    }

    func testTranscriptionSoundSelectionsRemainIndependent() {
        self.withRestoredDefaults(keys: [
            self.enableTranscriptionSoundsKey,
            self.transcriptionStartSoundKey,
            self.transcriptionEndSoundKey,
        ]) {
            SettingsStore.shared.enableTranscriptionSounds = true
            SettingsStore.shared.transcriptionStartSound = .fluidSfx2
            SettingsStore.shared.transcriptionEndSound = .fluidSfx1

            XCTAssertEqual(SettingsStore.shared.transcriptionStartSound, .fluidSfx2)
            XCTAssertEqual(SettingsStore.shared.transcriptionEndSound, .fluidSfx1)
            XCTAssertEqual(SettingsStore.shared.transcriptionEndSound.soundFileName, "FV_end")
        }
    }

    func testSystemSoundNamesPersistIndependently() {
        self.withRestoredDefaults(keys: [
            self.transcriptionStartSystemSoundNameKey,
            self.transcriptionEndSystemSoundNameKey,
        ]) {
            SettingsStore.shared.transcriptionStartSystemSoundName = "Tink"
            SettingsStore.shared.transcriptionEndSystemSoundName = "Ping"

            XCTAssertEqual(SettingsStore.shared.transcriptionStartSystemSoundName, "Tink")
            XCTAssertEqual(SettingsStore.shared.transcriptionEndSystemSoundName, "Ping")

            SettingsStore.shared.transcriptionStartSystemSoundName = nil

            XCTAssertNil(SettingsStore.shared.transcriptionStartSystemSoundName)
            XCTAssertEqual(SettingsStore.shared.transcriptionEndSystemSoundName, "Ping")
        }
    }

    func testBackupPayloadIncludesSystemSoundNames() {
        self.withRestoredDefaults(keys: [
            self.transcriptionStartSystemSoundNameKey,
            self.transcriptionEndSystemSoundNameKey,
        ]) {
            SettingsStore.shared.transcriptionStartSystemSoundName = "Tink"
            SettingsStore.shared.transcriptionEndSystemSoundName = "Ping"

            let payload = SettingsStore.shared.makeBackupPayload()

            XCTAssertEqual(payload.transcriptionStartSystemSoundName, "Tink")
            XCTAssertEqual(payload.transcriptionEndSystemSoundName, "Ping")
        }
    }

    func testOverlappingIndependentVolumePlaybackRestoresTheOriginalVolumeLast() {
        var state = IndependentVolumePlaybackState()

        XCTAssertTrue(state.beginPlayback(currentSystemVolume: 0.72))
        XCTAssertTrue(state.beginPlayback(currentSystemVolume: 0.18))
        XCTAssertNil(state.finishPlayback())
        XCTAssertEqual(state.finishPlayback(), 0.72)
        XCTAssertEqual(state.activePlaybackCount, 0)
    }

    func testMutedIndependentVolumePlaybackDoesNotJoinRestorationGroup() {
        var state = IndependentVolumePlaybackState()

        XCTAssertFalse(state.beginPlayback(currentSystemVolume: 0.001))
        XCTAssertNil(state.finishPlayback())
        XCTAssertEqual(state.activePlaybackCount, 0)
    }

    private func withRestoredDefaults(keys: [String], run: () -> Void) {
        let defaults = UserDefaults.standard
        var snapshot: [String: Any] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) {
                snapshot[key] = value
            }
        }

        defer {
            for key in keys {
                if let previous = snapshot[key] {
                    defaults.set(previous, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        run()
    }
}
