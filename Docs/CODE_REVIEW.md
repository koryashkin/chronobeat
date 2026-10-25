# Repository code review

Review baseline: `12ae8ee` (2026-10-25). Scope: the iOS app, DSP, audio capture and export, research tools, tests, XcodeGen configuration, and public repository files. This review is based on source inspection and simulator tests; real microphone accuracy still requires a physical iPhone and reference measurements.

## Summary

The app keeps recording and analysis local, uses the raw-preserving `.record` / `.measurement` audio session, and hides the rate when signal quality is Low. Its synthetic and sanitized WAV fixtures cover many DSP regressions. The open issues below matter before the quality labels or `sec/day` output can be presented as validated watch accuracy.

## Open findings

### 1. High: a clean-looking manual grid can bypass the final competing-rate check

`WatchDSP.analyze(samples:selectedBPH:)` compares a non-Low manual result with Auto BPH. If Auto is Low or ambiguous, it falls through to `beatRateCompetition` (`WatchDSP.swift`, lines 483–511). That function returns without examining another beat rate when the manual result is High, its candidate count matches, outliers are at most 0.25, and periodicity is at least 0.80 (lines 1694–1702). A strong harmonic or dual-periodic signal can therefore remain High in manual mode even though Auto could not choose a rate. The code does not satisfy the repository rule that every Medium/High manual result must complete competing-BPH and harmonic checks.

**Recommended change:** Evaluate all supported competing rates before accepting every non-Low manual result. Treat an ambiguous Auto result as evidence requiring an explicit manual-rate margin, and add a regression fixture or synthetic dual-grid case for this path.

### 2. Medium: the analysis deadline does not stop CPU work

`MeasurementViewModel.analyzeWithDeadline` cancels the detached task on timeout or user cancellation (`MeasurementViewModel.swift`, lines 269–299). The task runs a synchronous `WatchDSP` operation, and `WatchDSP.swift` contains no cancellation checkpoints. The UI can leave the analyzing state while that operation continues. Repeated retries can overlap expensive full-capture analyses and retain their audio buffers until each finishes.

**Recommended change:** Add cooperative cancellation checks at bounded points in DSP analysis, or run analysis through an operation whose lifetime can be enforced. Test that a timed-out full-capture analysis actually stops consuming work, not just that the UI changes state.

### 3. Medium: microphone data-source changes are not detected

`AudioWatchMeter.inputRouteIdentity` records only input port UID and port type (`AudioWatchMeter.swift`, lines 258–262). Route-change validation compares that identity (lines 205–217). A switch between built-in microphone data sources can keep the same port identity while changing the acoustic input during the one-minute recording.

**Recommended change:** Include the selected data-source identity in the expected route, and fail or restart a capture when it changes. Validate this on a physical iPhone.

### 4. Medium: live capture diagnostics are calculated but not shown

`MeasurementViewModel` publishes live RMS, peak, clipping ratio, and route warning (`MeasurementViewModel.swift`, lines 75–81 and 395–411). During measurement, `ContentView` shows sample count and recorded seconds, plus a warning only when the route is unsupported (`ContentView.swift`, lines 70–89 and 119–150). It does not show the actual route or live RMS, peak, and clipping, despite the repository's UI guidance. A user cannot distinguish quiet ticks from loud background sound using the current capture screen.

**Recommended change:** Show the input route and compact live level/clipping indicators during recording, with clear guidance when the signal is too quiet or clips.

### 5. Medium: the percentage labeled “Recognition confidence” is not calibrated

`WatchDSP.recognitionConfidence` is a weighted combination of quality score, coverage, estimated recall, and periodicity (`WatchDSP.swift`, lines 2256–2268). The result screen displays it as a percentage (`ContentView.swift`, line 190). No held-out data calibrates it as a probability that the BPH or `sec/day` estimate is correct. Public readers may reasonably interpret “90% confidence” as a validated accuracy statement.

**Recommended change:** Call it a heuristic recognition score in the UI and export, or calibrate it against independent labeled captures before using probability language.

### 6. Medium: GitHub Actions does not verify the app

`.github/workflows/placeholder.yml` runs only an informational `echo`. A green workflow therefore says nothing about build, tests, or project generation.

**Recommended change:** Replace it with a macOS workflow that checks XcodeGen output and runs the simulator test scheme, or remove the placeholder until CI is available.

### 7. Low: benchmark “passed” can be read more strongly than its evidence supports

`Tools/RecognitionBenchmark/main.swift` sets `acceptanceGatePassed` from an aggregate rate over overlapping windows plus minimum counts (lines 229–251). It does not require every capture to have watch and device IDs, nor does it report a held-out watch/device result in that flag. The report caveat correctly notes correlation, but downstream readers may quote the Boolean without it.

**Recommended change:** Make capture identifiers mandatory for an eligible gate, report capture-level and held-out summaries, and reserve `acceptanceGatePassed` for the complete protocol.

### 8. Low: repeated export reuses the same directory

`AudioCaptureExporter.export` names a folder from the capture timestamp with one-second precision (`AudioCaptureExporter.swift`, lines 18–26 and 129–136). Exporting the same measurement twice targets the same files, so a later export can overwrite an earlier package.

**Recommended change:** Create a unique directory per export or explicitly reuse a completed export rather than writing it again.

## Validation and remaining evidence

- XcodeBuildMCP simulator suite on an iPhone 17 Pro simulator: **78 passed, 0 failed, 0 skipped** on 2026-10-25. This confirms the current regression suite, not the absence of the code paths described above.
- The app has no network or analytics integration in the tracked source. Audio is written to a debug package only from the explicit export action.
- Existing tests exercise synthetic watch rates, ambiguous and harmonic cases, real sanitized fixture regressions, capture state, and export format.
- The current fixtures span too few independent watches and devices to establish the published acceptance gate. Overlapping windows must not be counted as independent recordings.
- Physical iPhone microphone routing, post-processing time on the oldest supported device, and `sec/day` error against a trusted timegrapher remain unverified in this repository.

The [README](../README.md) describes the current product behavior and validation limits for GitHub readers. This review records implementation gaps without changing the measurement algorithm.
