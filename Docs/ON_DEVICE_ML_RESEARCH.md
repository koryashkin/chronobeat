# On-device ML research for tick recognition

## Decision

Do not use an on-device large language model for audio recognition.

Use Core ML only as an experimental tick-candidate verifier inside the existing
DSP and beat-grid pipeline. The model may rank or reject candidate transients,
but deterministic grid fitting must remain responsible for BPH selection and
rate estimation.

This is a research recommendation, not evidence that ML already improves the
app. The repository does not yet contain enough independent labeled recordings
to train or validate a model without severe overfitting.

## Why an LLM is not suitable

Apple's Foundation Models framework exposes a text-oriented on-device language
model. It is intended for language understanding, structured generation, and
tool calling. It does not provide the raw-audio, sample-level event output that
this app needs. It also requires iOS 26 and an Apple Intelligence-eligible,
enabled device, while this app supports iOS 17.

Watch timing is a temporal event-detection problem. At 28,800 bph the expected
tick interval is 125 ms; across supported movements the interval ranges from
100 ms to 200 ms. The detector needs event timestamps with millisecond-scale
precision so hundreds of events can be robustly fit over a 60-second capture.
Generating text from audio summaries would add latency and nondeterminism while
discarding the timing information needed for the measurement.

## Apple ML options

### Foundation Models

Verdict: reject for recognition.

- Text-oriented, not a sample-level audio event detector.
- iOS 26 and Apple Intelligence availability would break the current iOS 17
  compatibility target.
- Model and prompt behavior can change with OS updates.
- It may eventually help explain diagnostics to a user, but it must never decide
  whether a tick happened or calculate sec/day.

### Create ML Sound Classifier and Sound Analysis

Verdict: useful only for a quick signal-presence experiment.

Create ML can train a custom `MLSoundClassifier`, and Sound Analysis can run it
locally on an audio file or stream. This is private and easy to integrate.
However, Create ML sound-classifier windows default to 0.975 seconds and cannot
be shorter than 0.5 seconds. A 0.5-second window contains roughly 2.5 to 5 watch
ticks, so the API can classify "watch present" versus "noise" but cannot provide
the individual timestamps required by the beat-grid fitter.

A Create ML classifier could improve preflight and reject captures that contain
speech, handling noise, or no watch. It should not replace tick detection.

### Custom Core ML temporal model

Verdict: recommended experiment.

Core ML supports custom PyTorch or TensorFlow models converted to an ML Program,
which is compatible with iOS 15 and therefore with this app's iOS 17 target. A
small stateless model is sufficient; iOS 18 stateful-model APIs are unnecessary.

Recommended first model:

- Input: a 2,048-sample mono waveform centered on each DSP candidate (42.7 ms
  at 48 kHz), normalized with the same capture-level statistics used by DSP.
- Backbone: a small 1D temporal convolution network with dilated residual blocks.
- Outputs: `tickProbability` and an optional sub-window timestamp correction.
- Size target: less than 250,000 parameters and less than 2 MB at Float16.
- Execution: batch inference during post-processing, never from the real-time
  audio callback.

The current detector should deliberately generate a high-recall candidate set.
Core ML then supplies a probability for each candidate. Grid fitting uses that
probability as a weight and still assigns at most one event to each expected beat
slot. Auto BPH continues to evaluate every supported BPH and reject ambiguous
winners.

```text
raw PCM
  -> raw-preserving DSP and high-recall transient candidates
  -> 42.7 ms candidate snippets
  -> Core ML tick probability and timestamp correction
  -> weighted duplicate merging
  -> deterministic beat-grid fit for every supported BPH
  -> strict confidence and ambiguity gates
```

This hybrid design lets ML learn watch-specific transient shape and reject
handling noise without asking it to learn the physical periodicity rules that
the existing fitter already expresses directly.

## Why not start with learned noise cancellation

Generic iOS voice processing and speech denoisers are trained to preserve voice,
not escapement transients. They can remove the signal of interest. A learned
time-frequency mask has the same risk and would require paired clean/noisy watch
recordings that the project does not have.

The first ML experiment should classify candidates, not rewrite raw audio. If a
candidate verifier is insufficient, a learned denoiser can be evaluated later
only with a contact-microphone reference channel and an explicit transient-recall
gate.

There is also a lower-risk DSP experiment worth running first. Published work on
mechanical-watch acoustics describes the signal as multi-component and uses
wavelet-packet and empirical-mode decomposition to expose informative low-energy
components. A small multi-band transient envelope or wavelet-packet approximation
may improve candidate separation without any training data.

## Current baseline

Offline replay on 2026-07-18 used the current `WatchDSP.analyzeAuto` implementation.
These recordings are not statistically independent, so this table diagnoses
failure modes and does not estimate product accuracy.

| Real fixture | Known BPH | Auto result | Quality | Outcome |
| --- | ---: | ---: | --- | --- |
| King Seiko, 20 s | 28,800 | 25,200 | Low, ambiguous | Fail |
| iPhone bottom mic, 20 s | 28,800 | 28,800 | Medium | Pass |
| Tudor GMT, 40-60 s | 28,800 | 28,800 | Medium | Pass |
| Tudor GMT, 30-60 s | 28,800 | 28,800 | Low, ambiguous | Fail |
| Tudor GMT, 0-60 s | 28,800 | 28,800 | Medium | Pass |

The existing real-fixture benchmark mostly exercises manual BPH. It has only a
few correlated windows and cannot prove the 90% Auto-BPH objective. The King
Seiko result also shows why training and testing on only the Tudor capture would
produce a misleading model.

## High-band periodicity experiment

The first non-ML experiment was implemented on 2026-07-18. It extracts an
8-20 kHz transient envelope independently of the normal peak detector and
measures autocorrelation at every supported BPH period. Strong evidence can add
at most 0.08 to an otherwise valid Auto-BPH candidate score. It cannot change a
low-quality grid into a usable result.

On the 20-second Tudor fixture, 28,800 bph produced a high-band correlation of
0.632; every wrong supported BPH was below zero. The iPhone bottom-mic fixture
showed the same separation. The King Seiko fixture's strongest correlation was
only 0.019, so it remains low quality rather than receiving an invented rate.

For the reconstructed Tudor capture, Auto recognition improved from one of
three 20-second windows to three of three. The formerly ambiguous 30-second
second half now returns 28,800 bph with medium quality. These are correlated
windows from one recording, so they demonstrate a useful mechanism but do not
establish an accuracy percentage.

The frozen fixture manifest is `recognition-fixtures.json`. It records source
capture groups so future training and test tooling can prevent overlapping
segments from leaking across data splits.

## Dataset and labels

### Pilot dataset

Do not train until the pilot contains at least:

- 30 independent 60-second captures;
- 5 mechanical watches, including quiet and noisy movements;
- 2 iPhone generations;
- quiet-room, ordinary-room, handling-noise, and no-watch negatives;
- repeated positions with crown, caseback, and varying contact pressure;
- trusted BPH labels for every capture;
- trusted timegrapher references for any sec/day accuracy claim.

This is enough for a feasibility experiment, not a broad production claim. Auto
BPH support across all listed rates requires real held-out recordings for every
supported BPH. Synthetic grids may augment training but cannot replace those
recordings in the test set.

### Event labels

Each candidate training example needs:

- source recording identifier;
- watch and movement identifier;
- iPhone model and microphone route;
- selected/known BPH;
- candidate sample index;
- `tick` or `noise` label;
- corrected tick sample index when the candidate is a tick;
- noise and placement tags.

High-confidence DSP grids can propose labels, but failed and ambiguous captures
must be manually reviewed. Otherwise the model will reproduce the current DSP's
mistakes. Include hard negatives from rejected resonance peaks, desk movement,
speech, taps, and rotor noise.

### Candidate trace export

Each in-app debug export now includes `candidates.json` beside `capture.wav` and
`diagnostics.json`. The trace contains candidate sample indices, normalized
envelope strength, distance to the fitted beat grid, and a provisional label.
An offline dataset tool can reconstruct each 2,048-frame waveform snippet from
`capture.wav` using `snippetCenterOffset`; snippets at file boundaries must be
zero-padded rather than shifted.

The trace collapses candidates within 5 ms and exports at most 4,000 events. It
keeps all provisional ticks and samples temporally diverse ambiguous events and
strong hard negatives. Source, merged, and exported counts are recorded so the
sampling bias remains visible during evaluation. Trace generation runs as a
utility-priority background task so it cannot block the result screen.

These labels are weak supervision, not ground truth. Low-quality captures export
only `unknown` labels. Before training, a reviewer must confirm or correct all
`likelyTick` and `likelyNoise` labels, and training code must exclude `unknown`.
The full capture remains the unit of train/validation/test splitting.

### Split policy

Never randomly split snippets or overlapping windows from one recording across
training and test sets. Split by complete capture, then hold out entire watches
and iPhone models. Report both:

- held-out-capture performance for tuning;
- held-out-watch/device performance for generalization.

## Acceptance gates

Compare DSP-only and hybrid DSP/Core ML on the same frozen test manifest.
Do not enable the model in production unless all gates pass:

1. Tick event precision at least 98% and recall at least 90%, using a +/-5 ms
   timestamp tolerance.
2. Correct Auto-BPH with non-low quality in at least 90% of at least 100 held-out
   20-second windows from at least 20 independent captures.
3. Wrong-BPH and no-watch cases never return a confident rate; wrong-BPH rejection
   must be at least 95%.
4. At least a 10 percentage-point improvement over DSP-only Auto recognition on
   the frozen real-audio test set.
5. No regression in high-confidence King Seiko, Tudor, or synthetic stress tests.
6. Post-processing remains below 30 seconds on the oldest supported physical
   iPhone, with peak memory recorded.
7. Sec/day error is evaluated separately against a trusted timegrapher. Recognition
   success alone must not be presented as timing accuracy.

## Implementation sequence

1. Add a versioned fixture manifest and an offline evaluator that exports candidate
   snippets, labels, per-capture outcomes, and DSP-only baseline metrics.
2. Extend the validated high-band periodicity path into a multi-band candidate
   source only if additional captures show that candidate recall remains the
   limiting factor.
3. Collect and label the pilot dataset, keeping private full captures outside git.
4. Train the candidate verifier off-device and convert it to an iOS 17 ML Program.
5. Add a `TickCandidateScoring` protocol with DSP-only and Core ML implementations.
6. Run the frozen benchmark in DSP-only, ML-only diagnostic, and hybrid modes.
7. Ship only if the acceptance gates pass; otherwise retain the data and remove the
   runtime model integration.

## Primary sources

- [Apple Foundation Models](https://developer.apple.com/documentation/FoundationModels)
- [Apple SystemLanguageModel availability](https://developer.apple.com/documentation/FoundationModels/SystemLanguageModel)
- [Apple MLSoundClassifier](https://developer.apple.com/documentation/createml/mlsoundclassifier/)
- [Apple sound-classifier window size](https://developer.apple.com/documentation/createml/mlsoundclassifier/modelparameters-swift.struct/featureextractiontimewindowsize)
- [Apple Sound Analysis](https://developer.apple.com/documentation/soundanalysis/)
- [Apple Core ML Tools: ML Programs](https://apple.github.io/coremltools/docs-guides/source/convert-to-ml-program.html)
- [Sound Event Detection: A Tutorial](https://arxiv.org/abs/2107.05463)
- [Mono-component signal extraction and analysis of mechanical watch movements](https://research.cuhk.edu.hk/en/publications/mono-component-signal-extraction-and-analysis-of-mechanical-watch-2/)
