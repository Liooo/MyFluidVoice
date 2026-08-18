import Foundation
#if arch(arm64)
import MediaRemoteAdapter
#endif

/// Service that wraps MediaRemoteAdapter's MediaController to provide
/// controlled pause/resume functionality during transcription.
///
/// This service ensures we only pause media if it's currently playing,
/// and only resume if we were the ones who paused it.
@MainActor
final class MediaPlaybackService {
    static let shared = MediaPlaybackService()

    #if arch(arm64)
    private let mediaController = MediaController()
    #endif

    private init() {}

    // MARK: - Public API

    #if arch(arm64)
    /// Pauses system media playback if something is currently playing.
    ///
    /// - Returns: `true` if we successfully paused playback, `false` if nothing was playing
    ///   or if we couldn't determine playback state.
    ///
    /// - Note: The pinned BSD-licensed adapter exposes a listener instead of a one-shot query.
    ///   This method starts it only long enough to receive the initial snapshot, then tears the
    ///   listener down before completing.
    func pauseIfPlaying() async -> Bool {
        return await withCheckedContinuation { continuation in
            let resumeLock = NSLock()
            var didResume = false

            @MainActor
            @discardableResult
            func resumeOnce(
                _ value: Bool,
                logDuplicate: Bool = true,
                beforeResume: () -> Void = {}
            ) -> Bool {
                var shouldResume = false

                resumeLock.lock()
                if !didResume {
                    didResume = true
                    shouldResume = true
                }
                resumeLock.unlock()

                guard shouldResume else {
                    if logDuplicate {
                        DebugLogger.shared.warning(
                            "MediaPlaybackService: Suppressed late or duplicate media callback",
                            source: "MediaPlaybackService"
                        )
                    }
                    return false
                }

                beforeResume()
                self.mediaController.onTrackInfoReceived = nil
                self.mediaController.onListenerTerminated = nil
                self.mediaController.stopListening()
                continuation.resume(returning: value)
                return true
            }

            self.mediaController.stopListening()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if resumeOnce(false, logDuplicate: false) {
                    DebugLogger.shared.warning(
                        "MediaPlaybackService: Now Playing query timed out; leaving playback unchanged",
                        source: "MediaPlaybackService"
                    )
                }
            }

            self.mediaController.onTrackInfoReceived = { [weak self] trackInfo in
                Task { @MainActor in
                    guard let self = self else {
                        resumeOnce(false)
                        return
                    }

                    let isPlaying = trackInfo.payload.isPlaying ?? false

                    // Log what we found
                    DebugLogger.shared.debug(
                        """
                        MediaPlaybackService: Track info received
                        - App: \(trackInfo.payload.applicationName ?? "Unknown")
                        - Bundle: \(trackInfo.payload.bundleIdentifier ?? "Unknown")
                        - Title: \(trackInfo.payload.title ?? "Unknown")
                        - isPlaying: \(trackInfo.payload.isPlaying?.description ?? "nil")
                        - Determined playing: \(isPlaying)
                        """,
                        source: "MediaPlaybackService"
                    )

                    if isPlaying {
                        resumeOnce(true) {
                            DebugLogger.shared.info(
                                "MediaPlaybackService: Media is playing, sending pause command",
                                source: "MediaPlaybackService"
                            )
                            self.mediaController.pause()
                        }
                    } else {
                        DebugLogger.shared.debug(
                            "MediaPlaybackService: Media is not playing, no action needed",
                            source: "MediaPlaybackService"
                        )
                        resumeOnce(false)
                    }
                }
            }
            self.mediaController.onListenerTerminated = {
                Task { @MainActor in
                    resumeOnce(false, logDuplicate: false)
                }
            }
            self.mediaController.startListening()
        }
    }

    /// Resumes media playback only if we were the ones who paused it.
    ///
    /// - Parameter wePaused: `true` if `pauseIfPlaying()` returned `true` for this session.
    func resumeIfWePaused(_ wePaused: Bool) async {
        guard wePaused else {
            DebugLogger.shared.debug(
                "MediaPlaybackService: We didn't pause media, not resuming",
                source: "MediaPlaybackService"
            )
            return
        }

        DebugLogger.shared.info(
            "MediaPlaybackService: Resuming media playback (we paused it)",
            source: "MediaPlaybackService"
        )

        // Use explicit play() command - never toggle
        self.mediaController.play()
    }
    #else
    /// Intel Mac stub - media control not available
    func pauseIfPlaying() async -> Bool {
        DebugLogger.shared.debug(
            "MediaPlaybackService: Not available on Intel Macs",
            source: "MediaPlaybackService"
        )
        return false
    }

    func resumeIfWePaused(_ wePaused: Bool) async {
        // No-op on Intel
    }
    #endif
}
