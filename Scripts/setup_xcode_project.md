# Xcode setup

This repository contains source files and technical documentation, not a generated `.xcodeproj`.

## Steps

1. Open Xcode.
2. File → New → Project → iOS → App.
3. Product Name: `WatchAccuracyMeter`.
4. Interface: SwiftUI.
5. Language: Swift.
6. Delete the generated `ContentView.swift` and app entry file.
7. Drag all files from `Sources/WatchAccuracyMeter/` into the Xcode project.
8. Add microphone permission to `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app uses the microphone to listen to your watch ticking. Audio is processed on your device and is not uploaded.</string>
```

9. Run on a real iPhone.

## Debug checklist

- Confirm actual sample rate after session activation.
- Confirm built-in microphone route, not AirPods/Bluetooth.
- Check live level changes when the watch is placed near the mic.
- Run five repeated 60-second measurements.
- Compare against a real timegrapher if available.
