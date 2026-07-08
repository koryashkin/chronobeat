import Foundation

enum BeatRate: Int, CaseIterable, Identifiable {
    case bph18000 = 18_000
    case bph19800 = 19_800
    case bph21600 = 21_600
    case bph25200 = 25_200
    case bph28800 = 28_800
    case bph36000 = 36_000

    var id: Int { rawValue }
    var label: String { "\(rawValue) bph" }
}

enum MeasurementState {
    case idle
    case requestingPermission
    case measuring
    case analyzing
    case result(WatchMeasurementResult)
    case failed(String)
}

enum SignalQuality: String {
    case high
    case medium
    case low

    var label: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }
}

struct WatchMeasurementResult {
    let selectedBPH: Int
    let detectedBPH: Double
    let rateSecondsPerDay: Double
    let qualityScore: Double
    let quality: SignalQuality
    let validPeakCount: Int
    let outlierRatio: Double

    var rateText: String {
        let rounded = Int(rateSecondsPerDay.rounded())
        if rounded > 0 { return "+\(rounded) sec/day" }
        return "\(rounded) sec/day"
    }

    var interpretation: String {
        switch quality {
        case .high:
            if abs(rateSecondsPerDay) <= 10 {
                return "This looks reasonably stable for a phone-based measurement. Repeat once to confirm."
            } else {
                return "The watch appears to be running noticeably \(rateSecondsPerDay > 0 ? "fast" : "slow"). Repeat once to confirm."
            }
        case .medium:
            return "Approximate result. Try another measurement in a quieter room to confirm."
        case .low:
            return "Measurement quality is low. Move the watch closer to the microphone and try again."
        }
    }
}

enum WatchDSP {
    static func analyze(samples: [Float], sampleRate: Double, selectedBPH: Int) -> WatchMeasurementResult {
        guard samples.count > Int(sampleRate * 10) else {
            return fallback(selectedBPH: selectedBPH, reasonScore: 0)
        }

        let processed = preprocess(samples)
        let expectedPeriod = 3600.0 / Double(selectedBPH)
        let envelope = makeEnvelope(processed, sampleRate: sampleRate)
        let peaks = detectPeaks(envelope: envelope, sampleRate: sampleRate, expectedPeriod: expectedPeriod)
        let fit = robustFit(peaks: peaks, selectedBPH: selectedBPH)

        guard let fit else {
            return fallback(selectedBPH: selectedBPH, reasonScore: 10)
        }

        let detectedBPH = 3600.0 / fit.period
        let rate = (detectedBPH / Double(selectedBPH) - 1.0) * 86_400.0
        let qualityScore = qualityScore(validPeaks: fit.validCount,
                                        outlierRatio: fit.outlierRatio,
                                        windowRates: fit.windowRates)
        let quality: SignalQuality
        if qualityScore >= 80 {
            quality = .high
        } else if qualityScore >= 50 {
            quality = .medium
        } else {
            quality = .low
        }

        return WatchMeasurementResult(selectedBPH: selectedBPH,
                                      detectedBPH: detectedBPH,
                                      rateSecondsPerDay: rate,
                                      qualityScore: qualityScore,
                                      quality: quality,
                                      validPeakCount: fit.validCount,
                                      outlierRatio: fit.outlierRatio)
    }

    private static func fallback(selectedBPH: Int, reasonScore: Double) -> WatchMeasurementResult {
        WatchMeasurementResult(selectedBPH: selectedBPH,
                               detectedBPH: Double(selectedBPH),
                               rateSecondsPerDay: 0,
                               qualityScore: reasonScore,
                               quality: .low,
                               validPeakCount: 0,
                               outlierRatio: 1)
    }

    private static func preprocess(_ input: [Float]) -> [Float] {
        guard !input.isEmpty else { return [] }

        let mean = input.reduce(Float(0), +) / Float(input.count)
        var output = [Float]()
        output.reserveCapacity(input.count)

        // Simple DC removal plus first-order high-pass-like differencing.
        var previous: Float = input[0] - mean
        var hp: Float = 0
        let alpha: Float = 0.995

        for raw in input {
            let x = raw - mean
            hp = alpha * (hp + x - previous)
            previous = x
            output.append(hp)
        }
        return output
    }

    private static func makeEnvelope(_ input: [Float], sampleRate: Double) -> [Float] {
        guard !input.isEmpty else { return [] }

        // Absolute value envelope with short smoothing window.
        let window = max(4, Int(sampleRate * 0.0015)) // ~1.5 ms
        var absSignal = input.map { abs($0) }
        var envelope = Array(repeating: Float(0), count: absSignal.count)

        var sum: Float = 0
        for i in 0..<absSignal.count {
            sum += absSignal[i]
            if i >= window { sum -= absSignal[i - window] }
            envelope[i] = sum / Float(min(i + 1, window))
        }
        absSignal.removeAll()
        return envelope
    }

    private static func detectPeaks(envelope: [Float], sampleRate: Double, expectedPeriod: Double) -> [Double] {
        guard envelope.count > 3 else { return [] }

        let sortedSample = envelope.strideSample(maxCount: 20_000).sorted()
        let median = sortedSample[sortedSample.count / 2]
        let p95 = sortedSample[Int(Double(sortedSample.count - 1) * 0.95)]
        let threshold = median + max((p95 - median) * 0.35, 0.0005)

        let minDistance = Int(sampleRate * expectedPeriod * 0.45)
        var peaks: [Double] = []
        var lastPeakIndex = -minDistance

        var i = 1
        while i < envelope.count - 1 {
            let value = envelope[i]
            if value > threshold,
               value >= envelope[i - 1],
               value > envelope[i + 1],
               i - lastPeakIndex >= minDistance {

                // Local refinement: choose max in a small neighborhood.
                let radius = max(2, Int(sampleRate * 0.002))
                let start = max(1, i - radius)
                let end = min(envelope.count - 2, i + radius)
                var bestIndex = i
                var bestValue = value
                for j in start...end where envelope[j] > bestValue {
                    bestValue = envelope[j]
                    bestIndex = j
                }

                peaks.append(Double(bestIndex) / sampleRate)
                lastPeakIndex = bestIndex
                i = bestIndex + minDistance
            } else {
                i += 1
            }
        }

        return peaks
    }

    private struct FitResult {
        let period: Double
        let validCount: Int
        let outlierRatio: Double
        let windowRates: [Double]
    }

    private static func robustFit(peaks: [Double], selectedBPH: Int) -> FitResult? {
        guard peaks.count > 50 else { return nil }

        let expectedPeriod = 3600.0 / Double(selectedBPH)
        let first = peaks[0]

        // Assign beat indices using expected period. This is simple but effective for MVP.
        var pairs: [(n: Double, t: Double)] = []
        pairs.reserveCapacity(peaks.count)

        var usedIndices = Set<Int>()
        for t in peaks {
            let n = Int(round((t - first) / expectedPeriod))
            guard n >= 0, !usedIndices.contains(n) else { continue }
            usedIndices.insert(n)
            pairs.append((Double(n), t))
        }

        guard pairs.count > 50 else { return nil }

        var slope = linearRegressionSlope(pairs: pairs) ?? expectedPeriod
        var intercept = first

        for _ in 0..<3 {
            var residuals = pairs.map { abs($0.t - (intercept + slope * $0.n)) }
            residuals.sort()
            let medianResidual = residuals[residuals.count / 2]
            let threshold = max(medianResidual * 4, expectedPeriod * 0.12)

            let filtered = pairs.filter { abs($0.t - (intercept + slope * $0.n)) <= threshold }
            guard filtered.count > 50 else { break }
            pairs = filtered

            if let newSlope = linearRegressionSlope(pairs: pairs),
               let newIntercept = linearRegressionIntercept(pairs: pairs, slope: newSlope) {
                slope = newSlope
                intercept = newIntercept
            }
        }

        let outlierRatio = 1.0 - Double(pairs.count) / Double(peaks.count)
        let windowRates = windowRateEstimates(pairs: pairs, selectedBPH: selectedBPH)

        guard slope > 0 else { return nil }
        return FitResult(period: slope,
                         validCount: pairs.count,
                         outlierRatio: max(0, min(1, outlierRatio)),
                         windowRates: windowRates)
    }

    private static func linearRegressionSlope(pairs: [(n: Double, t: Double)]) -> Double? {
        guard pairs.count > 1 else { return nil }
        let meanN = pairs.map(\.n).reduce(0, +) / Double(pairs.count)
        let meanT = pairs.map(\.t).reduce(0, +) / Double(pairs.count)
        var numerator = 0.0
        var denominator = 0.0
        for p in pairs {
            numerator += (p.n - meanN) * (p.t - meanT)
            denominator += (p.n - meanN) * (p.n - meanN)
        }
        guard denominator > 0 else { return nil }
        return numerator / denominator
    }

    private static func linearRegressionIntercept(pairs: [(n: Double, t: Double)], slope: Double) -> Double? {
        guard !pairs.isEmpty else { return nil }
        let meanN = pairs.map(\.n).reduce(0, +) / Double(pairs.count)
        let meanT = pairs.map(\.t).reduce(0, +) / Double(pairs.count)
        return meanT - slope * meanN
    }

    private static func windowRateEstimates(pairs: [(n: Double, t: Double)], selectedBPH: Int) -> [Double] {
        guard pairs.count > 100 else { return [] }
        let windowSize = 80
        let step = 40
        var rates: [Double] = []
        var start = 0

        while start + windowSize < pairs.count {
            let window = Array(pairs[start..<(start + windowSize)])
            if let slope = linearRegressionSlope(pairs: window), slope > 0 {
                let detectedBPH = 3600.0 / slope
                let rate = (detectedBPH / Double(selectedBPH) - 1.0) * 86_400.0
                rates.append(rate)
            }
            start += step
        }
        return rates
    }

    private static func qualityScore(validPeaks: Int, outlierRatio: Double, windowRates: [Double]) -> Double {
        let peakScore = min(100, Double(validPeaks) / 350.0 * 100.0)
        let outlierScore = max(0, 100.0 - outlierRatio * 300.0)

        let stabilityScore: Double
        if windowRates.count >= 3 {
            let mean = windowRates.reduce(0, +) / Double(windowRates.count)
            let variance = windowRates.map { pow($0 - mean, 2) }.reduce(0, +) / Double(windowRates.count)
            let stdev = sqrt(variance)
            stabilityScore = max(0, 100.0 - stdev * 8.0)
        } else {
            stabilityScore = 40
        }

        return max(0, min(100, peakScore * 0.35 + outlierScore * 0.30 + stabilityScore * 0.35))
    }
}

private extension Array where Element == Float {
    func strideSample(maxCount: Int) -> [Float] {
        guard count > maxCount else { return self }
        let strideBy = max(1, count / maxCount)
        var result: [Float] = []
        result.reserveCapacity(maxCount)
        var index = 0
        while index < count {
            result.append(self[index])
            index += strideBy
        }
        return result
    }
}
