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

    func testShortCleanIslandInsideFullCaptureRemainsLowQuality() {
        var samples = makeSyntheticWatchSamples(rateSecondsPerDay: 5, duration: 12)
        samples.append(contentsOf: repeatElement(Float(0), count: Int(sampleRate * 48)))

        let result = WatchDSP.analyze(samples: samples,
                                      sampleRate: sampleRate,
                                      selectedBPH: selectedBPH,
                                      routeDescription: "Partial synthetic capture")

        XCTAssertEqual(result.quality, .low)
        XCTAssertLessThan(result.tickRecallEstimate, 0.30)
        XCTAssertLessThan(result.successfulWindowCount, result.analysisWindowCount)
        XCTAssertLessThan(result.qualityScore, 50)
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

    func testAutoBPHDetectsEverySupportedSyntheticBeatRate() {
        for beatRate in BeatRate.allCases {
            let samples = makeSyntheticWatchSamples(rateSecondsPerDay: 4,
                                                    nominalBPH: beatRate.rawValue,
                                                    duration: 12)

            let result = WatchDSP.analyzeAuto(samples: samples,
                                              sampleRate: sampleRate,
                                              routeDescription: "Auto synthetic \(beatRate.rawValue)")

            XCTAssertEqual(result.selectedBPH,
                           beatRate.rawValue,
                           "Wrong Auto BPH for synthetic \(beatRate.rawValue)")
            XCTAssertTrue(result.isAutoBPH)
            XCTAssertNotEqual(result.quality,
                              .low,
                              "Expected usable quality for synthetic \(beatRate.rawValue)")
            XCTAssertEqual(result.rateSecondsPerDay, 4, accuracy: 3)
        }
    }

    func testCandidateWeightingClampsDeduplicatesAndFindsNearestScore() {
        let weighting = TickCandidateWeighting(weights: [
            TickCandidateWeight(sampleIndex: 120, score: -0.4),
            TickCandidateWeight(sampleIndex: 120, score: 0.8),
            TickCandidateWeight(sampleIndex: 300, score: 1.4),
            TickCandidateWeight(sampleIndex: -1, score: 0.5),
            TickCandidateWeight(sampleIndex: 500, score: .nan)
        ])

        XCTAssertEqual(weighting.weights, [
            TickCandidateWeight(sampleIndex: 120, score: 0.8),
            TickCandidateWeight(sampleIndex: 300, score: 1)
        ])
        XCTAssertEqual(weighting.score(near: 124, toleranceSamples: 4), 0.8)
        XCTAssertEqual(weighting.score(near: 290, toleranceSamples: 10), 1)
        XCTAssertNil(weighting.score(near: 290, toleranceSamples: 9))
    }

    func testEqualCandidateWeightsPreserveProductionAutoResult() {
        let samples = makeSyntheticWatchSamples(rateSecondsPerDay: 4, duration: 12)
        let capture = AudioCapture(samples: samples,
                                   sampleRate: sampleRate,
                                   routeDescription: "Equal-weight synthetic")
        let pool = WatchDSP.makeCandidatePool(capture: capture)
        let weighting = TickCandidateWeighting(weights: pool.events.map {
            TickCandidateWeight(sampleIndex: $0.sampleIndex, score: 0.5)
        })

        let production = WatchDSP.analyzeAuto(capture: capture)
        let experimental = WatchDSP.analyzeAuto(capture: capture,
                                                candidateWeighting: weighting)

        XCTAssertFalse(pool.events.isEmpty)
        XCTAssertEqual(experimental.selectedBPH, production.selectedBPH)
        XCTAssertEqual(experimental.quality, production.quality)
        XCTAssertEqual(experimental.detectedPeakCount, production.detectedPeakCount)
        XCTAssertEqual(experimental.validPeakCount, production.validPeakCount)
        XCTAssertEqual(experimental.rateSecondsPerDay, production.rateSecondsPerDay, accuracy: 0.000_001)
    }

    func testCandidateWeightingPrefersPeriodicTicksOverNearbyJitteredDecoys() {
        let duration = 20.0
        var samples = Array(repeating: Float.zero, count: Int(duration * sampleRate))
        let period = 3_600.0 / Double(selectedBPH)
        let jitterPattern = [0.010, 0.050, 0.018, 0.045, 0.025, 0.040]
        var trueTickIndices: [Int] = []
        var beatIndex = 0
        var tickTime = 0.1
        while tickTime < duration - 0.1 {
            let tickIndex = Int((tickTime * sampleRate).rounded())
            let jitter = jitterPattern[beatIndex % jitterPattern.count]
            let decoyIndex = tickIndex - Int((jitter * sampleRate).rounded())
            addSyntheticTick(to: &samples,
                             at: decoyIndex,
                             beatIndex: beatIndex,
                             amplitudeScale: 1)
            addSyntheticTick(to: &samples,
                             at: tickIndex,
                             beatIndex: beatIndex,
                             amplitudeScale: 0.65)
            trueTickIndices.append(tickIndex)
            beatIndex += 1
            tickTime += period
        }

        let capture = AudioCapture(samples: samples,
                                   sampleRate: sampleRate,
                                   routeDescription: "Weighted collision synthetic")
        let pool = WatchDSP.makeCandidatePool(capture: capture)
        let trueTolerance = Int((sampleRate * 0.004).rounded())
        let weighting = TickCandidateWeighting(weights: pool.events.map { event in
            let isTrueTick = trueTickIndices.contains {
                abs($0 - event.sampleIndex) <= trueTolerance
            }
            return TickCandidateWeight(sampleIndex: event.sampleIndex,
                                       score: isTrueTick ? 1 : 0)
        })

        let production = WatchDSP.analyzeAuto(capture: capture)
        let experimental = WatchDSP.analyzeAuto(capture: capture,
                                                candidateWeighting: weighting)

        XCTAssertEqual(experimental.selectedBPH, selectedBPH)
        XCTAssertNotEqual(experimental.quality, .low)
        XCTAssertGreaterThan(experimental.periodicityScore, production.periodicityScore + 0.02)
        XCTAssertGreaterThan(experimental.qualityScore, production.qualityScore + 5)
        XCTAssertLessThan(abs(experimental.rateSecondsPerDay), abs(production.rateSecondsPerDay))
    }

    func testAutoBPHPreservesTooQuietFailureReason() {
        let samples = Array(repeating: Float(0), count: Int(sampleRate * 12))

        let result = WatchDSP.analyzeAuto(samples: samples,
                                          sampleRate: sampleRate,
                                          routeDescription: "Auto silence")

        XCTAssertEqual(result.quality, .low)
        XCTAssertEqual(result.dominantFailureReason, .tooQuiet)
    }

    func testAutoBPHRejectsNarrowWinnerMarginEvenWithUsableGrid() {
        let isAmbiguous = WatchDSP.autoSelectionIsAmbiguous(bestScore: 0.76,
                                                            secondScore: 0.73,
                                                            verifiedQuality: .high,
                                                            outlierRatio: 0.10,
                                                            periodicityScore: 0.85)

        XCTAssertTrue(isAmbiguous)
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

    func testKingSeikoFixtureRejectsWrongBeatRate() throws {
        let fixture = try loadFixture(named: "king-seiko-28800-10-30s")

        let result = WatchDSP.analyze(samples: fixture.samples,
                                      sampleRate: fixture.sampleRate,
                                      selectedBPH: BeatRate.bph21600.rawValue,
                                      routeDescription: "King Seiko fixture")

        XCTAssertEqual(result.quality, .low)
        XCTAssertLessThan(result.qualityScore, 50)
    }

    func testRealDeviceBottomMicFixtureDetectsSelectedBeatRate() throws {
        let fixture = try loadFixture(named: "iphone-bottom-28800-0-20s")

        let result = WatchDSP.analyze(samples: fixture.samples,
                                      sampleRate: fixture.sampleRate,
                                      selectedBPH: selectedBPH,
                                      routeDescription: "iPhone bottom mic fixture")

        XCTAssertNotEqual(result.quality, .low)
        XCTAssertGreaterThanOrEqual(result.validPeakCount, 140)
        XCTAssertGreaterThanOrEqual(result.beatCoverage, 0.85)
        XCTAssertGreaterThanOrEqual(result.tickRecallEstimate, 0.85)
    }

    func testAutoBPHFixtureManifestOutcomes() throws {
        let manifest = try loadRecognitionFixtureManifest()
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertFalse(manifest.fixtures.isEmpty)

        for spec in manifest.fixtures {
            XCTAssertFalse(spec.sourceCaptureID.isEmpty)
            let fixture = try loadFixture(named: spec.resourceName)
            XCTAssertEqual(Double(fixture.samples.count) / fixture.sampleRate,
                           spec.durationSeconds,
                           accuracy: 0.01,
                           "Unexpected fixture duration for \(spec.resourceName)")

            let result = WatchDSP.analyzeAuto(samples: fixture.samples,
                                              sampleRate: fixture.sampleRate,
                                              routeDescription: spec.resourceName)

            switch spec.expectedAutoOutcome {
            case .recognize:
                XCTAssertEqual(result.selectedBPH,
                               spec.knownBPH,
                               "Wrong Auto BPH for \(spec.resourceName)")
                XCTAssertNotEqual(result.quality,
                                  .low,
                                  "Expected a usable Auto result for \(spec.resourceName)")
                XCTAssertNotEqual(result.dominantFailureReason,
                                  .ambiguousBeatRate,
                                  "Unexpected Auto ambiguity for \(spec.resourceName)")
            case .reject:
                XCTAssertEqual(result.quality,
                               .low,
                               "A fixture without independent periodic evidence must stay low quality")
            }
        }
    }

    func testHighFrequencyPeriodicityIdentifiesTudorBeatRate() throws {
        let fixture = try loadFixture(named: "tudor-gmt-28800-40-60s")

        let scores = WatchDSP.autoSpectralPeriodicityScores(samples: fixture.samples,
                                                            sampleRate: fixture.sampleRate)
        let selectedScore = try XCTUnwrap(scores[selectedBPH])
        let strongestWrongScore = try XCTUnwrap(scores
            .filter { $0.key != selectedBPH }
            .map(\.value)
            .max())

        XCTAssertGreaterThan(selectedScore, 0.50)
        XCTAssertGreaterThan(selectedScore - strongestWrongScore, 0.50)
    }

    func testKingSeikoFixtureDoesNotInventSpectralPeriodicity() throws {
        let fixture = try loadFixture(named: "king-seiko-28800-10-30s")

        let scores = WatchDSP.autoSpectralPeriodicityScores(samples: fixture.samples,
                                                            sampleRate: fixture.sampleRate)
        let strongestScore = try XCTUnwrap(scores.values.max())

        XCTAssertLessThan(strongestScore, 0.05)
    }

    func testAlternatingSpectralConsensusIdentifiesKingSeikoBeatRate() throws {
        let fixture = try loadFixture(named: "king-seiko-28800-10-30s")

        let consensus = WatchDSP.autoAlternatingSpectralConsensusScores(
            samples: fixture.samples,
            sampleRate: fixture.sampleRate
        )
        let alternatingPeriodicity = WatchDSP.autoAlternatingSpectralPeriodicityScores(
            samples: fixture.samples,
            sampleRate: fixture.sampleRate
        )
        let result = WatchDSP.analyzeAuto(samples: fixture.samples,
                                          sampleRate: fixture.sampleRate,
                                          routeDescription: "King Seiko alternating consensus")

        let selectedAlternatingScore = try XCTUnwrap(alternatingPeriodicity[selectedBPH])
        let strongestWrongScore = try XCTUnwrap(alternatingPeriodicity
            .filter { $0.key != selectedBPH }
            .map(\.value)
            .max())
        XCTAssertGreaterThanOrEqual(selectedAlternatingScore, 0.03)
        XCTAssertGreaterThanOrEqual(selectedAlternatingScore - strongestWrongScore, 0.025)
        XCTAssertEqual(consensus[selectedBPH], 1)
        XCTAssertTrue(consensus
            .filter { $0.key != selectedBPH }
            .allSatisfy { $0.value == 0 })
        XCTAssertEqual(result.selectedBPH, selectedBPH)
        XCTAssertNotEqual(result.quality, .low)
        XCTAssertEqual(result.alternatingSpectralPeriodicityScore,
                       selectedAlternatingScore,
                       accuracy: 0.000_001)
        XCTAssertEqual(result.alternatingSpectralConsensus, 1)
        XCTAssertNil(result.dominantFailureReason)
    }

    func testRandomHighFrequencyImpulsesDoNotCreateAlternatingConsensus() {
        var samples = Array(repeating: Float.zero, count: Int(sampleRate * 20))
        addWhiteNoise(to: &samples, amplitude: 0.0005, seed: 0xA17E)
        addImpulseNoise(to: &samples, count: 600, amplitude: 0.08, seed: 0xB17E)

        let consensus = WatchDSP.autoAlternatingSpectralConsensusScores(
            samples: samples,
            sampleRate: sampleRate
        )
        let result = WatchDSP.analyzeAuto(samples: samples,
                                          sampleRate: sampleRate,
                                          routeDescription: "Random high-frequency impulses")

        XCTAssertTrue(consensus.values.allSatisfy { $0 == 0 })
        XCTAssertEqual(result.quality, .low)
    }

    func testAlternatingSpectralConsensusCannotPromoteModulatedNoiseGrid() {
        var samples = Array(repeating: Float.zero, count: Int(sampleRate * 20))
        for index in samples.indices {
            let time = Double(index) / sampleRate
            let modulation = max(0, sin(2 * Double.pi * 4 * time))
            samples[index] = Float(sin(2 * Double.pi * 12_000 * time) * modulation * 0.02)
        }
        addWhiteNoise(to: &samples, amplitude: 0.0005, seed: 0x4)

        let consensus = WatchDSP.autoAlternatingSpectralConsensusScores(
            samples: samples,
            sampleRate: sampleRate
        )
        let result = WatchDSP.analyzeAuto(samples: samples,
                                          sampleRate: sampleRate,
                                          routeDescription: "Amplitude-modulated noise")

        XCTAssertEqual(consensus[selectedBPH], 1)
        XCTAssertEqual(result.quality, .low)
        XCTAssertLessThan(result.recognitionConfidence, 0.50)
    }

    func testIndependentSinglePeriodEvidenceResolvesTudorAmbiguity() throws {
        let fixture = try loadFixture(named: "tudor-gmt-28800-0-20s")

        let result = WatchDSP.analyzeAuto(samples: fixture.samples,
                                          sampleRate: fixture.sampleRate,
                                          routeDescription: "Tudor independent spectral evidence")

        XCTAssertEqual(result.selectedBPH, selectedBPH)
        XCTAssertNotEqual(result.quality, .low)
        XCTAssertGreaterThanOrEqual(result.beatCoverage, 0.80)
        XCTAssertGreaterThanOrEqual(result.tickRecallEstimate, 0.80)
        XCTAssertGreaterThanOrEqual(result.spectralPeriodicityScore, 0.20)
        XCTAssertEqual(result.alternatingSpectralConsensus, 0)
        XCTAssertNil(result.dominantFailureReason)
    }

    func testIndependentAlternatingEvidenceResolvesTudorRunnerUpGrid() throws {
        let fixture = try loadFixture(named: "tudor-gmt-28800-0-30s")
        let start = Int((10 * fixture.sampleRate).rounded())
        let frameCount = Int((20 * fixture.sampleRate).rounded())
        let samples = Array(fixture.samples[start..<(start + frameCount)])

        let result = WatchDSP.analyzeAuto(samples: samples,
                                          sampleRate: fixture.sampleRate,
                                          routeDescription: "Tudor alternating runner-up")

        XCTAssertEqual(result.selectedBPH, selectedBPH)
        XCTAssertNotEqual(result.quality, .low)
        XCTAssertGreaterThanOrEqual(result.beatCoverage, 0.80)
        XCTAssertGreaterThanOrEqual(result.tickRecallEstimate, 0.80)
        XCTAssertGreaterThanOrEqual(result.spectralPeriodicityScore, 0.20)
        XCTAssertEqual(result.alternatingSpectralConsensus, 1)
        XCTAssertNil(result.dominantFailureReason)
    }

    func testStationaryHighFrequencyNoiseDoesNotCreateAutoBeatRate() {
        var samples = Array(repeating: Float.zero, count: Int(sampleRate * 12))
        addSine(to: &samples, frequency: 12_000, amplitude: 0.02)
        addWhiteNoise(to: &samples, amplitude: 0.001, seed: 0x12_000)

        let result = WatchDSP.analyzeAuto(samples: samples,
                                          sampleRate: sampleRate,
                                          routeDescription: "Stationary high-frequency noise")

        XCTAssertEqual(result.quality, .low)
        XCTAssertLessThan(result.recognitionConfidence, 0.50)
    }

    func testTudorFullDeviceCaptureAutoDetectsBeatRateEndToEnd() throws {
        let fixture = try loadFullTudorDeviceCapture()

        let result = WatchDSP.analyzeAuto(samples: fixture.samples,
                                          sampleRate: fixture.sampleRate,
                                          routeDescription: "Tudor GMT full device capture")

        XCTAssertEqual(result.selectedBPH, selectedBPH)
        XCTAssertTrue(result.isAutoBPH)
        XCTAssertEqual(result.quality, .medium)
        XCTAssertNil(result.dominantFailureReason)
        XCTAssertGreaterThanOrEqual(result.beatCoverage, 0.85)
        XCTAssertGreaterThanOrEqual(result.tickRecallEstimate, 0.85)
        XCTAssertGreaterThanOrEqual(result.successfulWindowCount,
                                    Int(ceil(Double(result.analysisWindowCount) * 0.90)))

        let windows = fixtureWindows(samples: fixture.samples,
                                     sampleRate: fixture.sampleRate,
                                     duration: 20,
                                     hop: 20)
        XCTAssertEqual(windows.count, 3)
        for window in windows {
            let windowResult = WatchDSP.analyzeAuto(samples: window.samples,
                                                    sampleRate: fixture.sampleRate,
                                                    routeDescription: "Tudor GMT \(window.start)-second window")
            XCTAssertEqual(windowResult.selectedBPH,
                           selectedBPH,
                           "Wrong Auto BPH at \(window.start) seconds")
            XCTAssertNotEqual(windowResult.quality,
                              .low,
                              "Expected usable Auto result at \(window.start) seconds")
        }
    }

    func testTudorFullDeviceCaptureRejectsManualWrongBPHWithinThirtySeconds() throws {
        let fixture = try loadFullTudorDeviceCapture()

        let start = ProcessInfo.processInfo.systemUptime
        let result = WatchDSP.analyze(samples: fixture.samples,
                                      sampleRate: fixture.sampleRate,
                                      selectedBPH: BeatRate.bph21600.rawValue,
                                      routeDescription: "Tudor GMT wrong manual BPH")
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        XCTAssertLessThan(elapsed, 30, "Manual BPH verification exceeded the 30-second requirement.")
        XCTAssertEqual(result.quality, .low)
        XCTAssertEqual(result.dominantFailureReason, .wrongBPHLikely)
        XCTAssertLessThan(result.qualityScore, 50)
        XCTAssertLessThan(result.recognitionConfidence, 0.50)
    }

    func testTudorFixtureRejectsEverySupportedManualWrongBPH() throws {
        let fixture = try loadFixture(named: "tudor-gmt-28800-0-20s")
        let wrongBeatRates = BeatRate.allCases.map(\.rawValue).filter { $0 != selectedBPH }

        for beatRate in wrongBeatRates {
            let result = WatchDSP.analyze(samples: fixture.samples,
                                          sampleRate: fixture.sampleRate,
                                          selectedBPH: beatRate,
                                          routeDescription: "Tudor GMT wrong \(beatRate) BPH")

            XCTAssertEqual(result.quality, .low, "Expected \(beatRate) BPH to be rejected.")
            XCTAssertNotNil(result.dominantFailureReason)
            XCTAssertLessThan(result.qualityScore, 50)
            XCTAssertLessThan(result.recognitionConfidence, 0.50)
        }
    }

    func testFullDurationNoisyFixtureAutoAnalysisCompletesWithinThirtySeconds() throws {
        let fixture = try loadFullTudorDeviceCapture()

        let start = ProcessInfo.processInfo.systemUptime
        let result = WatchDSP.analyzeAuto(samples: fixture.samples,
                                          sampleRate: fixture.sampleRate,
                                          routeDescription: "Tudor GMT performance fixture")
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        XCTAssertLessThan(elapsed, 30, "Auto BPH post-processing exceeded the 30-second requirement.")
        XCTAssertTrue(result.isAutoBPH)
        XCTAssertEqual(result.sampleCount, fixture.samples.count)
    }

    func testRealDeviceBottomMicFixtureRejectsWrongBeatRates() throws {
        let fixture = try loadFixture(named: "iphone-bottom-28800-0-20s")
        let wrongBeatRates = BeatRate.allCases.map(\.rawValue).filter { $0 != selectedBPH }

        for beatRate in wrongBeatRates {
            let result = WatchDSP.analyze(samples: fixture.samples,
                                          sampleRate: fixture.sampleRate,
                                          selectedBPH: beatRate,
                                          routeDescription: "iPhone bottom mic fixture")

            XCTAssertEqual(result.quality, .low, "Expected \(beatRate) bph to be rejected.")
            XCTAssertLessThan(result.qualityScore, 50)
        }
    }

    func testHighBeatRateWatchCannotMasqueradeAsHalfRate() {
        let samples = makeSyntheticWatchSamples(rateSecondsPerDay: 0,
                                                nominalBPH: BeatRate.bph36000.rawValue,
                                                duration: 20)

        let result = WatchDSP.analyze(samples: samples,
                                      sampleRate: sampleRate,
                                      selectedBPH: BeatRate.bph18000.rawValue,
                                      routeDescription: "Half-rate harmonic")

        XCTAssertEqual(result.quality, .low)
        XCTAssertEqual(result.dominantFailureReason, .wrongBPHLikely)
        XCTAssertLessThan(result.qualityScore, 50)
    }

    func testRealFixtureBenchmarkWindowsMeetRecognitionGate() throws {
        let fixtureSpecs = [
            LabeledFixture(name: "king-seiko-28800-10-30s", bph: selectedBPH),
            LabeledFixture(name: "iphone-bottom-28800-0-20s", bph: selectedBPH),
            LabeledFixture(name: "tudor-gmt-28800-40-60s", bph: selectedBPH)
        ]
        var outcomes: [FixtureWindowOutcome] = []

        for spec in fixtureSpecs {
            let fixture = try loadFixture(named: spec.name)
            for window in fixtureWindows(samples: fixture.samples,
                                         sampleRate: fixture.sampleRate,
                                         duration: 20,
                                         hop: 5) {
                let result = WatchDSP.analyze(samples: window.samples,
                                              sampleRate: fixture.sampleRate,
                                              selectedBPH: spec.bph,
                                              routeDescription: spec.name)
                let passed = result.quality != .low
                    && result.beatCoverage >= 0.70
                    && result.periodicityScore >= 0.50
                outcomes.append(FixtureWindowOutcome(fixtureName: spec.name,
                                                     start: window.start,
                                                     result: result,
                                                     passed: passed))
            }
        }

        XCTAssertFalse(outcomes.isEmpty)
        let successCount = outcomes.filter(\.passed).count
        let successRate = Double(successCount) / Double(outcomes.count)
        if outcomes.count >= 30 {
            XCTAssertGreaterThanOrEqual(successRate, 0.90)
        } else {
            XCTAssertEqual(successCount, outcomes.count, "All available real fixture windows should pass until the 30-window 90% gate is populated.")
        }
    }

    func testDebugCaptureExportWritesAudioDiagnosticsAndCandidateTrace() throws {
        let samples = makeSyntheticWatchSamples(rateSecondsPerDay: 5, duration: 12)
        let capture = AudioCapture(samples: samples,
                                   sampleRate: sampleRate,
                                   routeDescription: "Synthetic microphone",
                                   routeWarning: nil,
                                   capturedAt: Date(timeIntervalSince1970: 1_725_000_000))
        let result = WatchDSP.analyze(capture: capture, selectedBPH: selectedBPH)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchAccuracyExportTests-\(UUID().uuidString)", isDirectory: true)

        let export = try AudioCaptureExporter.export(capture: capture,
                                                     result: result,
                                                     directory: directory)

        XCTAssertTrue(FileManager.default.fileExists(atPath: export.audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.diagnosticsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.candidateTraceURL.path))

        let exportedAudio = try AVAudioFile(forReading: export.audioURL)
        XCTAssertEqual(Int(exportedAudio.length), samples.count)
        XCTAssertEqual(exportedAudio.processingFormat.sampleRate, sampleRate, accuracy: 0.1)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: export.diagnosticsURL)) as? [String: Any]
        XCTAssertEqual(json?["audioFileName"] as? String, "capture.wav")
        XCTAssertEqual(json?["selectedBPH"] as? Int, selectedBPH)
        XCTAssertEqual(json?["isAutoBPH"] as? Bool, false)
        XCTAssertEqual(json?["routeDescription"] as? String, "Synthetic microphone")
        XCTAssertNotNil(json?["recognitionConfidence"])
        XCTAssertNotNil(json?["spectralPeriodicityScore"])
        XCTAssertNotNil(json?["alternatingSpectralPeriodicityScore"])
        XCTAssertNotNil(json?["alternatingSpectralConsensus"])

        let traceData = try Data(contentsOf: export.candidateTraceURL)
        let trace = try JSONDecoder().decode(TickCandidateTrace.self, from: traceData)
        XCTAssertEqual(trace.schemaVersion, 1)
        XCTAssertEqual(trace.selectedBPH, selectedBPH)
        XCTAssertEqual(trace.sampleRate, sampleRate)
        XCTAssertEqual(trace.sampleCount, samples.count)
        XCTAssertEqual(trace.snippetFrameCount, 2_048)
        XCTAssertEqual(trace.snippetCenterOffset, 1_024)
        XCTAssertFalse(trace.events.isEmpty)
        XCTAssertGreaterThanOrEqual(trace.sourceCandidateCount, trace.mergedCandidateCount)
        XCTAssertGreaterThanOrEqual(trace.mergedCandidateCount, trace.events.count)
        XCTAssertLessThanOrEqual(trace.events.count, 4_000)
        XCTAssertTrue(trace.events.contains { $0.provisionalLabel == .likelyTick })
        XCTAssertTrue(trace.events.allSatisfy { samples.indices.contains($0.sampleIndex) })

        try? FileManager.default.removeItem(at: directory)
    }

    func testLowQualityCandidateTraceLeavesAllLabelsUnknown() {
        var samples = Array(repeating: Float.zero, count: Int(sampleRate * 12))
        addImpulseNoise(to: &samples, count: 180, amplitude: 0.18, seed: 0xBAD)
        let capture = AudioCapture(samples: samples,
                                   sampleRate: sampleRate,
                                   routeDescription: "Random impulse noise")
        let result = WatchDSP.analyzeAuto(capture: capture)

        let trace = WatchDSP.makeCandidateTrace(capture: capture, result: result)

        XCTAssertEqual(result.quality, .low)
        XCTAssertFalse(trace.events.isEmpty)
        XCTAssertTrue(trace.events.allSatisfy { $0.provisionalLabel == .unknown })
    }

    func testCandidateTraceSelectionKeepsTicksAndBalancesBoundedNegatives() {
        func events(count: Int, start: Int, label: TickCandidateProvisionalLabel) -> [TickCandidateEvent] {
            (0..<count).map { offset in
                let sampleIndex = start + offset * 10
                return TickCandidateEvent(sampleIndex: sampleIndex,
                                          timeSeconds: Double(sampleIndex) / sampleRate,
                                          normalizedEnvelope: Double((offset % 37) + 1),
                                          nearestAssignedDistanceSeconds: nil,
                                          provisionalLabel: label)
            }
        }

        let candidates = events(count: 500, start: 0, label: .likelyTick)
            + events(count: 5_000, start: 100_000, label: .unknown)
            + events(count: 5_000, start: 200_000, label: .likelyNoise)

        let selected = WatchDSP.selectCandidateTraceEvents(candidates)
        let selectedAgain = WatchDSP.selectCandidateTraceEvents(candidates)

        XCTAssertEqual(selected.count, 3_500)
        XCTAssertEqual(selected.filter { $0.provisionalLabel == .likelyTick }.count, 500)
        XCTAssertEqual(selected.filter { $0.provisionalLabel == .unknown }.count, 1_000)
        XCTAssertEqual(selected.filter { $0.provisionalLabel == .likelyNoise }.count, 2_000)
        XCTAssertEqual(selected.map(\.sampleIndex), selectedAgain.map(\.sampleIndex))
        XCTAssertEqual(selected.map(\.sampleIndex), selected.map(\.sampleIndex).sorted())

        let underLimitButImbalanced = events(count: 100, start: 0, label: .likelyTick)
            + events(count: 100, start: 100_000, label: .unknown)
            + events(count: 2_000, start: 200_000, label: .likelyNoise)
        let balanced = WatchDSP.selectCandidateTraceEvents(underLimitButImbalanced)

        XCTAssertEqual(balanced.filter { $0.provisionalLabel == .likelyTick }.count, 100)
        XCTAssertEqual(balanced.filter { $0.provisionalLabel == .unknown }.count, 100)
        XCTAssertEqual(balanced.filter { $0.provisionalLabel == .likelyNoise }.count, 512)
    }

    func testAudioCaptureComputesLevelDiagnostics() {
        let capture = AudioCapture(samples: [0, 0.5, -1, 1],
                                   sampleRate: 4,
                                   routeDescription: "Synthetic")

        XCTAssertEqual(capture.duration, 1, accuracy: 0.001)
        XCTAssertEqual(capture.levels.peakLevel, 1, accuracy: 0.001)
        XCTAssertEqual(capture.levels.clippingRatio, 0.5, accuracy: 0.001)
        XCTAssertGreaterThan(capture.levels.rmsLevel, 0.70)
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
        let channels = max(1, Int(format.channelCount))
        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))

        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let requestedFrames = AVAudioFrameCount(min(remaining, 65_536))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format,
                                                       frameCapacity: requestedFrames))
            try file.read(into: buffer, frameCount: requestedFrames)
            guard buffer.frameLength > 0 else { break }
            let channelData = try XCTUnwrap(buffer.floatChannelData)

            for frame in 0..<Int(buffer.frameLength) {
                var mixed: Float = 0
                for channel in 0..<channels {
                    mixed += channelData[channel][frame]
                }
                samples.append(mixed / Float(channels))
            }
        }

        XCTAssertEqual(samples.count, Int(file.length), "Fixture decoder returned a short read for \(name).")
        return (samples, format.sampleRate)
    }

    private func loadRecognitionFixtureManifest() throws -> RecognitionFixtureManifest {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "recognition-fixtures",
                                           withExtension: "json"))
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(RecognitionFixtureManifest.self, from: data)
    }

    private func loadFullTudorDeviceCapture() throws -> (samples: [Float], sampleRate: Double) {
        let firstHalf = try loadFixture(named: "tudor-gmt-28800-0-30s")
        let secondHalf = try loadFixture(named: "tudor-gmt-28800-30-60s")
        XCTAssertEqual(firstHalf.sampleRate, secondHalf.sampleRate)

        let halfDurationSampleCount = Int((30 * firstHalf.sampleRate).rounded())
        XCTAssertEqual(firstHalf.samples.count, halfDurationSampleCount)
        XCTAssertEqual(secondHalf.samples.count, halfDurationSampleCount)

        var samples = firstHalf.samples
        samples.append(contentsOf: secondHalf.samples)
        XCTAssertEqual(samples.count, halfDurationSampleCount * 2)
        return (samples, firstHalf.sampleRate)
    }

    private struct LabeledFixture {
        let name: String
        let bph: Int
    }

    private struct RecognitionFixtureManifest: Decodable {
        let schemaVersion: Int
        let fixtures: [RecognitionFixtureSpec]
    }

    private struct RecognitionFixtureSpec: Decodable {
        let resourceName: String
        let sourceCaptureID: String
        let knownBPH: Int
        let durationSeconds: Double
        let expectedAutoOutcome: AutoFixtureOutcome
    }

    private enum AutoFixtureOutcome: String, Decodable {
        case recognize
        case reject
    }

    private struct FixtureWindow {
        let start: Double
        let samples: [Float]
    }

    private struct FixtureWindowOutcome {
        let fixtureName: String
        let start: Double
        let result: WatchMeasurementResult
        let passed: Bool
    }

    private func fixtureWindows(samples: [Float],
                                sampleRate: Double,
                                duration: Double,
                                hop: Double) -> [FixtureWindow] {
        let windowSize = Int((duration * sampleRate).rounded())
        let hopSize = max(1, Int((hop * sampleRate).rounded()))
        guard windowSize > 0, samples.count > windowSize else {
            return [FixtureWindow(start: 0, samples: samples)]
        }

        var windows: [FixtureWindow] = []
        var startIndex = 0
        while startIndex + windowSize <= samples.count {
            let endIndex = startIndex + windowSize
            windows.append(FixtureWindow(start: Double(startIndex) / sampleRate,
                                         samples: Array(samples[startIndex..<endIndex])))
            startIndex += hopSize
        }
        return windows
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
        let samples = makeSyntheticWatchSamples(rateSecondsPerDay: 11, duration: 12)
        let audioMeter = FakeAudioMeter(samples: samples,
                                        sampleRate: sampleRate,
                                        routeDescription: "Synthetic microphone")
        let viewModel = MeasurementViewModel(audioMeter: audioMeter,
                                             measurementDuration: 0.01)
        viewModel.selectedBPH = .manual(.bph28800)

        viewModel.startMeasurement()

        try await waitUntil(timeout: 15) {
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

    func testFullDurationAutoMeasurementLeavesAnalyzingState() async throws {
        let samples = makeSyntheticWatchSamples(rateSecondsPerDay: -7,
                                                duration: 60)
        let audioMeter = FakeAudioMeter(samples: samples,
                                        sampleRate: sampleRate,
                                        routeDescription: "Full-duration synthetic microphone")
        let viewModel = MeasurementViewModel(audioMeter: audioMeter,
                                             measurementDuration: 0.01)
        viewModel.selectedBPH = .auto

        viewModel.startMeasurement()

        try await waitUntil(timeout: 15) {
            if case .result = viewModel.state { return true }
            return false
        }

        guard case .result(let result) = viewModel.state else {
            return XCTFail("Expected Auto BPH analysis to leave the analyzing state.")
        }

        XCTAssertEqual(result.selectedBPH, selectedBPH)
        XCTAssertTrue(result.isAutoBPH)
        XCTAssertNotEqual(result.quality, .low)
        XCTAssertEqual(result.sampleCount, samples.count)
        XCTAssertEqual(audioMeter.stopAndReturnSamplesCallCount, 1)
    }

    func testAnalysisDeadlineLeavesAnalyzingStateWithFailure() async throws {
        let samples = makeSyntheticWatchSamples(rateSecondsPerDay: 0,
                                                duration: 12)
        let audioMeter = FakeAudioMeter(samples: samples,
                                        sampleRate: sampleRate)
        let stalledAnalysis: WatchAnalysisOperation = { capture, _ in
            Thread.sleep(forTimeInterval: 0.20)
            return WatchDSP.analyze(capture: capture, selectedBPH: 28_800)
        }
        let viewModel = MeasurementViewModel(audioMeter: audioMeter,
                                             measurementDuration: 0.01,
                                             analysisTimeout: 0.02,
                                             analysisOperation: stalledAnalysis)

        viewModel.startMeasurement()

        try await waitUntil(timeout: 2) {
            if case .failed = viewModel.state { return true }
            return false
        }

        guard case .failed(let message) = viewModel.state else {
            return XCTFail("Expected analysis timeout to leave the analyzing state.")
        }

        XCTAssertTrue(message.contains("analysis took longer"))
        XCTAssertEqual(audioMeter.stopAndReturnSamplesCallCount, 1)
    }

    func testDebugExportRunsAsynchronouslyAndPublishesResult() async throws {
        let samples = makeSyntheticWatchSamples(rateSecondsPerDay: 3, duration: 12)
        let audioMeter = FakeAudioMeter(samples: samples,
                                        sampleRate: sampleRate,
                                        routeDescription: "Synthetic microphone")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AsyncWatchExport-\(UUID().uuidString)", isDirectory: true)
        let exportOperation: AudioCaptureExportOperation = { _, _ in
            Thread.sleep(forTimeInterval: 0.10)
            return AudioCaptureExport(directoryURL: directory,
                                      audioURL: directory.appendingPathComponent("capture.wav"),
                                      diagnosticsURL: directory.appendingPathComponent("diagnostics.json"),
                                      candidateTraceURL: directory.appendingPathComponent("candidates.json"))
        }
        let viewModel = MeasurementViewModel(audioMeter: audioMeter,
                                             measurementDuration: 0.01,
                                             exportOperation: exportOperation)
        viewModel.selectedBPH = .manual(.bph28800)
        viewModel.startMeasurement()

        try await waitUntil(timeout: 15) {
            if case .result = viewModel.state { return true }
            return false
        }

        viewModel.exportLastMeasurement()

        XCTAssertTrue(viewModel.isExporting)
        XCTAssertEqual(viewModel.exportStatusText, "Preparing debug export…")
        try await waitUntil(timeout: 2) { !viewModel.isExporting }
        XCTAssertEqual(viewModel.latestExportURL, directory)
        XCTAssertEqual(viewModel.exportStatusText, "Debug capture exported.")
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
        try await waitUntil { audioMeter.stopCallCount == 1 }
    }

    func testMeasurementDurationTextUsesConfiguredDuration() {
        let audioMeter = FakeAudioMeter(samples: [], sampleRate: sampleRate)
        let viewModel = MeasurementViewModel(audioMeter: audioMeter,
                                             measurementDuration: 12)

        XCTAssertEqual(viewModel.measurementDurationText, "12 sec")
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

    func testUnsupportedInputRouteFailsImmediately() async throws {
        let samples = makeSyntheticWatchSamples(rateSecondsPerDay: 0)
        let audioMeter = FakeAudioMeter(samples: samples,
                                        sampleRate: sampleRate,
                                        routeWarning: "Use the built-in iPhone microphone.")
        let viewModel = MeasurementViewModel(audioMeter: audioMeter,
                                             measurementDuration: 60)

        viewModel.startMeasurement()

        try await waitUntil {
            if case .failed = viewModel.state { return true }
            return false
        }

        guard case .failed(let message) = viewModel.state else {
            return XCTFail("Expected a failed state.")
        }

        XCTAssertTrue(message.contains("built-in iPhone microphone"))
        XCTAssertEqual(audioMeter.startCallCount, 1)
        XCTAssertEqual(audioMeter.stopCallCount, 1)
    }

    func testQuietPreflightFailsBeforeFullMeasurementDuration() async throws {
        let samples = Array(repeating: Float(0), count: Int(sampleRate * 60))
        let audioMeter = FakeAudioMeter(samples: samples,
                                        sampleRate: sampleRate,
                                        latestLevels: AudioLevelStats(rmsLevel: 0.0001,
                                                                      peakLevel: 0.0005,
                                                                      clippingRatio: 0))
        let viewModel = MeasurementViewModel(audioMeter: audioMeter,
                                             measurementDuration: 0.25)

        viewModel.startMeasurement()

        try await waitUntil {
            if case .failed = viewModel.state { return true }
            return false
        }

        guard case .failed(let message) = viewModel.state else {
            return XCTFail("Expected a failed state.")
        }

        XCTAssertTrue(message.contains("too quiet"))
        XCTAssertEqual(audioMeter.startCallCount, 1)
        XCTAssertEqual(audioMeter.stopCallCount, 1)
        XCTAssertEqual(audioMeter.stopAndReturnSamplesCallCount, 0)
    }

    func testPreflightUsesPeakActivityAcrossAudioBuffers() async throws {
        let samples = makeSyntheticWatchSamples(rateSecondsPerDay: 0, duration: 12)
        let audioMeter = FakeAudioMeter(samples: samples,
                                        sampleRate: sampleRate,
                                        latestLevels: AudioLevelStats(rmsLevel: 0.0001,
                                                                      peakLevel: 0.0005,
                                                                      clippingRatio: 0),
                                        peakLevelSinceStart: 0.02)
        let viewModel = MeasurementViewModel(audioMeter: audioMeter,
                                             measurementDuration: 0.10)
        viewModel.selectedBPH = .manual(.bph28800)

        viewModel.startMeasurement()

        try await waitUntil(timeout: 15) {
            if case .result = viewModel.state { return true }
            return false
        }

        XCTAssertEqual(audioMeter.stopAndReturnSamplesCallCount, 1)
    }

    func testRouteChangeFailureStopsMeasurement() async throws {
        let samples = makeSyntheticWatchSamples(rateSecondsPerDay: 0)
        let audioMeter = FakeAudioMeter(samples: samples,
                                        sampleRate: sampleRate,
                                        captureFailure: .routeChangedDuringCapture)
        let viewModel = MeasurementViewModel(audioMeter: audioMeter,
                                             measurementDuration: 60)

        viewModel.startMeasurement()

        try await waitUntil {
            if case .failed = viewModel.state { return true }
            return false
        }

        guard case .failed(let message) = viewModel.state else {
            return XCTFail("Expected a failed state.")
        }

        XCTAssertTrue(message.contains("route changed"))
        XCTAssertEqual(audioMeter.startCallCount, 1)
        XCTAssertEqual(audioMeter.stopCallCount, 1)
        XCTAssertEqual(audioMeter.stopAndReturnSamplesCallCount, 0)
    }

    func testInactiveSceneStopsInjectedAudioMeasurement() async throws {
        let samples = makeSyntheticWatchSamples(rateSecondsPerDay: 0)
        let audioMeter = FakeAudioMeter(samples: samples, sampleRate: sampleRate)
        let viewModel = MeasurementViewModel(audioMeter: audioMeter,
                                             measurementDuration: 5)

        viewModel.startMeasurement()

        try await waitUntil { viewModel.isMeasuring }
        viewModel.stopForInactiveScene()

        try await waitUntil { audioMeter.stopCallCount == 1 }
        XCTAssertTrue(viewModel.canEditBeatRate)
        XCTAssertEqual(audioMeter.startCallCount, 1)
        XCTAssertEqual(audioMeter.stopCallCount, 1)
    }

    func testCancelStopsInjectedAudioOnlyOnce() async throws {
        let samples = makeSyntheticWatchSamples(rateSecondsPerDay: 0)
        let audioMeter = FakeAudioMeter(samples: samples, sampleRate: sampleRate)
        let viewModel = MeasurementViewModel(audioMeter: audioMeter,
                                             measurementDuration: 5)

        viewModel.startMeasurement()

        try await waitUntil { viewModel.isMeasuring }
        viewModel.cancelMeasurement()

        try await waitUntil { audioMeter.stopCallCount == 1 }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(viewModel.canEditBeatRate)
        XCTAssertEqual(audioMeter.startCallCount, 1)
        XCTAssertEqual(audioMeter.stopCallCount, 1)
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
    var captureFailure: AudioMeterError?
    var latestLevels: AudioLevelStats {
        lock.lock()
        let levels = storedLatestLevels
        lock.unlock()
        return levels
    }
    var peakLevelSinceStart: Double {
        lock.lock()
        let peakLevel = storedPeakLevelSinceStart
        lock.unlock()
        return peakLevel
    }

    private let lock = NSLock()
    private let samples: [Float]
    private let permissionError: Error?
    private let startLevels: AudioLevelStats
    private let startPeakLevelSinceStart: Double
    private var storedLatestLevels: AudioLevelStats = .empty
    private var storedPeakLevelSinceStart: Double = 0
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
         latestLevels: AudioLevelStats = AudioLevelStats(rmsLevel: 0.0084,
                                                         peakLevel: 0.04,
                                                         clippingRatio: 0),
         peakLevelSinceStart: Double? = nil,
         captureFailure: AudioMeterError? = nil,
         permissionError: Error? = nil) {
        self.samples = samples
        self.actualSampleRate = sampleRate
        self.routeDescription = routeDescription
        self.routeWarning = routeWarning
        self.startLevels = latestLevels
        self.startPeakLevelSinceStart = peakLevelSinceStart ?? latestLevels.peakLevel
        self.captureFailure = captureFailure
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
        lock.lock()
        storedLatestLevels = startLevels
        storedPeakLevelSinceStart = startPeakLevelSinceStart
        lock.unlock()
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

final class AudioCaptureRouteChangePolicyTests: XCTestCase {
    private let builtInBottomMic = AudioInputRouteIdentity(portUID: "built-in-mic",
                                                           portType: "MicrophoneBuiltIn")

    func testBenignRouteNotificationIsIgnoredWhenInputIsUnchanged() {
        let shouldFail = AudioCaptureRouteChangePolicy.shouldFailCapture(
            expectedRoute: builtInBottomMic,
            currentRoute: builtInBottomMic,
            engineIsRunning: false,
            event: .route
        )

        XCTAssertFalse(shouldFail)
    }

    func testBenignEngineNotificationIsIgnoredWhileCaptureIsRunning() {
        let shouldFail = AudioCaptureRouteChangePolicy.shouldFailCapture(
            expectedRoute: builtInBottomMic,
            currentRoute: builtInBottomMic,
            engineIsRunning: true,
            event: .engineConfiguration
        )

        XCTAssertFalse(shouldFail)
    }

    func testChangedMicrophoneInputFailsCapture() {
        let changedRoute = AudioInputRouteIdentity(portUID: "wired-headset",
                                                   portType: "MicrophoneWired")

        let shouldFail = AudioCaptureRouteChangePolicy.shouldFailCapture(
            expectedRoute: builtInBottomMic,
            currentRoute: changedRoute,
            engineIsRunning: true,
            event: .route
        )

        XCTAssertTrue(shouldFail)
    }

    func testStoppedEngineOrMissingInputFailsCapture() {
        XCTAssertTrue(AudioCaptureRouteChangePolicy.shouldFailCapture(
            expectedRoute: builtInBottomMic,
            currentRoute: builtInBottomMic,
            engineIsRunning: false,
            event: .engineConfiguration
        ))
        XCTAssertTrue(AudioCaptureRouteChangePolicy.shouldFailCapture(
            expectedRoute: builtInBottomMic,
            currentRoute: nil,
            engineIsRunning: true,
            event: .route
        ))
    }
}

final class DomainModelTests: XCTestCase {
    func testBeatRateCasesExposeExpectedLabelsAndIds() {
        XCTAssertEqual(BeatRate.allCases.map(\.rawValue),
                       [18_000, 19_800, 21_600, 25_200, 28_800, 36_000])
        XCTAssertEqual(BeatRate.bph28800.label, "28800 bph")
        XCTAssertEqual(BeatRate.bph28800.id, 28_800)
    }

    func testBeatRateSelectionIncludesAutoOptionFirst() {
        XCTAssertEqual(BeatRateSelection.allCases.first, .auto)
        XCTAssertEqual(BeatRateSelection.auto.label, "Auto BPH")
        XCTAssertTrue(BeatRateSelection.allCases.contains(.manual(.bph28800)))
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
                               isAutoBPH: false,
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
                               spectralPeriodicityScore: 0,
                               alternatingSpectralPeriodicityScore: 0,
                               alternatingSpectralConsensus: 0,
                               recognitionConfidence: quality == .high ? 1 : 0,
                               tickRecallEstimate: quality == .high ? 1 : 0,
                               analysisWindowCount: quality == .high ? 10 : 0,
                               successfulWindowCount: quality == .high ? 10 : 0,
                               dominantFailureReason: quality == .high ? nil : .unstableGrid,
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
                               isAutoBPH: false,
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
                               spectralPeriodicityScore: 0,
                               alternatingSpectralPeriodicityScore: 0,
                               alternatingSpectralConsensus: 0,
                               recognitionConfidence: 1,
                               tickRecallEstimate: 1,
                               analysisWindowCount: 10,
                               successfulWindowCount: 10,
                               dominantFailureReason: nil,
                               detectionThreshold: 0.01,
                               envelopeMedian: 0.001,
                               envelopeP95: 0.01,
                               sampleRate: 48_000,
                               sampleCount: 2_880_000,
                               routeDescription: "Synthetic",
                               routeWarning: nil)
    }
}
