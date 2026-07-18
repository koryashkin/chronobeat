# AGENTS.md

Guidance for coding agents working on Watch Accuracy Meter.

## Project Overview

- Native iOS app for estimating mechanical watch rate from iPhone microphone ticks.
- Swift 6, SwiftUI, AVFoundation, iOS 17+.
- No backend, login, cloud sync, or professional timegrapher claims.
- Audio must stay local and raw-preserving. Do not use voice-processing, voice-chat, or noise-cancel audio session modes that can remove mechanical tick transients.

## Repository Layout

- `Sources/WatchAccuracyMeter/`: app source.
- `Tests/WatchAccuracyMeterTests/`: unit tests and audio fixtures.
- `Tests/WatchAccuracyMeterTests/Fixtures/`: sanitized committed WAV regression fixtures only.
- `Tools/RecognitionBenchmark/`: private full-capture replay and JSON reporting.
- `Tools/TickCandidateMLExperiment/`: capture-safe Create ML feasibility evaluation.
- `Tools/CandidateReview/`: local manual tick/noise review package generation.
- `Docs/`: product and validation notes.
- `project.yml`: XcodeGen source of truth.
- `WatchAccuracyMeter.xcodeproj/`: generated project, tracked in git.

## Build And Test

After changing `project.yml`, adding source files, or adding test resources, regenerate the project:

```sh
xcodegen generate
```

Preferred validation is through XcodeBuildMCP when available:

- `session_show_defaults`
- `test_sim`
- `build_run_sim`

Shell fallback:

```sh
xcodebuild test \
  -project WatchAccuracyMeter.xcodeproj \
  -scheme WatchAccuracyMeter \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Simulator tests validate compilation, UI wiring, fixtures, and DSP regressions. Real microphone accuracy must be validated on a physical iPhone.

Replay labeled private captures without committing them:

```sh
Tools/RecognitionBenchmark/run-recognition-benchmark /path/to/manifest.json > /tmp/recognition-report.json
```

Do not treat overlapping-window results as independent. The report's acceptance
gate remains ineligible until it contains at least 100 windows from 20 unique
captures, five watches, and two devices.

Evaluate experimental candidate models without adding models or reports to git:

```sh
Tools/TickCandidateMLExperiment/run-tick-candidate-ml-experiment \
  /path/to/manifest.json \
  --model-type logistic \
  --model-output /tmp/tick-candidate.mlmodel \
  > /tmp/tick-candidate-report.json
```

The ML experiment uses whole-watch holdouts and provisional DSP labels. Its
output is research evidence only; never add a generated model to the app unless
manually reviewed labels and the end-to-end acceptance gates pass.

Generate a private manual-review package for a capture with known BPH:

```sh
Tools/CandidateReview/run-candidate-review \
  /path/to/capture.wav \
  28800 \
  /tmp/watch-review
```

The generated `review.html` contains embedded private audio. Keep the package
and exported labels outside git. Add `reviewLabelsPath` to a private ML manifest
to use reviewed events; reviewed labels may come from captures DSP rejects.

## Audio/DSP Rules

- Keep capture using `AVAudioSession` `.record` + `.measurement`.
- Prefer built-in iPhone microphone routes; warn on Bluetooth/headset routes.
- Preserve raw samples for analysis/export; perform rumble suppression, transient emphasis, noise handling, and duplicate merging inside DSP.
- Manual BPH results must run competing-BPH/harmonic checks before returning medium/high confidence.
- Future auto-BPH work should evaluate all supported BPH values and reject ambiguous winners.
- Do not show confident rate results when periodicity is weak, BPH is ambiguous, or a harmonic match is likely.
- `.measurement` disables iOS software AGC/EQ, but older iPhones may still apply hardware ALC that cannot be disabled. Keep envelope normalization windows long enough to tolerate slow gain sweeps.

## Fixtures And Captures

- Generic audio captures are ignored by `.gitignore`.
- Only commit small sanitized WAV fixtures under `Tests/WatchAccuracyMeterTests/Fixtures/`.
- Prefer trimmed 10-30s fixtures, mono 48 kHz WAV, with no private full-session recordings unless explicitly approved.
- When adding a fixture:
  - add/confirm tests that use it;
  - regenerate `WatchAccuracyMeter.xcodeproj`;
  - verify with `test_sim`;
  - keep exact `sec/day` assertions out unless a trusted reference measurement exists.

## UI Rules

- Keep the first screen as the usable measurement workflow, not a landing page.
- Show clear live audio capture evidence: sample count, seconds, RMS/peak/clipping, route.
- Debug details are allowed for now because real-device DSP tuning depends on them.
- Result quality should prioritize honesty: retry/ambiguous is better than a confident wrong rate.

## Git Hygiene

- Work on `codex/*` branches unless the user asks otherwise.
- Do not revert user changes.
- Stage only files relevant to the requested task.
- Before pushing, run `test_sim` when possible; also run `build_run_sim` for app/runtime-affecting changes.
