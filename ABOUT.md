# About Watch Accuracy Meter

Watch Accuracy Meter is an experimental iPhone app that estimates the daily
rate of a mechanical watch by analyzing its ticks through the iPhone's built-in
microphone. It is a small, on-device SwiftUI project focused on careful audio
capture and conservative signal-quality checks.

## What it does

- Records a 60-second microphone sample in `.record` / `.measurement` mode.
- Detects supported watch beat rates automatically or lets you choose a known
  rate: 18,000, 19,800, 21,600, 25,200, 28,800, or 36,000 beats per hour.
- Estimates whether a watch is running fast or slow when the tick pattern is
  clear enough, and asks you to retry when recognition is weak or ambiguous.
- Keeps audio processing on the device. A raw capture and diagnostics are
  created only when you explicitly export a debug capture.

## Accuracy and limits

This is a hobbyist estimate, not a professional timegrapher or watchmaker
diagnostic. Results depend on watch placement, the phone's microphone, and the
recording environment. The app does not measure amplitude or beat error. A
simulator build can demonstrate the interface, but microphone accuracy requires
testing on a physical iPhone. See [the validation plan](Docs/VALIDATION_PLAN.md)
for the project's current measurement gates.

## Technology

- Swift 6, SwiftUI, and AVFoundation
- iOS 17 or later
- No backend, account, analytics, or cloud sync

## Build and use

Open `WatchAccuracyMeter.xcodeproj`, select the `WatchAccuracyMeter` scheme, and
run it on an iPhone or iOS Simulator. For a measurement, place the watch near
the iPhone's bottom microphone in a quiet room. See the [README](README.md) for
the full setup, build, and measurement instructions.

## License

No license has been added to this repository. Public visibility does not by
itself grant permission to reuse, distribute, or modify the code.
