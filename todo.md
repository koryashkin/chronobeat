# TODO — Code & Architecture Review

> Full senior/architect review pass. Ranked by severity.

## Progress

### 2026-07-13

Fixed on `codex/mvp-simulator-tests`:

- Bugs: 1, 2, 3, 4, 5, 6, 7, 8.
- Code quality / cleanup: 14, 15, 17.
- Low priority / nice-to-have: 20.
- Audio engineering: A7, A10.

### 2026-07-15

Fixed on `codex/mvp-simulator-tests`:

- Code quality / cleanup: 11, 12, 13, 16.
- Audio engineering: A1, A3, A4, A5, A6, A8, A9.

Partially improved:

- Architecture / Design: 10 (named the Auto/DSP preprocessing thresholds touched in this pass; broader quality thresholds still need centralization).
- Audio engineering: A2 (moved `ProcessInfo.processInfo.systemUptime` outside the lock; the larger lock-free/priority-inheritance work remains).

---

## Bugs (correctness)

### 1. UI permanently stuck on "Analyzing ticks…" after cancel
**File:** `Sources/WatchAccuracyMeter/MeasurementViewModel.swift:138`  
If the measurement task is cancelled while `Task.detached` DSP is in flight, `finishMeasurement` hits `guard !Task.isCancelled else { return }` and returns without resetting state. `cancelMeasurement()` already nils `measurementTask`, so nothing ever drives the state back to `.idle`. The app hangs on the analyzing screen until force-quit.  
**Fix:** Replace the bare `return` with `state = .idle`.

---

### 2. Double `audioMeter.stop()` on cancel → can tear down a new measurement
**File:** `Sources/WatchAccuracyMeter/MeasurementViewModel.swift:90`  
`cancelMeasurement()` calls `audioMeter.stop()` immediately (line 94), but the cancelled task's `CancellationError` catch block also calls `audioMeter.stop()` (line 82). The second call deactivates an `AVAudioSession` that is already inactive — or, if a new measurement started in between, tears down the new engine.  
**Fix:** Remove the direct `audioMeter.stop()` from `cancelMeasurement()` and rely solely on the cancellation path; or set a flag that suppresses the catch-block stop after an explicit cancel.

---

### 3. RANSAC refinement computes residuals against the previous iteration's regression line
**File:** `Sources/WatchAccuracyMeter/WatchDSP.swift:905`  
After `pairs = reassigned.pairs` is accepted on line 901, the residual computation on line 905 still uses the old `intercept`/`slope`. Outlier filtering in each iteration therefore uses a stale model, causing inliers to be dropped (or outliers kept) across iterations 2–4, degrading the period estimate.  
**Fix:** Accept the new slope/intercept returned by `linearRegressionSlope/Intercept` before computing residuals, or restructure so residuals are computed after updating the model.

---

### 4. Off-by-one "median" — uses upper element for even-count arrays
**File:** `Sources/WatchAccuracyMeter/WatchDSP.swift:907` (also line 1012 in `assignPeaksToGrid`)  
`residuals[residuals.count / 2]` is floor division. For N=2 this returns the maximum, not the median, inflating `medianResidual * 3.5` and making outlier thresholds too loose.  
**Fix:** Use `(residuals[count/2 - 1] + residuals[count/2]) / 2` for even counts, or just use `residuals[(count - 1) / 2]` for a lower-median which is acceptable here.

---

### 5. `analyzeAuto` skips `beatRateCompetition` — violates AGENTS.md audio/DSP rule
**File:** `Sources/WatchAccuracyMeter/WatchDSP.swift:183`  
All 6 candidates are analyzed with `checksCompetingBeatRates: false`. The score-margin ambiguity gate (`margin < 0.06`, etc.) is a weaker substitute for the full harmonic competition check. AGENTS.md states: *"Do not show confident rate results when … a harmonic match is likely."* A watch at 36000 bph whose half-rate (18000) candidate scores 0.07 below it can be returned at `.medium`/`.high` confidence without any harmonic guard.  
**Fix:** After picking the winner in `analyzeAuto`, run `beatRateCompetition` on it against the remaining candidates before returning.

---

### 6. Auto mode: `.ambiguousBeatRate` overwrites actionable failure reasons
**File:** `Sources/WatchAccuracyMeter/WatchDSP.swift:212`  
When the ambiguity gate fires, `replacing(..., dominantFailureReason: .ambiguousBeatRate)` is applied unconditionally, even when the underlying result carries `.tooQuiet` or `.clipping`. The user sees "Try another measurement with the watch closer" instead of "Audio is clipping — move the watch farther away."  
**Fix:** Only set `.ambiguousBeatRate` when the underlying `dominantFailureReason` is `nil` or `.unstableGrid`.

---

### 7. Early-recording peaks systematically dropped in `assignPeaksToGrid`
**File:** `Sources/WatchAccuracyMeter/WatchDSP.swift:991`  
`slot = Int(round((peak - phase) / period))` can be negative when a peak's absolute time is less than the phase value (up to one full period). The `guard slot >= 0` silently discards these ticks, reducing `beatCoverage` and `validPeakCount` for the opening second of every recording.  
**Fix:** Allow negative slots by shifting the grid: find the minimum slot and subtract it so all slots are non-negative, or clamp phase to `normalizedPhase(peaks.first, period:)`.

---

### 8. Data race on `FakeAudioMeter.latestLevels` in tests
**File:** `Tests/WatchAccuracyMeterTests/WatchDSPTests.swift:752`  
`FakeAudioMeter` is `@unchecked Sendable` but `latestLevels` is an unprotected `var`. The timer task reads it via `MainActor.run { updateCaptureStatus() }` while `start()` can write it from a different executor. The real `AudioWatchMeter` guards this with `NSLock`; the fake does not, introducing a data race in tests that diverges from production behavior.  
**Fix:** Either add `NSLock` protection or make `latestLevels` a `let` set at init time (sufficient for test purposes).

---

## Architecture / Design

### 9. `WatchMeasurementResult` — 27-field flat struct is fragile to construct and copy
**File:** `Sources/WatchAccuracyMeter/WatchDSP.swift:86`  
The struct has 27 fields. It is constructed in 3 different call sites and copied wholesale by `replacing(result:...)` just to change 1–5 fields. Any new field requires updating every construction site and `replacing`. The diagnostic fields (threshold, envelope stats, window counts, route) could be in a nested `DiagnosticsSnapshot` struct, leaving a compact primary result.  
**Fix:** Extract a `DSPDiagnostics` sub-struct. Consider making `WatchMeasurementResult` a class (reference semantics) or using a builder to avoid `replacing`.

---

### 10. Quality thresholds are magic numbers scattered across 4 functions
**File:** `Sources/WatchAccuracyMeter/WatchDSP.swift` (lines 206–209, 315–317, 762–769, 812–818)  
Values like `0.58`, `0.06`, `0.80`, `0.70`, `0.50`, `0.60`, `0.25` appear as bare literals in `analyzeAuto`, the quality classifier, and `beatRateCompetition`. They are the knobs that control false-positive/recall tradeoffs but are invisible unless you grep for them.  
**Fix:** Collect them in a `private enum QualityThresholds` or a `DSPConfiguration` struct so they can be understood and tuned together.

---

## Code Quality / Cleanup

### 11. `stabilityScore` block copy-pasted three times with silent scaling divergence
**File:** `Sources/WatchAccuracyMeter/WatchDSP.swift:693, 718, 1110`  
The windowRates mean → variance → stdev computation is duplicated three times. The copies have silently diverged: the first two normalize against `/15.0` (score in [0,1]), the third uses `/8.0` (score in [0,100]). Future tuning will require three separate edits.  
**Fix:** Extract `windowRateStabilityScore(windowRates: [Double]) -> Double` and a separate `windowRateStability100(...)` for the 0-100 scale.

---

### 12. `linearRegressionSlope/Intercept` compute `meanN`/`meanT` redundantly
**File:** `Sources/WatchAccuracyMeter/WatchDSP.swift:1039–1057`  
`linearRegressionSlope` performs two `map+reduce` passes for `meanN` and `meanT`. `linearRegressionIntercept` then recomputes both means again. Across 4 RANSAC iterations on potentially thousands of pairs, this is 4× redundant work on the hot path.  
**Fix:** Merge into a single `linearRegression(pairs:) -> (slope: Double, intercept: Double)?` that computes means once.

---

### 13. `cancelMeasurement()` and `reset()` duplicate nearly all logic
**File:** `Sources/WatchAccuracyMeter/MeasurementViewModel.swift:90, 98`  
Both functions cancel the task, cancel the timer, and reset state. `cancelMeasurement` also calls `audioMeter.stop()` and then calls `reset()`. The duplication risks them drifting out of sync.  
**Fix:** Have `cancelMeasurement()` cancel the task and stop audio, then call a private `resetState()` that handles the `@Published` fields.

---

### 14. `start()` calls `resetSamples(reservingCapacity: nil)` then immediately again with a real capacity
**File:** `Sources/WatchAccuracyMeter/AudioWatchMeter.swift:65, 83`  
The first call on line 65 allocates and immediately discards the array. The real capacity is only known after the engine format is read on line 82.  
**Fix:** Remove the first `resetSamples(reservingCapacity: nil)` call; only call on line 83 with the known capacity.

---

### 15. `configurePreferredBuiltInInput` called twice in `start()` — first call is a no-op
**File:** `Sources/WatchAccuracyMeter/AudioWatchMeter.swift:72, 74`  
The call on line 72 fires before `session.setActive(true)`, so `setPreferredInput` is silently ignored by iOS (session not yet active). Only the second call on line 74 is effective. The dead first call will mislead a future refactor.  
**Fix:** Remove the call on line 72.

---

### 16. UI hardcodes "60 sec" instead of deriving from `measurementDuration`
**File:** `Sources/WatchAccuracyMeter/ContentView.swift:55, 69`  
`"Start 60 sec measurement"` and `"Listening… / 60 sec"` both hardcode 60. The `MeasurementViewModel` accepts `measurementDuration` as a parameter (used in tests with 0.01s). When duration changes, the labels silently stay wrong.  
**Fix:** Expose `measurementDuration` as a `@Published` or let property and use it in the label strings.

---

### 17. `autoBeatRateScore` uses `detectedPeakCount` (candidate count) where `validPeakCount` is more meaningful
**File:** `Sources/WatchAccuracyMeter/WatchDSP.swift:1157`  
`autoBeatRateScore` feeds `result.detectedPeakCount` into `candidateCountMatch`. `detectedPeakCount` is the raw above-threshold candidate count (including spurious peaks), not the fitted/valid count. For a noisy signal, a BPH with many spurious candidates will score higher than one with fewer but well-fitted peaks, potentially picking the wrong beat rate.  
**Fix:** Use `result.validPeakCount` in the `candidateCountMatch` call inside `autoBeatRateScore`, or use a blend of both.

---

## Low priority / nice-to-have

### 18. `phaseCandidates` uniqueness dedup is O(n²)
**File:** `Sources/WatchAccuracyMeter/WatchDSP.swift:971`  
`uniqueCandidates.contains(where:)` inside a loop over ~134 candidates is O(n²). Not a performance problem at current scale, but worth noting for maintainability.

### 19. `liveLevelText` is a separate `@Published String` derived from the audio level
**File:** `Sources/WatchAccuracyMeter/MeasurementViewModel.swift:10, 68`  
It is set via a `Task { @MainActor }` dispatch in the audio tap callback, adding a heap allocation + async hop per buffer. It could be a computed property derived from `liveRmsLevel` in the view layer.

### 20. `stopForInactiveScene` is a no-op during `.analyzing`
**File:** `Sources/WatchAccuracyMeter/MeasurementViewModel.swift:113`  
`requiresForegroundAudioSession` returns `false` for `.analyzing`, so backgrounding mid-analysis leaves an orphaned detached DSP task running (or suspended). On return, state may flip to `.result` while the user is away, or stay stuck if the OS killed the burst. Consider cancelling the measurement task on background regardless of state.

---

## Audio Engineering

### A1. No route-change observer — engine silently dies mid-measurement
**File:** `Sources/WatchAccuracyMeter/AudioWatchMeter.swift:63`  
No `AVAudioEngineConfigurationChange` or `AVAudioSession.routeChangeNotification` observer is registered. When the user plugs in wired headphones (or unplugs them) mid-measurement, iOS fires `AVAudioEngineConfigurationChange` and auto-stops the render graph. The tap callback silently stops delivering buffers, `samples` accumulates only a partial capture, and the 60 s sleep in `runMeasurement` completes normally. Analysis runs on a truncated buffer, but the result reports the original route (builtInMic) with no indication of what happened.  
**Fix:** Register an observer on `AVAudioEngineConfigurationChange` in `start()`. On receipt, cancel the measurement task with a new `AudioMeterError.routeChangedDuringCapture` error so the user sees a clear failure message.

---

### A2. `NSLock` on the real-time audio render thread — priority inversion risk
**File:** `Sources/WatchAccuracyMeter/AudioWatchMeter.swift:121`  
The entire per-sample processing loop (all ~960 `samples.append()` calls per callback) runs inside `lock.lock()`. `NSLock` wraps a POSIX `pthread_mutex` which has **no priority inheritance**. The audio render thread runs at real-time priority under a hard deadline. If the main thread holds the lock during `resetSamples()`, the audio thread blocks with no priority boost to the owner — a textbook priority inversion. Missing the audio hardware deadline causes a glitch or engine watchdog termination. Additionally, `ProcessInfo.processInfo.systemUptime` (a syscall) is called while the lock is held, which is non-deterministic.  
**Minimum fix:** Replace `NSLock` with `OSAllocatedUnfairLock` (iOS 16+), which supports priority promotion. Move `ProcessInfo.processInfo.systemUptime` outside the lock.  
**Ideal fix:** Use a lock-free SPSC ring buffer — a pre-allocated `UnsafeMutableBufferPointer<Float>` with an atomic write index. The audio thread advances the index with an atomic store; the main thread reads up to the last committed index. Eliminates all locking on the hot path.

---

### A3. HP filter cutoff too low — passes 80–300 Hz room noise
**File:** `Sources/WatchAccuracyMeter/WatchDSP.swift:443`  
The formula `max(40, min(180, sampleRate/600))` evaluates to **80 Hz at 48 kHz** always (`48000/600 = 80`; the 180 Hz ceiling is never reached). Watch tick energy starts at ~500 Hz–1 kHz. The main interference sources are HVAC and room noise at 80–300 Hz, which this cutoff barely touches. Raising to 150–200 Hz would improve noise rejection without affecting tick energy.  
**Fix:** Change the formula to a named constant set to 150–200 Hz.

---

### A4. First-order HP filter — insufficient rumble rejection
**File:** `Sources/WatchAccuracyMeter/WatchDSP.swift:447`  
A single first-order IIR HP gives −20 dB/decade rolloff. At 20 Hz with an 80 Hz cutoff, attenuation is only ~12 dB — insufficient for handling noise or proximity to HVAC vents. A second-order (cascaded) HP would give ~24 dB at 20 Hz with minimal added code.  
**Fix:** Cascade a second identical first-order HP stage after the existing one.

---

### A5. Derivative coefficient 0.90 adds ~+16 dB high-frequency noise boost
**File:** `Sources/WatchAccuracyMeter/WatchDSP.swift:453`  
`transient = hp * 0.35 + derivative * 0.90`. The derivative term has gain ~2.15 at Nyquist (≈ +15.7 dB). For strong signals (watch caseback pressed against mic) this sharpens transient onsets helpfully. For weak signals (watch held at distance) it amplifies ADC noise by ~16 dB, pushing tick transients below the detection threshold.  
**Fix:** Reduce the derivative coefficient to 0.5–0.6, or band-limit the derivative path with a 2-tap LP (`0.5*(hp[n] + hp[n-1])`) before differencing to preserve onset sharpening while capping noise gain above ~12 kHz.

---

### A6. AirPods / BT HFP route allows silent garbage measurements
**File:** `Sources/WatchAccuracyMeter/AudioWatchMeter.swift:202`  
When AirPods or Bluetooth is the input, iOS uses HFP which limits bandwidth to 8–16 kHz with heavy codec compression. Watch tick transients (energy up to >10 kHz) are partially aliased. The code correctly sets `routeWarning` and maps it to `RecognitionIssue.unsupportedRoute`, but the full 60 s capture still runs and produces a meaningless result.  
**Fix:** Consider cancelling immediately after `start()` when `routeWarning != nil`, returning a `.low` quality result with `dominantFailureReason: .unsupportedRoute` and no rate claim — saving the user 60 s of pointless waiting.

---

### A7. Channel averaging dilutes the stronger capsule for contact pickup
**File:** `Sources/WatchAccuracyMeter/AudioWatchMeter.swift:124`  
The tap mixes all channels by summing and dividing. On devices where one capsule is physically closer to the tick source, the farther capsule's signal averages in with lower amplitude, losing 3–6 dB SNR. `setPreferredDataSource` and `setPreferredInput` already configure iOS to deliver the preferred capsule on bus 0.  
**Fix:** Use `channelData[0][i]` directly instead of averaging, trusting the session's preferred-input configuration. The averaging is actively counterproductive once the correct capsule is selected.

---

### A8. No pre-roll SNR gate — user waits full 60 s on a silent recording
**File:** `Sources/WatchAccuracyMeter/MeasurementViewModel.swift:77`  
No early-exit check exists. If the watch is too far from the mic, the user waits the full 60 s before seeing the "too quiet" failure. The existing `dominantFailureReason` system handles this correctly post-hoc; this is a UX gap.  
**Fix:** After a ~5 s pre-roll, sample `audioMeter.latestLevels` and check `peakLevel < 0.002`. If too quiet, cancel with an actionable early message.

---

### A9. Hardware ALC on older iPhones not detectable or disableable
**File:** `Sources/WatchAccuracyMeter/AudioWatchMeter.swift:69`  
`.measurement` mode disables iOS **software** AGC/EQ. On iPhone 11 and earlier, hardware ALC (Automatic Level Control) cannot be disabled via `AVAudioSession`. Loud tick transients can trigger 1–2 s gain sweeps of ±6 dB, causing amplitude variation that the `normalizeEnvelope` 750 ms window partially — but not fully — compensates for. No public API fix exists.  
**Action:** Document this hardware limitation in `AGENTS.md` so future contributors understand why normalization windows were chosen at their current sizes.

---

### A10. Capacity guard missing before `samples.append` on real-time thread
**File:** `Sources/WatchAccuracyMeter/AudioWatchMeter.swift:129`  
The buffer is pre-allocated to 65 s. If `Task.sleep` oversleeps significantly (suspended process, debugger), `samples.append()` beyond capacity triggers a `malloc`/`memcpy`/`free` reallocation on the real-time audio thread — all non-RT-safe. In practice the margin is large, but a guard is trivial.  
**Fix:** Add `guard samples.count < samples.capacity else { return }` before appending to silently drop overflow frames.
**File:** `Sources/WatchAccuracyMeter/MeasurementViewModel.swift:113`  
`requiresForegroundAudioSession` returns `false` for `.analyzing`, so backgrounding mid-analysis leaves an orphaned detached DSP task running (or suspended). On return, state may flip to `.result` while the user is away, or stay stuck if the OS killed the burst. Consider cancelling the measurement task on background regardless of state.
