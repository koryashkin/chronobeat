# Watch Accuracy Meter — iOS MVP Technical Document

## 1. Goal

Build a native iOS MVP that measures whether a mechanical watch is running fast or slow using the iPhone built-in microphone.

The MVP answers one question:

> How many seconds per day is this mechanical watch gaining or losing?

The product must be honest: it is a phone-based estimate, not a replacement for a professional timegrapher.

## 2. MVP Scope

In scope:

- iOS only
- Native Swift + SwiftUI
- AVFoundation microphone capture
- Manual BPH selection
- 60-second measurement
- On-device DSP
- Rate result in seconds per day
- Detected BPH
- Signal quality gate
- Retry guidance

Out of scope:

- Android
- Backend
- User accounts
- Watch profiles
- History
- Charts
- CSV export
- Camera mode
- Amplitude
- Professional watchmaker diagnostics

## 3. Core Technical Architecture

```text
Built-in iPhone microphone
→ AVAudioSession configured for recording / measurement
→ AVAudioEngine input tap
→ Float32 PCM buffers
→ local sample buffer
→ DSP analysis
→ tick candidate detection
→ robust beat-grid fit
→ seconds/day result
→ confidence gate
```

The app should process audio locally and should not upload or store raw recordings by default.

## 4. iOS Audio Capture

Use `AVAudioSession` and `AVAudioEngine`.

Recommended session setup:

```swift
let session = AVAudioSession.sharedInstance()
try session.setCategory(.record, mode: .measurement, options: [])
try session.setPreferredSampleRate(48_000)
try session.setPreferredIOBufferDuration(0.02)
try session.setActive(true)
let actualSampleRate = session.sampleRate
```

Important engineering notes:

- `setPreferredSampleRate` is a request, not a value to blindly assume.
- Always read the actual sample rate after activating the session.
- Use the built-in iPhone microphone.
- Warn if the audio route is Bluetooth or otherwise unsuitable.
- Keep processing local and foreground-only.

The input stream should be captured with `AVAudioEngine.inputNode.installTap` and converted to a mono Float32 sample stream.

## 5. Measurement Flow

1. User selects BPH.
2. User taps Start.
3. App requests microphone permission if needed.
4. App starts AVAudioEngine.
5. App records approximately 60 seconds of PCM samples.
6. App stops recording.
7. DSP analyzes the captured sample buffer.
8. App shows result only if confidence is sufficient.

Supported manual BPH values:

- 18,000
- 19,800
- 21,600
- 25,200
- 28,800
- 36,000

Default value: 28,800 BPH.

## 6. DSP Pipeline

The first implementation should be simple but honest.

```text
Raw Float32 PCM
→ DC offset removal
→ high-pass / transient-emphasis filter
→ envelope extraction
→ adaptive threshold
→ candidate peak detection
→ duplicate peak rejection
→ beat index assignment
→ robust linear regression
→ seconds/day calculation
→ signal quality calculation
```

## 7. Tick Timing Model

Do not calculate the rate by simply taking the median interval between detected peaks.

Use a beat-grid timing model:

```text
time_of_beat[n] = t0 + n * beat_period + error
```

Estimate `beat_period` using robust linear regression over detected tick timestamps.

This is more stable because it reduces the damage from:

- missed ticks
- doubled peaks
- case resonance
- one-off noise spikes
- small local jitter

## 8. Rate Calculation

Expected interval:

```text
expected_period = 3600 / selected_bph
```

Detected BPH:

```text
detected_bph = 3600 / detected_period
```

Rate:

```text
rate_seconds_per_day = (detected_bph / selected_bph - 1) * 86400
```

Example:

```text
selected_bph = 28800
detected_bph = 28803
rate = +9 sec/day
```

Positive value means the watch runs fast. Negative value means the watch runs slow.

## 9. Signal Quality Gate

Signal quality is mandatory. The app should not show overconfident numbers from bad audio.

Quality should consider:

- number of valid detected beats
- outlier ratio
- stability across measurement windows
- match with selected BPH
- approximate signal-to-noise behavior

Labels:

- High: show result normally
- Medium: show approximate result and recommend repeating
- Low: do not trust result; ask user to retry

Target for first useful prototype:

> High-confidence repeated measurements on the same watch, same position, same room should be stable within approximately ±3–5 sec/day.

## 10. MVP Result Screen

Show:

```text
+8 sec/day
Signal quality: High
Selected beat rate: 28,800 bph
Measured beat rate: 28,802.7 bph
```

Do not show amplitude in MVP.

Beat error should also be hidden in v0.1 unless the detector is validated against a real timegrapher.

## 11. Privacy Requirements

- Ask microphone permission clearly.
- Process audio on device.
- Do not upload audio.
- Do not save raw audio by default.
- Do not record in background.
- Stop the audio engine when measurement ends or the view disappears.

Suggested microphone permission copy:

> This app uses the microphone to listen to your watch ticking. Audio is processed on your device and is not uploaded.

## 12. Engineering Build Plan

### Phase 1 — Debug prototype

Build an ugly but useful iOS debug app:

- microphone permission
- AVAudioEngine capture
- live audio level
- manual BPH selector
- 60-second sample buffer
- DSP analysis
- debug stats

Debug stats:

- actual sample rate
- captured sample count
- detected peaks
- valid peaks
- outlier ratio
- estimated BPH
- rate sec/day
- quality score

### Phase 2 — DSP hardening

Improve:

- thresholding
- duplicate peak rejection
- robust fit
- window-to-window stability
- confidence scoring

### Phase 3 — MVP UI

Build simple consumer UI:

- instruction screen
- measuring screen
- result screen
- retry flow

### Phase 4 — Validation

Test:

- one known good 28,800 BPH watch
- one vintage watch
- at least two iPhone models
- quiet room vs noisy room
- repeated measurements
- comparison with a real timegrapher if available

## 13. Acceptance Criteria

MVP v0.1 is acceptable when:

- app runs on real iPhone
- microphone permission works
- AVAudioEngine captures live PCM samples
- 60-second measurement completes
- DSP returns sec/day and measured BPH
- low-quality signal is rejected or clearly marked
- repeated high-quality measurements are reasonably stable
- no raw audio leaves the device

## 14. Main Risk

The main risk is not microphone access. The main risk is repeatability.

A viable app must avoid this pattern:

```text
Measurement 1: +6 sec/day
Measurement 2: +28 sec/day
Measurement 3: -11 sec/day
```

The product succeeds only if the confidence gate can separate good measurements from bad ones.

## 15. References

- Apple Developer Documentation — AVAudioSession
- Apple Developer Documentation — AVAudioSession.Mode.measurement
- Apple Developer Documentation — AVAudioEngine
- Apple Developer Documentation — Microphone recording permission
