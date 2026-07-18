# Recognition benchmark

This command replays private, labeled WAV captures through the current Auto-BPH
pipeline. It reads every audio frame, creates overlapping analysis windows, and
emits a JSON report suitable for comparing DSP-only and future Core ML runs.

Create an uncommitted manifest outside the repository:

```json
{
  "schemaVersion": 1,
  "captures": [
    {
      "id": "tudor-gmt-run-01",
      "path": "/absolute/path/to/capture.wav",
      "knownBPH": 28800,
      "watchID": "tudor-gmt",
      "deviceID": "iphone-model-or-test-device"
    }
  ]
}
```

Run the default 20-second windows with a 5-second hop:

```sh
Tools/RecognitionBenchmark/run-recognition-benchmark /path/to/manifest.json > /tmp/recognition-report.json
```

Optional second and third arguments override window and hop duration:

```sh
Tools/RecognitionBenchmark/run-recognition-benchmark /path/to/manifest.json 20 10
```

Full captures and private manifests must remain outside git. The report marks
the recognition acceptance gate eligible only after at least 100 windows from
20 unique captures, five labeled watches, and two labeled devices exist.
Duplicate capture IDs and paths are rejected. Overlapping windows are
correlated, so a passing aggregate still requires held-out-watch and
held-out-device analysis.
