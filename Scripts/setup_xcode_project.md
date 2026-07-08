# Xcode setup

This repository uses XcodeGen to keep the Xcode project reproducible.

## Steps

1. Install XcodeGen if needed:

```sh
brew install xcodegen
```

2. Generate or refresh the project:

```sh
xcodegen generate
```

3. Open `WatchAccuracyMeter.xcodeproj`.
4. Select the `WatchAccuracyMeter` scheme.
5. Run on an iOS Simulator for UI/build checks.
6. Run the unit tests from the `WatchAccuracyMeter` scheme.
7. Run on a real iPhone for microphone and watch-tick validation.

The microphone permission is generated into `Sources/WatchAccuracyMeter/Info.plist` from `project.yml`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app uses the microphone to listen to your watch ticking. Audio is processed on your device and is not uploaded.</string>
```

## Debug checklist

- Confirm actual sample rate after session activation.
- Confirm built-in microphone route, not AirPods/Bluetooth.
- Check live level changes when the watch is placed near the mic.
- Run five repeated 60-second measurements.
- Compare against a real timegrapher if available.
