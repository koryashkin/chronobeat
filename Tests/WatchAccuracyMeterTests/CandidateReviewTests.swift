import XCTest
@testable import WatchAccuracyMeter

final class CandidateReviewTests: XCTestCase {
    func testReviewSelectionBalancesProvisionalClassesAndKeepsTimeOrder() {
        let events = makeEvents(count: 12, label: .likelyTick, offset: 0)
            + makeEvents(count: 12, label: .likelyNoise, offset: 100)
            + makeEvents(count: 12, label: .unknown, offset: 200)

        let selected = CandidateReviewSampler.selectEvents(events, maximumCount: 15)

        XCTAssertEqual(selected.count, 15)
        XCTAssertEqual(selected.filter { $0.provisionalLabel == .likelyTick }.count, 5)
        XCTAssertEqual(selected.filter { $0.provisionalLabel == .likelyNoise }.count, 5)
        XCTAssertEqual(selected.filter { $0.provisionalLabel == .unknown }.count, 5)
        XCTAssertEqual(selected.map(\.sampleIndex), selected.map(\.sampleIndex).sorted())
    }

    func testReviewSelectionRedistributesQuotaWhenOnlyUnknownEventsExist() {
        let events = makeEvents(count: 40, label: .unknown, offset: 0)

        let selected = CandidateReviewSampler.selectEvents(events, maximumCount: 17)

        XCTAssertEqual(selected.count, 17)
        XCTAssertTrue(selected.allSatisfy { $0.provisionalLabel == .unknown })
        XCTAssertEqual(Set(selected.map(\.sampleIndex)).count, selected.count)
    }

    func testReviewSelectionIsDeterministic() {
        let events = makeEvents(count: 80, label: .likelyTick, offset: 0)
            + makeEvents(count: 80, label: .likelyNoise, offset: 100)

        let first = CandidateReviewSampler.selectEvents(events, maximumCount: 31)
        let second = CandidateReviewSampler.selectEvents(Array(events.reversed()), maximumCount: 31)

        XCTAssertEqual(first.map(\.sampleIndex), second.map(\.sampleIndex))
    }

    func testWaveformPreviewIsBoundedAndZeroPadsCaptureEdge() {
        var samples = Array(repeating: Float.zero, count: 512)
        samples[0] = 0.25
        samples[1] = -0.5

        let preview = CandidateReviewSampler.preview(samples: samples,
                                                     sampleRate: 44_100,
                                                     centerIndex: 0)

        XCTAssertEqual(preview.waveform.count, CandidateReviewSampler.waveformPointCount)
        XCTAssertGreaterThan(preview.localPeak, 0.4)
        XCTAssertLessThanOrEqual(preview.localPeak, 0.5)
        XCTAssertTrue(preview.waveform.allSatisfy { $0.isFinite && abs($0) <= 1 })
        XCTAssertTrue(preview.waveform.contains { abs($0) > 0.9 })
    }

    private func makeEvents(
        count: Int,
        label: TickCandidateProvisionalLabel,
        offset: Int
    ) -> [TickCandidateEvent] {
        (0..<count).map { index in
            let sampleIndex = (offset + index) * 1_000
            return TickCandidateEvent(sampleIndex: sampleIndex,
                                      timeSeconds: Double(sampleIndex) / 48_000,
                                      normalizedEnvelope: Double((index % 7) + 1),
                                      nearestAssignedDistanceSeconds: nil,
                                      provisionalLabel: label)
        }
    }
}
