import Foundation
import AVFoundation

@MainActor
final class MeasurementViewModel: ObservableObject {
    @Published var selectedBPH: BeatRate = .bph28800
    @Published var state: MeasurementState = .idle
    @Published var elapsedSeconds: Double = 0
    @Published var progress: Double = 0
    @Published var liveLevelText: String = "0%"
    @Published var routeWarning: String?
    @Published var capturedSampleCount: Int = 0
    @Published var capturedAudioSeconds: Double = 0
    @Published var isReceivingAudio: Bool = false

    var isMeasuring: Bool {
        if case .measuring = state { return true }
        return false
    }

    private let audioMeter = AudioWatchMeter()
    private let measurementDuration: TimeInterval = 60
    private var timerTask: Task<Void, Never>?
    private var measurementTask: Task<Void, Never>?
    private var lastObservedSampleCount = 0
    private var lastSampleGrowthDate = Date.distantPast

    func startMeasurement() {
        measurementTask?.cancel()
        measurementTask = Task { [weak self] in
            await self?.runMeasurement()
        }
    }

    private func runMeasurement() async {
        state = .requestingPermission
        routeWarning = nil

        do {
            try await audioMeter.requestPermissionIfNeeded()
            try Task.checkCancellation()

            state = .measuring
            elapsedSeconds = 0
            progress = 0
            resetCaptureStatus()

            try audioMeter.start { [weak self] level in
                Task { @MainActor in
                    let pct = max(0, min(100, Int(level * 100)))
                    self?.liveLevelText = "\(pct)%"
                }
            }
            routeWarning = audioMeter.routeWarning

            startTimer()

            try await Task.sleep(nanoseconds: UInt64(measurementDuration * 1_000_000_000))
            try Task.checkCancellation()
            await finishMeasurement()
        } catch is CancellationError {
            cancelTimer()
            audioMeter.stop()
        } catch {
            cancelTimer()
            audioMeter.stop()
            state = .failed(error.localizedDescription)
        }
    }

    func cancelMeasurement() {
        measurementTask?.cancel()
        measurementTask = nil
        cancelTimer()
        audioMeter.stop()
        reset()
    }

    func reset() {
        measurementTask?.cancel()
        measurementTask = nil
        state = .idle
        elapsedSeconds = 0
        progress = 0
        liveLevelText = "0%"
        routeWarning = nil
        resetCaptureStatus()
    }

    private func finishMeasurement() async {
        cancelTimer()
        state = .analyzing

        let samples = audioMeter.stopAndReturnSamples()
        let sampleRate = audioMeter.actualSampleRate
        let selected = selectedBPH.rawValue
        let routeDescription = audioMeter.routeDescription
        let routeWarning = audioMeter.routeWarning

        let result = await Task.detached(priority: .userInitiated) {
            WatchDSP.analyze(samples: samples,
                             sampleRate: sampleRate,
                             selectedBPH: selected,
                             routeDescription: routeDescription,
                             routeWarning: routeWarning)
        }.value

        measurementTask = nil
        state = .result(result)
    }

    private func startTimer() {
        cancelTimer()
        timerTask = Task { [weak self] in
            guard let self else { return }
            let start = Date()
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(start)
                await MainActor.run {
                    self.elapsedSeconds = min(self.measurementDuration, elapsed)
                    self.progress = min(1, elapsed / self.measurementDuration)
                    self.updateCaptureStatus()
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func updateCaptureStatus() {
        let sampleCount = audioMeter.capturedSampleCount
        let now = Date()

        if sampleCount > lastObservedSampleCount {
            lastSampleGrowthDate = now
        }

        lastObservedSampleCount = sampleCount
        capturedSampleCount = sampleCount
        capturedAudioSeconds = audioMeter.actualSampleRate > 0 ? Double(sampleCount) / audioMeter.actualSampleRate : 0
        isReceivingAudio = sampleCount > 0 && now.timeIntervalSince(lastSampleGrowthDate) < 0.75
    }

    private func resetCaptureStatus() {
        capturedSampleCount = 0
        capturedAudioSeconds = 0
        isReceivingAudio = false
        lastObservedSampleCount = 0
        lastSampleGrowthDate = .distantPast
    }

    private func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
    }
}
