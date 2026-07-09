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

    private let audioMeter: any WatchAudioMetering
    private let measurementDuration: TimeInterval
    private var timerTask: Task<Void, Never>?
    private var measurementTask: Task<Void, Never>?
    private var lastObservedSampleCount = 0
    private var lastSampleGrowthDate = Date.distantPast
    private var latestCapture: AudioCapture?
    private var latestResult: WatchMeasurementResult?

    init(audioMeter: any WatchAudioMetering = AudioWatchMeter(),
         measurementDuration: TimeInterval = 60) {
        self.audioMeter = audioMeter
        self.measurementDuration = measurementDuration
    }

    func startMeasurement() {
        guard state.canEditBeatRate else { return }
        let selectedBPHForRun = selectedBPH

        measurementTask?.cancel()
        measurementTask = Task { [weak self] in
            await self?.runMeasurement(selectedBPH: selectedBPHForRun)
        }
    }

    private func runMeasurement(selectedBPH: BeatRateSelection) async {
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
            await finishMeasurement(selectedBPH: selectedBPH)
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
        latestExportURL = nil
        exportStatusText = nil
        latestCapture = nil
        latestResult = nil
        resetCaptureStatus()
    }

    func stopForInactiveScene() {
        guard state.requiresForegroundAudioSession else { return }
        cancelMeasurement()
    }

    private func finishMeasurement(selectedBPH: BeatRateSelection) async {
        cancelTimer()
        guard !Task.isCancelled else { return }
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

        guard !Task.isCancelled else { return }
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
