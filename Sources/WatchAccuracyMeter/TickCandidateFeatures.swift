import Foundation

struct TickCandidateFeatureVector: Equatable, Sendable {
    let values: [Double]

    subscript(index: Int) -> Double {
        values[index]
    }
}

enum TickCandidateFeatureSchema {
    static let version = 1
    static let targetSampleRate = 48_000.0
    static let snippetFrameCount = 2_048
    static let snippetCenterOffset = snippetFrameCount / 2
    static let temporalBinCount = 32

    static let featureNames: [String] = {
        let scalarNames = [
            "candidateEnvelope",
            "logRMS",
            "crestFactor",
            "zeroCrossingRate",
            "normalizedDerivativeRMS",
            "centerEnergyRatio",
            "prePostEnergyBalance"
        ]
        let envelopeNames = (0..<temporalBinCount).map {
            String(format: "envelopeBin%02d", $0)
        }
        let derivativeNames = (0..<temporalBinCount).map {
            String(format: "derivativeBin%02d", $0)
        }
        return scalarNames + envelopeNames + derivativeNames
    }()

    static func extract(
        samples: [Float],
        sampleRate: Double,
        centerIndex: Int,
        normalizedEnvelope: Double
    ) -> TickCandidateFeatureVector {
        let snippet = fixedRateSnippet(samples: samples,
                                       sampleRate: sampleRate,
                                       centerIndex: centerIndex)
        let mean = snippet.reduce(0, +) / Double(snippet.count)
        let centered = snippet.map { $0 - mean }
        let energy = centered.reduce(0) { $0 + $1 * $1 }
        let rms = sqrt(energy / Double(centered.count))
        let scale = max(rms, 1e-12)
        let peak = centered.map(abs).max() ?? 0

        var derivative = Array(repeating: 0.0, count: centered.count)
        if centered.count > 1 {
            for index in 1..<centered.count {
                derivative[index] = centered[index] - centered[index - 1]
            }
        }
        let derivativeEnergy = derivative.reduce(0) { $0 + $1 * $1 }
        let derivativeRMS = sqrt(derivativeEnergy / Double(derivative.count))

        var zeroCrossingCount = 0
        if centered.count > 1 {
            for index in 1..<centered.count {
                let previous = centered[index - 1]
                let current = centered[index]
                if (previous < 0 && current >= 0) || (previous >= 0 && current < 0) {
                    zeroCrossingCount += 1
                }
            }
        }

        let centerRadius = 128
        let centerStart = max(0, snippetCenterOffset - centerRadius)
        let centerEnd = min(centered.count, snippetCenterOffset + centerRadius)
        let centerEnergy = centered[centerStart..<centerEnd].reduce(0) { $0 + $1 * $1 }
        let preEnergy = centered[..<snippetCenterOffset].reduce(0) { $0 + $1 * $1 }
        let postEnergy = centered[snippetCenterOffset...].reduce(0) { $0 + $1 * $1 }
        let safeEnergy = max(energy, 1e-24)

        var values = [
            normalizedEnvelope.isFinite ? normalizedEnvelope : 0,
            log10(scale),
            peak / scale,
            Double(zeroCrossingCount) / Double(max(1, centered.count - 1)),
            derivativeRMS / scale,
            centerEnergy / safeEnergy,
            (postEnergy - preEnergy) / safeEnergy
        ]

        let binSize = snippetFrameCount / temporalBinCount
        for bin in 0..<temporalBinCount {
            let start = bin * binSize
            let end = start + binSize
            let meanAbsolute = centered[start..<end].reduce(0) { $0 + abs($1) }
                / Double(binSize)
            values.append(meanAbsolute / scale)
        }
        for bin in 0..<temporalBinCount {
            let start = bin * binSize
            let end = start + binSize
            let binEnergy = derivative[start..<end].reduce(0) { $0 + $1 * $1 }
            values.append(sqrt(binEnergy / Double(binSize)) / scale)
        }

        precondition(values.count == featureNames.count)
        return TickCandidateFeatureVector(values: values.map { $0.isFinite ? $0 : 0 })
    }

    private static func fixedRateSnippet(
        samples: [Float],
        sampleRate: Double,
        centerIndex: Int
    ) -> [Double] {
        guard !samples.isEmpty, sampleRate.isFinite, sampleRate > 0 else {
            return Array(repeating: 0, count: snippetFrameCount)
        }

        return (0..<snippetFrameCount).map { outputIndex in
            let targetOffset = Double(outputIndex - snippetCenterOffset)
                / targetSampleRate
            let sourcePosition = Double(centerIndex) + targetOffset * sampleRate
            guard sourcePosition >= 0,
                  sourcePosition <= Double(samples.count - 1) else {
                return 0
            }

            let lowerIndex = Int(sourcePosition.rounded(.down))
            let upperIndex = min(samples.count - 1, lowerIndex + 1)
            let fraction = sourcePosition - Double(lowerIndex)
            let lower = Double(samples[lowerIndex])
            let upper = Double(samples[upperIndex])
            return lower + (upper - lower) * fraction
        }
    }
}
