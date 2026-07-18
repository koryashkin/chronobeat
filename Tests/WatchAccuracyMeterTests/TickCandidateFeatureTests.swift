import XCTest
@testable import WatchAccuracyMeter

final class TickCandidateFeatureTests: XCTestCase {
    func testFeatureVectorMatchesVersionedSchemaAndContainsOnlyFiniteValues() {
        var samples = Array(repeating: Float.zero, count: 4_096)
        samples[2_048] = 0.2
        samples[2_049] = -0.1

        let features = TickCandidateFeatureSchema.extract(samples: samples,
                                                          sampleRate: 48_000,
                                                          centerIndex: 2_048,
                                                          normalizedEnvelope: 3.5)

        XCTAssertEqual(TickCandidateFeatureSchema.version, 1)
        XCTAssertEqual(features.values.count, TickCandidateFeatureSchema.featureNames.count)
        XCTAssertTrue(features.values.allSatisfy(\.isFinite))
        XCTAssertEqual(features[0], 3.5)
        XCTAssertGreaterThan(features[5], 0.95)
    }

    func testNormalizedShapeFeaturesAreInvariantToCaptureGain() {
        let center = 2_048
        var louder = Array(repeating: Float.zero, count: 4_096)
        for offset in -80...160 {
            let time = Double(offset) / 48_000
            let decay = exp(-abs(Double(offset)) / 45)
            louder[center + offset] = Float(0.2 * decay * sin(2 * .pi * 8_500 * time))
        }
        let quieter = louder.map { $0 * 0.1 }

        let loudFeatures = TickCandidateFeatureSchema.extract(samples: louder,
                                                              sampleRate: 48_000,
                                                              centerIndex: center,
                                                              normalizedEnvelope: 2.0)
        let quietFeatures = TickCandidateFeatureSchema.extract(samples: quieter,
                                                               sampleRate: 48_000,
                                                               centerIndex: center,
                                                               normalizedEnvelope: 2.0)

        XCTAssertEqual(loudFeatures[0], quietFeatures[0], accuracy: 1e-12)
        XCTAssertEqual(loudFeatures[1] - quietFeatures[1], 1, accuracy: 1e-5)
        for index in 2..<loudFeatures.values.count {
            XCTAssertEqual(loudFeatures[index], quietFeatures[index], accuracy: 1e-5,
                           "Gain changed normalized feature \(TickCandidateFeatureSchema.featureNames[index]).")
        }
    }

    func testFeatureExtractionZeroPadsCandidatesAtCaptureBoundaries() {
        var samples = Array(repeating: Float.zero, count: 512)
        samples[0] = 0.4
        samples[1] = -0.2

        let features = TickCandidateFeatureSchema.extract(samples: samples,
                                                          sampleRate: 44_100,
                                                          centerIndex: 0,
                                                          normalizedEnvelope: .infinity)

        XCTAssertEqual(features.values.count, TickCandidateFeatureSchema.featureNames.count)
        XCTAssertTrue(features.values.allSatisfy(\.isFinite))
        XCTAssertEqual(features[0], 0)
        XCTAssertGreaterThan(features[2], 1)
    }

    func testSilenceProducesStableFiniteFeatures() {
        let features = TickCandidateFeatureSchema.extract(samples: [],
                                                          sampleRate: 0,
                                                          centerIndex: 0,
                                                          normalizedEnvelope: 0)

        XCTAssertEqual(features[1], -12, accuracy: 1e-12)
        XCTAssertTrue(features.values.allSatisfy(\.isFinite))
        XCTAssertTrue(features.values.dropFirst(2).allSatisfy { $0 == 0 })
    }
}
