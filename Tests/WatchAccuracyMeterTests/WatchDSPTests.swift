import XCTest
import AVFoundation
@testable import WatchAccuracyMeter

final class WatchDSPTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let selectedBPH = 28_800

    func testDetectsFastSyntheticWatchRate() {
        let samples = makeSyntheticWatchSamples(rateSecondsPerDay: 12)

        let result = WatchDSP.analyze(samples: samples,
                                      sampleRate: sampleRate,
                                      selectedBPH: selectedBPH,
                                      routeDescription: "Synthetic")

        XCTAssertEqual(result.quality, .high)
        XCTAssertEqual(result.rateSecondsPerDay, 12, accuracy: 1.5)
        XCTAssertEqual(result.detectedBPH, 28_804, accuracy: 0.8)
        XCTAssertGreaterThan(result.validPeakCount, 400)
        XCTAssertLessThan(result.outlierRatio, 0.05)
    }

    func testDetectsSlowSyntheticWatchRate() {
        let samples = makeSyntheticWatchSamples(rateSecondsPerDay: -18)

        let result = WatchDSP.analyze(samples: samples,
                                      sampleRate: sampleRate,
                                      selectedBPH: selectedBPH,
                                      routeDescription: "Synthetic")

        XCTAssertEqual(result.quality, .high)
        XCTAssertEqual(result.rateSecondsPerDay, -18, accuracy: 1.5)
        XCTAssertLessThan(result.detectedBPH, Double(selectedBPH))
        XCTAssertGreaterThan(result.validPeakCount, 400)
        XCTAssertLessThan(result.outlierRatio, 0.05)
    }

    func testSilenceReturnsLowQualityFallbackWithoutRateClaim() {
        let samples = Array(repeating: Float(0), count: Int(sampleRate * 12))

        let result = WatchDSP.analyze(samples: samples,
                                      sampleRate: sampleRate,
                                      selectedBPH: selectedBPH,
                                      routeDescription: "Synthetic silence",
                                      routeWarning: "No useful input")

        XCTAssertEqual(result.quality, .low)
        XCTAssertEqual(result.rateSecondsPerDay, 0)
        XCTAssertEqual(result.validPeakCount, 0)
        XCTAssertEqual(result.outlierRatio, 1)
        XCTAssertEqual(result.sampleCount, samples.count)
        XCTAssertEqual(result.routeDescription, "Synthetic silence")
        XCTAssertEqual(result.routeWarning, "No useful input")
    }

    func testShortCaptureReturnsLowQualityFallback() {
        let samples = makeSyntheticWatchSamples(rateSecondsPerDay: 20, duration: 5)

        let result = WatchDSP.analyze(samples: samples,
                                      sampleRate: sampleRate,
                                      selectedBPH: selectedBPH,
                                      routeDescription: "Short synthetic capture")

        XCTAssertEqual(result.quality, .low)
        XCTAssertEqual(result.rateSecondsPerDay, 0)
        XCTAssertEqual(result.validPeakCount, 0)
        XCTAssertEqual(result.sampleCount, samples.count)
    }

    func testBeatGridFitToleratesMissedTicks() {
        let samples = makeSyntheticWatchSamples(rateSecondsPerDay: 7) { beatIndex in
            beatIndex.isMultiple(of: 19)
        }

        let result = WatchDSP.analyze(samples: samples,
                                      sampleRate: sampleRate,
                                      selectedBPH: selectedBPH,
                                      routeDescription: "Synthetic missed ticks")

        XCTAssertEqual(result.quality, .high)
        XCTAssertEqual(result.rateSecondsPerDay, 7, accuracy: 1.5)
        XCTAssertGreaterThan(result.validPeakCount, 430)
        XCTAssertLessThan(result.outlierRatio, 0.05)
    }

    func testDetectsVeryQuietSyntheticWatchBelowOldFixedThreshold() {
        let samples = makeSyntheticWatchSamples(rateSecondsPerDay: 9, amplitudeScale: 0.02)

        let result = WatchDSP.analyze(samples: samples,
                                      sampleRate: sampleRate,
                                      selectedBPH: selectedBPH,
                                      routeDescription: "Very quiet synthetic watch")

        XCTAssertEqual(result.quality, .high)
        XCTAssertEqual(result.rateSecondsPerDay, 9, accuracy: 1.5)
        XCTAssertGreaterThan(result.detectedPeakCount, 400)
        XCTAssertLessThan(result.rmsLevel, 0.001)
    }

    func testDetectsSupportedLowerBeatRateSyntheticWatch() {
        let lowerBPH = BeatRate.bph21600.rawValue
        let samples = makeSyntheticWatchSamples(rateSecondsPerDay: -6, nominalBPH: lowerBPH)

        let result = WatchDSP.analyze(samples: samples,
                                      sampleRate: sampleRate,
                                      selectedBPH: lowerBPH,
                                      routeDescription: "Lower beat rate synthetic watch")

        XCTAssertEqual(result.quality, .high)
        XCTAssertEqual(result.rateSecondsPerDay, -6, accuracy: 1.5)
        XCTAssertEqual(result.detectedBPH, 21_598.5, accuracy: 0.8)
        XCTAssertGreaterThan(result.validPeakCount, 300)
        XCTAssertGreaterThan(result.beatCoverage, 0.98)
    }

    func testWrongSelectedBeatRateIsRejectedByCoverageGate() {
        let actualBPH = BeatRate.bph21600.rawValue
        let samples = makeSyntheticWatchSamples(rateSecondsPerDay: 0, nominalBPH: actualBPH)

        let result = WatchDSP.analyze(samples: samples,
                                      sampleRate: sampleRate,
                                      selectedBPH: selectedBPH,
                                      routeDescription: "Wrong selected beat rate")

        XCTAssertEqual(result.quality, .low)
        XCTAssertLessThan(result.beatCoverage, 0.80)
        XCTAssertLessThan(result.qualityScore, 50)
    }

    func testKingSeikoFixtureDetectsRealTickGrid() throws {
        let fixture = try loadFixture(named: "king-seiko-28800-10-30s")

        let result = WatchDSP.analyze(samples: fixture.samples,
                                      sampleRate: fixture.sampleRate,
                                      selectedBPH: selectedBPH,
                                      routeDescription: "King Seiko fixture")

        XCTAssertNotEqual(result.quality, .low)
        XCTAssertGreaterThanOrEqual(result.detectedPeakCount, 120)
        XCTAssertGreaterThanOrEqual(result.validPeakCount, 100)
        XCTAssertGreaterThanOrEqual(result.beatCoverage, 0.70)
    }

    func testKingSeikoFixtureUsesLowerThresholdScale() throws {
        let fixture = try loadFixture(named: "king-seiko-28800-10-30s")

        let result = WatchDSP.analyze(samples: fixture.samples,
                                      sampleRate: fixture.sampleRate,
                                      selectedBPH: selectedBPH,
                                      routeDescription: "King Seiko fixture")

        XCTAssertLessThan(result.chosenThresholdScale, 1.0)
    }

    func testQuietSyntheticWatchWithWhiteNoiseStillFindsGrid() {
        var samples = makeSyntheticWatchSamples(rateSecondsPerDay: 5,
                                                duration: 30,
                                                amplitudeScale: 0.08)
        addWhiteNoise(to: &samples, amplitude: 0.00045, seed: 17)

        let result = WatchDSP.analyze(samples: samples,
                                      sampleRate: sampleRate,
                                      selectedBPH: selectedBPH,
                                      routeDescription: "Noisy synthetic watch")

        XCTAssertNotEqual(result.quality, .low)
        XCTAssertEqual(result.rateSecondsPerDay, 5, accuracy: 3.0)
        XCTAssertGreaterThan(result.beatCoverage, 0.85)
    }

    func testLowFrequencyHandlingRumbleDoesNotMaskTicks() {
        var samples = makeSyntheticWatchSamples(rateSecondsPerDay: -4, duration: 30)
        addSine(to: &samples, frequency: 28, amplitude: 0.003)

        let result = WatchDSP.analyze(samples: samples,
                                      sampleRate: sampleRate,
                                      selectedBPH: selectedBPH,
                                      routeDescription: "Rumble synthetic watch")

        XCTAssertNotEqual(result.quality, .low)
        XCTAssertEqual(result.rateSecondsPerDay, -4, accuracy: 3.0)
        XCTAssertGreaterThan(result.beatCoverage, 0.90)
    }

    func testDuplicateResonancePeaksAreMergedIntoBeatGrid() {
        let samples = makeSyntheticWatchSamples(rateSecondsPerDay: 6,
                                                duration: 30,
                                                echoDelay: 0.014,
                                                echoScale: 0.45)

        let result = WatchDSP.analyze(samples: samples,
                                      sampleRate: sampleRate,
                                      selectedBPH: selectedBPH,
                                      routeDescription: "Resonant synthetic watch")

        XCTAssertNotEqual(result.quality, .low)
        XCTAssertEqual(result.rateSecondsPerDay, 6, accuracy: 3.0)
        XCTAssertGreaterThan(result.beatCoverage, 0.90)
    }

    func testRandomImpulseNoiseDoesNotCreateConfidentWrongGrid() {
        var samples = makeSyntheticWatchSamples(rateSecondsPerDay: 3, duration: 30)
        addImpulseNoise(to: &samples, count: 40, amplitude: 0.18, seed: 29)

        let result = WatchDSP.analyze(samples: samples,
                                      sampleRate: sampleRate,
                                      selectedBPH: selectedBPH,
                                      routeDescription: "Impulse synthetic watch")

        XCTAssertNotEqual(result.quality, .low)
        XCTAssertEqual(result.rateSecondsPerDay, 3, accuracy: 3.0)
        XCTAssertGreaterThan(result.beatCoverage, 0.80)
    }

    func testAdaptiveLevelShiftStillFindsQuietTickGrid() {
        var samples = makeSyntheticWatchSamples(rateSecondsPerDay: -8,
                                                duration: 30,
                                                amplitudeScale: 0.09)
        applyLevelRamp(to: &samples, startGain: 0.30, endGain: 1.80)
        addWhiteNoise(to: &samples, amplitude: 0.00035, seed: 41)

        let result = WatchDSP.analyze(samples: samples,
                                      sampleRate: sampleRate,
                                      selectedBPH: selectedBPH,
                                      routeDescription: "Level-shifted synthetic watch")

        XCTAssertNotEqual(result.quality, .low)
        XCTAssertEqual(result.rateSecondsPerDay, -8, accuracy: 3.5)
        XCTAssertGreaterThan(result.beatCoverage, 0.75)
    }

    func testLocalizedNoiseBurstDoesNotBreakWholeMeasurement() {
        var samples = makeSyntheticWatchSamples(rateSecondsPerDay: 4,
                                                duration: 30,
                                                amplitudeScale: 0.12)
        addWhiteNoise(to: &samples, amplitude: 0.00030, seed: 53)
        addNoiseBurst(to: &samples,
                      start: 11,
                      duration: 4,
                      amplitude: 0.004,
                      seed: 67)

        let result = WatchDSP.analyze(samples: samples,
                                      sampleRate: sampleRate,
                                      selectedBPH: selectedBPH,
                                      routeDescription: "Burst-noise synthetic watch")

        XCTAssertNotEqual(result.quality, .low)
        XCTAssertEqual(result.rateSecondsPerDay, 4, accuracy: 4.0)
        XCTAssertGreaterThan(result.beatCoverage, 0.75)
    }

    private func makeSyntheticWatchSamples(
        rateSecondsPerDay: Double,
        nominalBPH: Int? = nil,
        duration: Double = 60,
        amplitudeScale: Float = 1,
        echoDelay: Double? = nil,
        echoScale: Float = 0,
        skipBeat: (Int) -> Bool = { _ in false }
    ) -> [Float] {
        let sampleCount = Int(duration * sampleRate)
        var samples = Array(repeating: Float(0), count: sampleCount)
        let expectedBPH = Double(nominalBPH ?? selectedBPH)
        let detectedBPH = expectedBPH * (1 + rateSecondsPerDay / 86_400)
        let period = 3_600 / detectedBPH

        var beatIndex = 0
        var tickTime = 0.1
        while tickTime < duration - 0.1 {
            let tickSample = Int((tickTime * sampleRate).rounded())
            if !skipBeat(beatIndex) {
                addSyntheticTick(to: &samples,
                                 at: tickSample,
                                 beatIndex: beatIndex,
                                 amplitudeScale: amplitudeScale)
                if let echoDelay {
                    addSyntheticTick(to: &samples,
                                     at: tickSample + Int((echoDelay * sampleRate).rounded()),
                                     beatIndex: beatIndex,
                                     amplitudeScale: amplitudeScale * echoScale)
                }
            }
            tickTime += period
            beatIndex += 1
        }

        return samples
    }

    private func addSyntheticTick(
        to samples: inout [Float],
        at index: Int,
        beatIndex: Int,
        amplitudeScale: Float
    ) {
        let shape: [Float] = [
            0.90, 0.68, 0.44, 0.20, -0.22, -0.14, -0.07,
            0.10, 0.06, 0.03, 0.015, 0.008
        ]
        let amplitude = Float(0.55 + 0.05 * sin(Double(beatIndex) * 0.17)) * amplitudeScale

        for offset in shape.indices {
            let sampleIndex = index + offset
            guard samples.indices.contains(sampleIndex) else { continue }
            samples[sampleIndex] += shape[offset] * amplitude
        }
    }

    private func loadFixture(named name: String) throws -> (samples: [Float], sampleRate: Double) {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "wav"))
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        try file.read(into: buffer)

        let channelData = try XCTUnwrap(buffer.floatChannelData)
        let channels = max(1, Int(format.channelCount))
        let frames = Int(buffer.frameLength)
        var samples: [Float] = []
        samples.reserveCapacity(frames)

        for frame in 0..<frames {
            var mixed: Float = 0
            for channel in 0..<channels {
                mixed += channelData[channel][frame]
            }
            samples.append(mixed / Float(channels))
        }

        return (samples, format.sampleRate)
    }

    private func addWhiteNoise(to samples: inout [Float], amplitude: Float, seed: UInt64) {
        var generator = SeededRandom(seed: seed)
        for index in samples.indices {
            samples[index] += (generator.nextFloat() * 2 - 1) * amplitude
        }
    }

    private func addSine(to samples: inout [Float], frequency: Double, amplitude: Float) {
        for index in samples.indices {
            let t = Double(index) / sampleRate
            samples[index] += Float(sin(2 * Double.pi * frequency * t)) * amplitude
        }
    }

    private func addImpulseNoise(to samples: inout [Float], count: Int, amplitude: Float, seed: UInt64) {
        var generator = SeededRandom(seed: seed)
        guard !samples.isEmpty else { return }

        for _ in 0..<count {
            let index = Int(generator.nextFloat() * Float(samples.count - 1))
            samples[index] += generator.nextFloat() > 0.5 ? amplitude : -amplitude
        }
    }

    private func applyLevelRamp(to samples: inout [Float], startGain: Float, endGain: Float) {
        guard samples.count > 1 else { return }

        for index in samples.indices {
            let progress = Float(index) / Float(samples.count - 1)
            let gain = startGain + (endGain - startGain) * progress
            samples[index] *= gain
        }
    }

    private func addNoiseBurst(to samples: inout [Float],
                               start: Double,
                               duration: Double,
                               amplitude: Float,
                               seed: UInt64) {
        var generator = SeededRandom(seed: seed)
        let startIndex = max(0, Int(start * sampleRate))
        let endIndex = min(samples.count, startIndex + Int(duration * sampleRate))
        guard startIndex < endIndex else { return }

        for index in startIndex..<endIndex {
            let slowWave = Float(sin(2 * Double.pi * 38 * Double(index) / sampleRate)) * amplitude
            let hiss = (generator.nextFloat() * 2 - 1) * amplitude * 0.35
            samples[index] += slowWave + hiss
        }
    }
}

private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextFloat() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        let value = UInt32(truncatingIfNeeded: state >> 32)
        return Float(value) / Float(UInt32.max)
    }
}

@MainActor
final class MeasurementViewModelAudioTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let selectedBPH = 28_800

    func testMeasurementCompletesWithInjectedAudioSamples() async throws {
        let samples = makeSyntheticWatchSamples(rateSecondsPerDay: 11)
        let audioMeter = FakeAudioMeter(samples: samples,
                                        sampleRate: sampleRate,
                                        routeDescription: "Synthetic microphone")
        let viewModel = MeasurementViewModel(audioMeter: audioMeter,
                                             measurementDuration: 0.01)

        viewModel.startMeasurement()

        try await waitUntil {
            if case .result = viewModel.state { return true }
            return false
        }

        guard case .result(let result) = viewModel.state else {
            return XCTFail("Expected a result state.")
        }

        XCTAssertTrue(audioMeter.didRequestPermission)
        XCTAssertEqual(audioMeter.startCallCount, 1)
        XCTAssertEqual(audioMeter.stopAndReturnSamplesCallCount, 1)
        XCTAssertEqual(result.quality, .high)
        XCTAssertEqual(result.rateSecondsPerDay, 11, accuracy: 1.5)
        XCTAssertEqual(result.routeDescription, "Synthetic microphone")
        XCTAssertEqual(result.sampleCount, samples.count)
    }

    func testInjectedAudioUpdatesCaptureStatusWithoutRealMicrophone() async throws {
        let samples = makeSyntheticWatchSamples(rateSecondsPerDay: 0)
        let audioMeter = FakeAudioMeter(samples: samples, sampleRate: sampleRate)
        let viewModel = MeasurementViewModel(audioMeter: audioMeter,
                                             measurementDuration: 5)

        viewModel.startMeasurement()

        try await waitUntil { viewModel.isReceivingAudio }

        XCTAssertEqual(viewModel.capturedSampleCount, samples.count)
        XCTAssertEqual(viewModel.capturedAudioSeconds, 60, accuracy: 0.1)
        XCTAssertEqual(viewModel.liveLevelText, "42%")

        viewModel.cancelMeasurement()
    }

    func testPermissionFailureDoesNotStartInjectedAudioMeter() async throws {
        let audioMeter = FakeAudioMeter(samples: [],
                                        sampleRate: sampleRate,
                                        permissionError: AudioMeterError.microphonePermissionDenied)
        let viewModel = MeasurementViewModel(audioMeter: audioMeter,
                                             measurementDuration: 0.01)

        viewModel.startMeasurement()

        try await waitUntil {
            if case .failed = viewModel.state { return true }
            return false
        }

        guard case .failed(let message) = viewModel.state else {
            return XCTFail("Expected a failed state.")
        }

        XCTAssertTrue(message.contains("Microphone access is required"))
        XCTAssertTrue(audioMeter.didRequestPermission)
        XCTAssertEqual(audioMeter.startCallCount, 0)
    }

    func testInactiveSceneStopsInjectedAudioMeasurement() async throws {
        let samples = makeSyntheticWatchSamples(rateSecondsPerDay: 0)
        let audioMeter = FakeAudioMeter(samples: samples, sampleRate: sampleRate)
        let viewModel = MeasurementViewModel(audioMeter: audioMeter,
                                             measurementDuration: 5)

        viewModel.startMeasurement()

        try await waitUntil { viewModel.isMeasuring }
        viewModel.stopForInactiveScene()

        XCTAssertTrue(viewModel.canEditBeatRate)
        XCTAssertEqual(audioMeter.startCallCount, 1)
        XCTAssertGreaterThanOrEqual(audioMeter.stopCallCount, 1)
    }

    private func makeSyntheticWatchSamples(
        rateSecondsPerDay: Double,
        duration: Double = 60
    ) -> [Float] {
        let sampleCount = Int(duration * sampleRate)
        var samples = Array(repeating: Float(0), count: sampleCount)
        let detectedBPH = Double(selectedBPH) * (1 + rateSecondsPerDay / 86_400)
        let period = 3_600 / detectedBPH

        var beatIndex = 0
        var tickTime = 0.1
        while tickTime < duration - 0.1 {
            let tickSample = Int((tickTime * sampleRate).rounded())
            addSyntheticTick(to: &samples, at: tickSample, beatIndex: beatIndex)
            tickTime += period
            beatIndex += 1
        }

        return samples
    }

    private func addSyntheticTick(to samples: inout [Float], at index: Int, beatIndex: Int) {
        let shape: [Float] = [
            0.90, 0.68, 0.44, 0.20, -0.22, -0.14, -0.07,
            0.10, 0.06, 0.03, 0.015, 0.008
        ]
        let amplitude = Float(0.55 + 0.05 * sin(Double(beatIndex) * 0.17))

        for offset in shape.indices {
            let sampleIndex = index + offset
            guard samples.indices.contains(sampleIndex) else { continue }
            samples[sampleIndex] += shape[offset] * amplitude
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                throw TestWaitError.timeout
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private enum TestWaitError: Error {
        case timeout
    }
}

private final class FakeAudioMeter: WatchAudioMetering, @unchecked Sendable {
    var actualSampleRate: Double
    var routeDescription: String
    var routeWarning: String?

    private let samples: [Float]
    private let permissionError: Error?
    private var hasStarted = false

    private(set) var didRequestPermission = false
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var stopAndReturnSamplesCallCount = 0

    var capturedSampleCount: Int {
        hasStarted ? samples.count : 0
    }

    init(samples: [Float],
         sampleRate: Double,
         routeDescription: String = "Synthetic audio input",
         routeWarning: String? = nil,
         permissionError: Error? = nil) {
        self.samples = samples
        self.actualSampleRate = sampleRate
        self.routeDescription = routeDescription
        self.routeWarning = routeWarning
        self.permissionError = permissionError
    }

    func requestPermissionIfNeeded() async throws {
        didRequestPermission = true
        if let permissionError {
            throw permissionError
        }
    }

    func start(liveLevel: @escaping (Float) -> Void) throws {
        startCallCount += 1
        hasStarted = true
        liveLevel(0.42)
    }

    func stop() {
        stopCallCount += 1
        hasStarted = false
    }

    func stopAndReturnSamples() -> [Float] {
        stopAndReturnSamplesCallCount += 1
        stop()
        return samples
    }
}

final class DomainModelTests: XCTestCase {
    func testBeatRateCasesExposeExpectedLabelsAndIds() {
        XCTAssertEqual(BeatRate.allCases.map(\.rawValue),
                       [18_000, 19_800, 21_600, 25_200, 28_800, 36_000])
        XCTAssertEqual(BeatRate.bph28800.label, "28800 bph")
        XCTAssertEqual(BeatRate.bph28800.id, 28_800)
    }

    func testSignalQualityLabelsAreUserReadable() {
        XCTAssertEqual(SignalQuality.high.label, "High")
        XCTAssertEqual(SignalQuality.medium.label, "Medium")
        XCTAssertEqual(SignalQuality.low.label, "Low")
    }

    func testRateTextRoundsAndPreservesPositiveSign() {
        XCTAssertEqual(Self.makeResult(rateSecondsPerDay: 8.4).rateText, "+8 sec/day")
        XCTAssertEqual(Self.makeResult(rateSecondsPerDay: -3.6).rateText, "-4 sec/day")
        XCTAssertEqual(Self.makeResult(rateSecondsPerDay: 0.4).rateText, "0 sec/day")
    }

    func testHighQualityInterpretationDistinguishesStableFastAndSlowResults() {
        XCTAssertTrue(Self.makeResult(rateSecondsPerDay: 4).interpretation.contains("reasonably stable"))
        XCTAssertTrue(Self.makeResult(rateSecondsPerDay: 24).interpretation.contains("fast"))
        XCTAssertTrue(Self.makeResult(rateSecondsPerDay: -24).interpretation.contains("slow"))
    }

    func testLowQualityInterpretationDistinguishesMissingCandidatesFromUnstableGrid() {
        let missing = Self.makeResult(quality: .low, detectedPeakCount: 0)
        let unstable = Self.makeResult(quality: .low, detectedPeakCount: 80)

        XCTAssertTrue(missing.interpretation.contains("No tick candidates"))
        XCTAssertTrue(unstable.interpretation.contains("beat pattern is unstable"))
    }

    private static func makeResult(
        rateSecondsPerDay: Double = 0,
        quality: SignalQuality = .high,
        detectedPeakCount: Int = 480
    ) -> WatchMeasurementResult {
        WatchMeasurementResult(selectedBPH: 28_800,
                               detectedBPH: 28_800,
                               rateSecondsPerDay: rateSecondsPerDay,
                               qualityScore: quality == .high ? 100 : 10,
                               quality: quality,
                               detectedPeakCount: detectedPeakCount,
                               validPeakCount: quality == .high ? 480 : 0,
                               expectedTickCount: 480,
                               beatCoverage: quality == .high ? 1 : 0,
                               outlierRatio: quality == .high ? 0 : 1,
                               chosenThresholdScale: 1,
                               rmsLevel: 0.01,
                               peakLevel: 0.10,
                               clippingRatio: 0,
                               estimatedSnrDb: 12,
                               periodicityScore: quality == .high ? 1 : 0,
                               detectionThreshold: 0.01,
                               envelopeMedian: 0.001,
                               envelopeP95: 0.01,
                               sampleRate: 48_000,
                               sampleCount: 2_880_000,
                               routeDescription: "Synthetic",
                               routeWarning: nil)
    }
}

final class MeasurementStateTests: XCTestCase {
    func testBeatRateSelectionIsEditableOnlyWhenIdle() {
        XCTAssertTrue(MeasurementState.idle.canEditBeatRate)
        XCTAssertFalse(MeasurementState.requestingPermission.canEditBeatRate)
        XCTAssertFalse(MeasurementState.measuring.canEditBeatRate)
        XCTAssertFalse(MeasurementState.analyzing.canEditBeatRate)
        XCTAssertFalse(MeasurementState.result(Self.makeResult()).canEditBeatRate)
        XCTAssertFalse(MeasurementState.failed("No microphone").canEditBeatRate)
    }

    func testForegroundAudioSessionIsRequiredOnlyAroundCaptureStartupAndRecording() {
        XCTAssertFalse(MeasurementState.idle.requiresForegroundAudioSession)
        XCTAssertTrue(MeasurementState.requestingPermission.requiresForegroundAudioSession)
        XCTAssertTrue(MeasurementState.measuring.requiresForegroundAudioSession)
        XCTAssertFalse(MeasurementState.analyzing.requiresForegroundAudioSession)
        XCTAssertFalse(MeasurementState.result(Self.makeResult()).requiresForegroundAudioSession)
        XCTAssertFalse(MeasurementState.failed("No microphone").requiresForegroundAudioSession)
    }

    private static func makeResult() -> WatchMeasurementResult {
        WatchMeasurementResult(selectedBPH: 28_800,
                               detectedBPH: 28_800,
                               rateSecondsPerDay: 0,
                               qualityScore: 100,
                               quality: .high,
                               detectedPeakCount: 480,
                               validPeakCount: 480,
                               expectedTickCount: 480,
                               beatCoverage: 1,
                               outlierRatio: 0,
                               chosenThresholdScale: 1,
                               rmsLevel: 0.01,
                               peakLevel: 0.10,
                               clippingRatio: 0,
                               estimatedSnrDb: 12,
                               periodicityScore: 1,
                               detectionThreshold: 0.01,
                               envelopeMedian: 0.001,
                               envelopeP95: 0.01,
                               sampleRate: 48_000,
                               sampleCount: 2_880_000,
                               routeDescription: "Synthetic",
                               routeWarning: nil)
    }
}
