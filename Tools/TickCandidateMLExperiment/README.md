# Tick candidate ML experiment

This macOS-only research tool evaluates compact Create ML classifiers over
candidate transients. It regenerates provisional candidate labels from raw WAVs,
extracts fixed-rate features, holds out complete watches, and emits JSON.

It does not alter the iOS app or prove product accuracy. Provisional DSP labels
must be manually reviewed before training a production candidate verifier.

## Manifest

Use the same private manifest format as `Tools/RecognitionBenchmark`:

```json
{
  "schemaVersion": 1,
  "captures": [
    {
      "id": "watch-run-01",
      "path": "/absolute/path/to/capture.wav",
      "knownBPH": 28800,
      "watchID": "stable-watch-identifier",
      "deviceID": "iphone-model-or-test-device",
      "reviewLabelsPath": "/optional/path/to/reviewed-labels.json"
    }
  ]
}
```

Every capture needs `watchID` and `deviceID`. Duplicate capture IDs and paths
are rejected. At least two watches are required so no snippets from the held-out
watch can leak into training.

When `reviewLabelsPath` is present, only reviewed `tick` and `noise` events are
used. `unsure` and unreviewed events are ignored. Reviewed events remain usable
when DSP is low or selects a different BPH. Without that path, the tool uses
provisional grid labels and requires DSP to recognize the known BPH.

## Run

Logistic regression is the compact baseline:

```sh
Tools/TickCandidateMLExperiment/run-tick-candidate-ml-experiment \
  /path/to/manifest.json \
  --model-type logistic \
  --model-output /tmp/tick-candidate.mlmodel \
  > /tmp/tick-candidate-logistic.json
```

Run the controlled nonlinear comparison separately:

```sh
Tools/TickCandidateMLExperiment/run-tick-candidate-ml-experiment \
  /path/to/manifest.json \
  --model-type boosted-tree \
  > /tmp/tick-candidate-tree.json
```

`--model-output` is optional. Generated `.mlmodel`, `.mlpackage`, and compiled
model artifacts are ignored by git and must stay out of the app until the
manually labeled, end-to-end acceptance gates pass.

The report includes per-watch folds, aggregate confusion matrices, comparison
with a train-only envelope threshold, reviewed/provisional counts, and explicit
caveats. `candidateMetricGatePassed` is diagnostic only, and
`productionEligible` remains false until candidate and end-to-end gates pass.

Compile an exported model to verify the Apple runtime artifact:

```sh
xcrun coremlcompiler compile \
  /tmp/tick-candidate.mlmodel \
  /tmp/tick-candidate-compiled
```
