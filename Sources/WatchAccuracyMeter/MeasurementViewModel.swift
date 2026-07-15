import Foundation
import AVFoundation

@MainActor
final class MeasurementViewModel: ObservableObject {
    @Published var selectedBPH: BeatRateSelection = .auto
    @Published var state: MeasurementState = .idle
    @Published var elapsedSeconds: Double = 0
    @Published var progress: Double = 0
    @Published var liveLevelText: String = "0%"
    @Published var routeWarning: String?
    @Published var capturedSampleCount: Int = 0
    @Published var capturedAudioSeconds: Double = 0
    @Published var isReceivingAudio: Bool = false
    @Published var liveRmsLevel: Double = 0
    @Published var livePeakLevel: Double = 0
    @Published var liveClippingRatio: Double = 0
    @Published var latestExportURL: URL?
    @Published var exportStatusText: String?

    var isMeasuring: Bool {
        state.isMeasuring
    }

    var canEditBeatRate: Bool {
        state.canEditBeatRate
    }

    var measurementDurationText: String {
        let seconds = max(1, Int(measurementDuration.rounded()))
        return seconds == 1 ? "1 sec" : "\(seconds) sec"
    }

    private let audioMeter: any WatchAudioMetering
    let measurementDuration: TimeInterval
    private var timerTask: Task<Void, Never>?
    private var measurementTask: Task<Void, Never>?
    private var lastObservedSampleCount = 0
    private var lastSampleGrowthDate = Date.distantPast
    private var latestCapture: AudioCapture?
    private var latestResult: WatchMeasurementResult?
    private var measurementGeneration = 0

    init(audioMeter: any WatchAudioMetering = AudioWatchMeter(),
         measurementDuration: TimeInterval = 60) {
        self.audioMeter = audioMeter
        self.measurementDuration = measurementDuration
    }

    func startMeasurement() {
        guard state.canEditBeatRate else { return }
        let selectedBPHForRun = selectedBPH
        measurementGeneration += 1
        let generation = measurementGeneration

        measurementTask?.cancel()
        measurementTask = Task { [weak self] in
            await self?.runMeasurement(selectedBPH: selectedBPHForRun, generation: generation)
        }
    }

    private func runMeasurement(selectedBPH: BeatRateSelection, generation: Int) async {
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
            if let routeWarning {
                throw AudioMeterError.unsupportedInputRoute(routeWarning)
            }

            startTimer()

            try await waitForMeasurementDuration(generation: generation)
            try Task.checkCancellation()
            await finishMeasurement(selectedBPH: selectedBPH, generation: generation)
        } catch is CancellationError {
            cancelTimer()
            if generation == measurementGeneration {
                audioMeter.stop()
            }
        } catch {
            cancelTimer()
            if generation == measurementGeneration {
                audioMeter.stop()
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancelMeasurement() {
        measurementGeneration += 1
        measurementTask?.cancel()
        measurementTask = nil
        cancelTimer()
        audioMeter.stop()
        resetState()
    }

    func reset() {
        measurementGeneration += 1
        measurementTask?.cancel()
        measurementTask = nil
        audioMeter.stop()
        resetState()
    }

    private func resetState() {
        state = .idle
        elapsedSeconds = 0
        progress = 0
        liveLevelText = "0%"
        routeWarning = nil
        latestExportURL = nil
        exportStatusText = nil
        latestCapture = nil
        latestResult = nil
        resetCaptureStatus()
    }

    func stopForInactiveScene() {
        switch state {
        case .idle, .result, .failed:
            return
        case .requestingPermission, .measuring, .analyzing:
            break
        }
        cancelMeasurement()
    }

    private func finishMeasurement(selectedBPH: BeatRateSelection, generation: Int) async {
        cancelTimer()
        guard !Task.isCancelled, generation == measurementGeneration else {
            if generation == measurementGeneration {
                state = .idle
                measurementTask = nil
            }
            return
        }
        state = .analyzing

        let samples = audioMeter.stopAndReturnSamples()
        let capture = AudioCapture(samples: samples,
                                   sampleRate: audioMeter.actualSampleRate,
                                   routeDescription: audioMeter.routeDescription,
                                   routeWarning: audioMeter.routeWarning)

        let result = await Task.detached(priority: .userInitiated) {
            switch selectedBPH {
            case .auto:
                WatchDSP.analyzeAuto(capture: capture)
            case .manual(let beatRate):
                WatchDSP.analyze(capture: capture, selectedBPH: beatRate.rawValue)
            }
        }.value

        guard !Task.isCancelled, generation == measurementGeneration else {
            if generation == measurementGeneration {
                state = .idle
                measurementTask = nil
            }
            return
        }
        latestCapture = capture
        latestResult = result
        latestExportURL = nil
        exportStatusText = nil
        measurementTask = nil
        state = .result(result)
    }

    func exportLastMeasurement() {
        guard let latestCapture, let latestResult else {
            exportStatusText = "No measurement is available to export."
            latestExportURL = nil
            return
        }

        do {
            let export = try AudioCaptureExporter.export(capture: latestCapture, result: latestResult)
            latestExportURL = export.directoryURL
            exportStatusText = "Debug capture exported."
        } catch {
            latestExportURL = nil
            exportStatusText = "Export failed: \(error.localizedDescription)"
        }
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

    private func waitForMeasurementDuration(generation: Int) async throws {
        let start = Date()
        let preflightDelay = min(5, max(0.05, measurementDuration * 0.25))
        var didRunPreflight = false

        while Date().timeIntervalSince(start) < measurementDuration {
            try Task.checkCancellation()
            guard generation == measurementGeneration else { throw CancellationError() }

            if let captureFailure = audioMeter.captureFailure {
                throw captureFailure
            }

            let elapsed = Date().timeIntervalSince(start)
            if !didRunPreflight, elapsed >= preflightDelay {
                didRunPreflight = true
                let levels = audioMeter.latestLevels
                if audioMeter.capturedSampleCount == 0 || levels.peakLevel < 0.002 {
                    throw AudioMeterError.inputTooQuiet
                }
            }

            try await Task.sleep(nanoseconds: 100_000_000)
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
        capturedAudioSeconds = audioMeter.actualSampleRate > 0
            ? Double(sampleCount) / audioMeter.actualSampleRate
            : 0
        isReceivingAudio = sampleCount > 0 && now.timeIntervalSince(lastSampleGrowthDate) < 0.75
        liveRmsLevel = audioMeter.latestLevels.rmsLevel
        livePeakLevel = audioMeter.latestLevels.peakLevel
        liveClippingRatio = audioMeter.latestLevels.clippingRatio
    }

    private func resetCaptureStatus() {
        capturedSampleCount = 0
        capturedAudioSeconds = 0
        isReceivingAudio = false
        liveRmsLevel = 0
        livePeakLevel = 0
        liveClippingRatio = 0
        lastObservedSampleCount = 0
        lastSampleGrowthDate = .distantPast
    }

    private func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
    }
}
