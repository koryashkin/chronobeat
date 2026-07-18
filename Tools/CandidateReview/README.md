# Candidate review

This macOS command creates a private, standalone browser review package for one
watch recording. It is the manual-label source for the candidate ML experiment.
Audio stays local and is embedded in the generated HTML.

## Generate

Provide the trusted BPH even when DSP currently rejects or misidentifies the
capture:

```sh
Tools/CandidateReview/run-candidate-review \
  /path/to/capture.wav \
  28800 \
  /tmp/watch-review \
  --capture-id stable-capture-id \
  --max-events 600
```

The output directory must be empty. `--capture-id` is optional; `--max-events`
accepts 1-4000 and defaults to 600.

The command writes:

- `review.html`: the review UI with embedded private audio;
- `review-data.json`: DSP metadata, event times, and waveform previews.

Open `review.html` in a browser. Playback uses a local gain and compressor so a
quiet tick is audible without modifying analysis samples. Labels are saved in
browser storage as work progresses. Export and import JSON provide a portable
resume path.

Use `tick` only for a mechanical escapement transient, `noise` for unrelated
impulses or background sound, and `unsure` when the event cannot be judged.
Unreviewed and unsure events are deliberately excluded from training.

## Train with reviewed labels

Keep the package and exported label JSON outside git. Add the exported file to
the matching private experiment-manifest entry:

```json
{
  "id": "stable-capture-id",
  "path": "/path/to/capture.wav",
  "knownBPH": 28800,
  "watchID": "stable-watch-id",
  "deviceID": "iphone-model-or-device-id",
  "reviewLabelsPath": "/path/to/stable-capture-id-reviewed-labels.json"
}
```

The ML evaluator validates capture ID, BPH, feature schema, duplicate events,
sample bounds, and label values. It uses reviewed labels even when current DSP
fails, while keeping whole watches isolated between training and testing.
