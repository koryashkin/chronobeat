import Foundation
import AVFoundation

@MainActor
final class MeasurementViewModel: ObservableObject {
    @Published var selectedBPH: BeatRate = .bph28800
    @Published var state: MeasurementState = .idle
    @Published var elapsedSeconds: Double = 0
    @Published var progress: Double = 0
    @Published var liveLevelText: String = "0%"

    var isMeasuring: Bool {
        if case .measuring = state { return true }
        return false
    }

    private let audioMeter = AudioWatchMeter()
    private let measurementDuration: TimeInterval = 60
    private var timerTask: Task<Void, Never>?

    func startMeasurement() async {
        state = .requestingPermission

        do {
            try await audioMeter.requestPermissionIfNeeded()
            state = .measuring
            elapsedSeconds = 0
            progress = 0

            try audioMeter.start { [weak self] level in
                Task { @MainActor in
                    let pct = max(0, min(100, Int(level * 100)))
                    self?.liveLevelText = "\(pct)%"
                }
            }

            startTimer()

            try await Task.sleep(nanoseconds: UInt64(measurementDuration * 1_000_000_000))
            await finishMeasurement()
        } catch {
            cancelTimer()
            audioMeter.stop()
            state = .failed(error.localizedDescription)
        }
    }

    func cancelMeasurement() {
        cancelTimer()
        audioMeter.stop()
        reset()
    }

    func reset() {
        state = .idle
        elapsedSeconds = 0
        progress = 0
        liveLevelText = "0%"
    }

    private func finishMeasurement() async {
        cancelTimer()
        state = .analyzing

        let samples = audioMeter.stopAndReturnSamples()
        let sampleRate = audioMeter.actualSampleRate
        let selected = selectedBPH.rawValue

        let result = await Task.detached(priority: .userInitiated) {
            WatchDSP.analyze(samples: samples, sampleRate: sampleRate, selectedBPH: selected)
        }.value

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
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
    }
}

