# Watch Accuracy Meter iOS

Native iOS MVP for measuring mechanical watch accuracy using the iPhone microphone.

The app is intentionally small: **no backend, no login, no watch profiles, no amplitude**. It focuses on one core question:

> Is this mechanical watch running fast or slow, and by roughly how many seconds per day?

## MVP scope

- iOS only
- Swift + SwiftUI
- AVFoundation audio capture
- `AVAudioSession` in `.record` + `.measurement` mode
- `AVAudioEngine` microphone input tap
- Manual BPH selection
- 60-second measurement
- On-device DSP
- Robust tick timing fit
- Signal quality gate
- Result in `sec/day`

## Non-goals

- Android
- Backend
- Account/login
- Watch collection/profile
- Cloud sync
- Amplitude
- Marketplace mode
- Professional timegrapher replacement claims

## Supported beat rates

- 18,000 bph
- 19,800 bph
- 21,600 bph
- 25,200 bph
- 28,800 bph
- 36,000 bph

## Repository structure

```text
Sources/WatchAccuracyMeter/
  WatchAccuracyMeterApp.swift
  ContentView.swift
  MeasurementViewModel.swift
  AudioWatchMeter.swift
  WatchDSP.swift
Docs/
  MVP_Technical_Document.md
Scripts/
  create_github_repo.sh
  setup_xcode_project.md
```

## How to run in Xcode

1. Open Xcode.
2. Create a new iOS App project named `WatchAccuracyMeter`.
3. Use SwiftUI and Swift.
4. Copy files from `Sources/WatchAccuracyMeter/` into the Xcode project.
5. Add this to `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app uses the microphone to listen to your watch ticking. Audio is processed on your device and is not uploaded.</string>
```

6. Run on a real iPhone. Do not validate on Simulator.

## First validation target

Use one mechanical watch, same position, same quiet room, and run five 60-second measurements.

A viable v0.1 should produce high-confidence measurements with repeatability around **±3–5 sec/day** under controlled conditions.

## Product positioning

This is not a professional Witschi/Weishi replacement. It is a phone-based accuracy estimate for hobbyists and collectors.
