import XCTest
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
        XCTAssertLessThan(result.detectionThreshold, 0.0005)
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

    private func makeSyntheticWatchSamples(
        rateSecondsPerDay: Double,
        nominalBPH: Int? = nil,
        duration: Double = 60,
        amplitudeScale: Float = 1,
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
        XCTAssertTrue(unstable.interpretation.contains("did not form a stable beat grid"))
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
                               beatCoverage: quality == .high ? 1 : 0,
                               outlierRatio: quality == .high ? 0 : 1,
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
                               beatCoverage: 1,
                               outlierRatio: 0,
                               detectionThreshold: 0.01,
                               envelopeMedian: 0.001,
                               envelopeP95: 0.01,
                               sampleRate: 48_000,
                               sampleCount: 2_880_000,
                               routeDescription: "Synthetic",
                               routeWarning: nil)
    }
}
