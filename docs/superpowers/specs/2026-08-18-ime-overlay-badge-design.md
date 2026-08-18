# IME Badge in the Dictation Overlay

## Goal

Show the input source used for the active dictation session beside the target application's icon in the bottom dictation overlay. The badge is informational only; it must not change model selection, focus restoration, or typing behavior.

## User-visible behavior

- At recording start, capture the current keyboard input source together with the existing dictation session snapshot.
- While that session is active, show a compact badge immediately to the right of the target app icon.
- Prefer the input source's native macOS icon when the Input Source API supplies one.
- If the native icon is unavailable, show a country flag derived from the resolved locale (`ja-JP` → 🇯🇵, `en-US` → 🇺🇸, `zh-CN` → 🇨🇳, etc.).
- If no region can be derived, show a two-letter language code (`JA`, `EN`, `ZH`, etc.).
- Keep the badge fixed for the session. An IME change during recording does not move or replace it; the next recording captures a new badge.
- Clear the badge whenever the overlay session is cleared, using the same lifecycle points that clear `targetAppIcon`.
- The badge is hidden when there is no active target app icon or no usable input-source representation, so existing overlay layouts remain unchanged for unsupported sources.

## Architecture

### Input-source representation

Extend the keyboard input source service with a presentation-only value that contains:

- the existing source ID and resolved locale;
- an optional `NSImage` created from `kTISPropertyIconRef` when available;
- a deterministic fallback label (flag emoji first, language code second).

The existing `KeyboardInputSourceSnapshot` remains the routing/session value and does not gain an `NSImage` field, preserving its `Sendable` and test-friendly shape. Icon/label resolution happens synchronously on the main/UI side when the recording context is captured.

### Session UI state

Add an optional `recordingInputSourceBadge` value to `NotchContentState`. `ContentView` populates it immediately before creating the dictation session, after resolving the current input source. `BottomOverlayView` reads this value alongside `targetAppIcon` and renders the badge in the existing target-icon stack.

The badge value is presentation-only and is not persisted. It is reset on overlay dismissal and on any other path that resets the recording target context.

### Layout

Use an `HStack` containing the current target app icon and a small rounded badge. Keep the existing icon size and waveform position stable by giving the badge a fixed compact width and a small inter-item spacing. Use the native icon at a smaller size when present; flag/code fallback uses a legible system font and a subtle material/background so it remains readable against the overlay.

## Fallback rules

1. Native Input Source icon, if the TIS property exists and converts to an image.
2. Region flag from the locale resolved by `KeyboardInputSourceLocaleResolver`.
3. Uppercased ISO language code from that locale.
4. No badge if the source and locale are both unavailable.

The badge must never infer a different locale from `Locale.current` when a session already has a resolved input source; it uses the same source snapshot/resolver as model routing.

## Testing

- Add pure tests for locale-to-flag and locale-to-language-code conversion, including Japanese, US English, Simplified Chinese, Traditional Chinese, Korean, and an unknown/no-region locale.
- Add a test that native-icon absence selects the flag/code fallback without affecting the routing snapshot.
- Add a state lifecycle test that the badge is set at recording start and cleared with the target app icon.
- Verify the focused overlay/icon tests, the IME routing tests, strict SwiftLint, and a signed macOS build.

## Non-goals

- No settings toggle or user customization.
- No live IME switching during an active recording.
- No changes to per-IME model assignment or locale resolution rules.
- No changes to the target application's icon capture or focus restoration.
