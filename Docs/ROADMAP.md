# Roadmap

## v0.1 — technical proof of concept

- iOS only
- microphone permission
- AVAudioEngine input capture
- manual BPH selection
- 60-second measurement
- sec/day output
- signal quality gate

## v0.2 — debugging and calibration

- waveform/envelope debug screen
- detected peak overlay
- audio route warning
- repeated measurement comparison
- export debug JSON

## v0.3 — collector usefulness

- optional local measurement history
- position label per measurement
- better retry guidance
- optional estimated beat error when confidence is high

## v0.4 - experimental on-device recognition

- add a versioned real-capture benchmark manifest
- use independent high-band periodicity to resolve strong Auto-BPH evidence
- use guarded two-beat tick/tock consensus for alternating escapement transients
- evaluate a multi-band candidate detector on additional quiet watches
- collect and label tick/noise candidate snippets
- train a small custom Core ML candidate verifier
- compare DSP-only and hybrid recognition on frozen held-out captures
- keep deterministic beat-grid fitting and strict ambiguity rejection
- do not ship ML unless it meets the gates in `ON_DEVICE_ML_RESEARCH.md`

## v0.5 — experimental motion-assisted recognition

- capture raw Core Motion accelerometer samples alongside microphone audio
- support an optional physical-contact mode with the watch caseback touching the iPhone
- synchronize accelerometer timestamps with the audio capture timeline
- export motion samples and diagnostics with debug captures
- detect motion periodicity independently and add synthetic motion regression tests
- validate across labeled physical-device recordings before motion affects confidence
- use motion only to confirm or reject audio results, never as a microphone replacement
- keep audio-only behavior unchanged when motion data is unavailable or inconclusive

## Not before v1

- amplitude
- cloud sync
- movement database
- paid features
- Android
