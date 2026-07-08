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

    private func makeSyntheticWatchSamples(
        rateSecondsPerDay: Double,
        duration: Double = 60,
        amplitudeScale: Float = 1,
        skipBeat: (Int) -> Bool = { _ in false }
    ) -> [Float] {
        let sampleCount = Int(duration * sampleRate)
        var samples = Array(repeating: Float(0), count: sampleCount)
        let detectedBPH = Double(selectedBPH) * (1 + rateSecondsPerDay / 86_400)
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
