import Foundation

struct CandidateReviewPreview: Equatable, Sendable {
    let localPeak: Double
    let waveform: [Double]
}

enum CandidateReviewSampler {
    static let waveformPointCount = 128

    static func selectEvents(
        _ events: [TickCandidateEvent],
        maximumCount: Int
    ) -> [TickCandidateEvent] {
        guard maximumCount > 0, !events.isEmpty else { return [] }
        guard events.count > maximumCount else {
            return events.sorted { $0.sampleIndex < $1.sampleIndex }
        }

        let labelOrder: [TickCandidateProvisionalLabel] = [
            .likelyTick,
            .likelyNoise,
            .unknown
        ]
        let grouped = Dictionary(grouping: events, by: \.provisionalLabel)
        var targets = Dictionary(uniqueKeysWithValues: labelOrder.map { ($0, 0) })
        var remaining = maximumCount

        while remaining > 0 {
            var allocated = false
            for label in labelOrder where remaining > 0 {
                let availableCount = grouped[label]?.count ?? 0
                let currentTarget = targets[label] ?? 0
                guard currentTarget < availableCount else { continue }
                targets[label] = currentTarget + 1
                remaining -= 1
                allocated = true
            }
            if !allocated { break }
        }

        let selected = labelOrder.flatMap { label in
            diverseSample(grouped[label] ?? [], limit: targets[label] ?? 0)
        }
        return selected.sorted { $0.sampleIndex < $1.sampleIndex }
    }

    static func preview(
        samples: [Float],
        sampleRate: Double,
        centerIndex: Int
    ) -> CandidateReviewPreview {
        let snippet = TickCandidateFeatureSchema.fixedRateSnippet(
            samples: samples,
            sampleRate: sampleRate,
            centerIndex: centerIndex
        )
        let localPeak = snippet.map(abs).max() ?? 0
        let scale = max(localPeak, 1e-12)
        let binSize = max(1, snippet.count / waveformPointCount)
        var waveform: [Double] = []
        waveform.reserveCapacity(waveformPointCount)

        for bin in 0..<waveformPointCount {
            let start = min(snippet.count, bin * binSize)
            let end = min(snippet.count, start + binSize)
            guard start < end else {
                waveform.append(0)
                continue
            }
            let strongest = snippet[start..<end].max { abs($0) < abs($1) } ?? 0
            waveform.append(strongest / scale)
        }

        return CandidateReviewPreview(localPeak: localPeak,
                                      waveform: waveform.map { $0.isFinite ? $0 : 0 })
    }

    private static func diverseSample(
        _ events: [TickCandidateEvent],
        limit: Int
    ) -> [TickCandidateEvent] {
        guard limit > 0 else { return [] }
        guard events.count > limit else {
            return events.sorted { $0.sampleIndex < $1.sampleIndex }
        }

        let ordered = events.sorted { $0.sampleIndex < $1.sampleIndex }
        let coverageCount = max(1, limit / 2)
        var selectedIndices = Set<Int>()
        var selected: [TickCandidateEvent] = []
        selected.reserveCapacity(limit)

        for bucket in 0..<coverageCount {
            let start = bucket * ordered.count / coverageCount
            let end = max(start + 1, (bucket + 1) * ordered.count / coverageCount)
            guard start < ordered.count else { continue }
            let strongest = ordered[start..<min(end, ordered.count)].max { lhs, rhs in
                if lhs.normalizedEnvelope != rhs.normalizedEnvelope {
                    return lhs.normalizedEnvelope < rhs.normalizedEnvelope
                }
                return lhs.sampleIndex > rhs.sampleIndex
            }
            if let strongest, selectedIndices.insert(strongest.sampleIndex).inserted {
                selected.append(strongest)
            }
        }

        if selected.count < limit {
            let strongestRemaining = ordered
                .filter { !selectedIndices.contains($0.sampleIndex) }
                .sorted { lhs, rhs in
                    if lhs.normalizedEnvelope != rhs.normalizedEnvelope {
                        return lhs.normalizedEnvelope > rhs.normalizedEnvelope
                    }
                    return lhs.sampleIndex < rhs.sampleIndex
                }
            selected.append(contentsOf: strongestRemaining.prefix(limit - selected.count))
        }

        return selected.sorted { $0.sampleIndex < $1.sampleIndex }
    }
}
