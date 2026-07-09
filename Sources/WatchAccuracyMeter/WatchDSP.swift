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

enum BeatRateSelection: Hashable, Identifiable, CaseIterable {
    case auto
    case manual(BeatRate)

    static var allCases: [BeatRateSelection] {
        [.auto] + BeatRate.allCases.map { .manual($0) }
    }

    var id: String {
        switch self {
        case .auto:
            return "auto"
        case .manual(let beatRate):
            return "\(beatRate.rawValue)"
        }
    }

    var label: String {
        switch self {
        case .auto:
            return "Auto BPH"
        case .manual(let beatRate):
            return beatRate.label
        }
    }
}

enum MeasurementState {
    case idle
    case requestingPermission
    case measuring
    case analyzing
    case result(WatchMeasurementResult)
    case failed(String)
}

extension MeasurementState {
    var canEditBeatRate: Bool {
        if case .idle = self { return true }
        return false
    }

    var isMeasuring: Bool {
        if case .measuring = self { return true }
        return false
    }

    var requiresForegroundAudioSession: Bool {
        switch self {
        case .requestingPermission, .measuring:
            return true
        case .idle, .analyzing, .result, .failed:
            return false
        }
    }
}

enum SignalQuality: String, Equatable {
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
    let isAutoBPH: Bool
    let detectedBPH: Double
    let rateSecondsPerDay: Double
    let qualityScore: Double
    let quality: SignalQuality
    let detectedPeakCount: Int
    let validPeakCount: Int
    let expectedTickCount: Int
    let beatCoverage: Double
    let outlierRatio: Double
    let chosenThresholdScale: Double
    let rmsLevel: Double
    let peakLevel: Double
    let clippingRatio: Double
    let estimatedSnrDb: Double
    let periodicityScore: Double
    let recognitionConfidence: Double
    let tickRecallEstimate: Double
    let analysisWindowCount: Int
    let successfulWindowCount: Int
    let dominantFailureReason: RecognitionIssue?
    let detectionThreshold: Double
    let envelopeMedian: Double
    let envelopeP95: Double
    let sampleRate: Double
    let sampleCount: Int
    let routeDescription: String
    let routeWarning: String?

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
            if dominantFailureReason == .unsupportedRoute {
                return "The current input route is not ideal. Use the built-in iPhone microphone for best results."
            }
            if dominantFailureReason == .clipping || clippingRatio > 0.001 {
                return "Audio is clipping. Move the watch slightly farther from the microphone and try again."
            }
            if dominantFailureReason == .tooQuiet || peakLevel < 0.002 {
                return "The tick signal is too quiet. Put the watch caseback directly against the bottom microphone and try again."
            }
            if detectedPeakCount == 0 {
                return "No tick candidates were detected. Put the watch caseback directly against the bottom microphone and try again."
            }
            if dominantFailureReason == .tooNoisy || estimatedSnrDb < 3 {
                return "Background noise is masking the ticks. Use a quieter room and keep the phone still."
            }
            if dominantFailureReason == .wrongBPHLikely {
                return "Ticks were detected, but they do not match the selected beat rate. Check the BPH setting and try again."
            }
            if dominantFailureReason == .ambiguousBeatRate {
                return "Ticks were detected, but the beat rate is ambiguous. Try another measurement with the watch closer to the microphone."
            }
            if dominantFailureReason == .unstableGrid || periodicityScore < 0.50 {
                return "Tick candidates were detected, but the beat pattern is unstable. Keep the watch still and try again."
            }
            return "Tick candidates were detected, but they did not form a stable beat grid. Keep the watch still and try again."
        }
    }
}

enum WatchDSP {
    static func analyzeAuto(capture: AudioCapture) -> WatchMeasurementResult {
        analyzeAuto(samples: capture.samples,
                    sampleRate: capture.sampleRate,
                    routeDescription: capture.routeDescription,
                    routeWarning: capture.routeWarning)
    }

    static func analyzeAuto(
        samples: [Float],
        sampleRate: Double,
        routeDescription: String = "Unknown",
        routeWarning: String? = nil
    ) -> WatchMeasurementResult {
        let candidates = BeatRate.allCases.map { beatRate in
            analyze(samples: samples,
                    sampleRate: sampleRate,
                    selectedBPH: beatRate.rawValue,
                    routeDescription: routeDescription,
                    routeWarning: routeWarning,
                    checksCompetingBeatRates: false,
                    isAutoBPH: true)
        }
        let sortedCandidates = candidates.sorted { lhs, rhs in
            autoBeatRateScore(lhs) > autoBeatRateScore(rhs)
        }

        guard let best = sortedCandidates.first else {
            return fallback(selectedBPH: BeatRate.bph28800.rawValue,
                            reasonScore: 0,
                            detectionStats: .empty,
                            audioStats: AudioLevelStats.measure(samples),
                            expectedTickCount: 0,
                            sampleRate: sampleRate,
                            sampleCount: samples.count,
                            routeDescription: routeDescription,
                            routeWarning: routeWarning,
                            isAutoBPH: true)
        }

        let bestScore = autoBeatRateScore(best)
        let secondScore = sortedCandidates.dropFirst().first.map(autoBeatRateScore) ?? 0
        let margin = bestScore - secondScore
        let isAmbiguous = best.quality == .low
            || bestScore < 0.58
            || margin < 0.06
            || best.outlierRatio > 0.60
            || best.periodicityScore < 0.50

        if isAmbiguous {
            return replacing(result: best,
                             quality: .low,
                             qualityScore: min(best.qualityScore, 49),
                             recognitionConfidence: min(best.recognitionConfidence, 0.49),
                             dominantFailureReason: .ambiguousBeatRate,
                             isAutoBPH: true)
        }

        return replacing(result: best, isAutoBPH: true)
    }

    static func analyze(
        capture: AudioCapture,
        selectedBPH: Int
    ) -> WatchMeasurementResult {
        analyze(samples: capture.samples,
                sampleRate: capture.sampleRate,
                selectedBPH: selectedBPH,
                routeDescription: capture.routeDescription,
                routeWarning: capture.routeWarning)
    }

    static func analyze(
        samples: [Float],
        sampleRate: Double,
        selectedBPH: Int,
        routeDescription: String = "Unknown",
        routeWarning: String? = nil,
        checksCompetingBeatRates: Bool = true,
        isAutoBPH: Bool = false
    ) -> WatchMeasurementResult {
        let expectedPeriod = 3600.0 / Double(selectedBPH)
        let expectedTickCount = expectedTickCount(sampleCount: samples.count,
                                                  sampleRate: sampleRate,
                                                  expectedPeriod: expectedPeriod)
        let audioStats = AudioLevelStats.measure(samples)

        guard samples.count > Int(sampleRate * 10) else {
            return fallback(selectedBPH: selectedBPH,
                            reasonScore: 0,
                            detectionStats: .empty,
                            audioStats: audioStats,
                            expectedTickCount: expectedTickCount,
                            sampleRate: sampleRate,
                            sampleCount: samples.count,
                            routeDescription: routeDescription,
                            routeWarning: routeWarning,
                            isAutoBPH: isAutoBPH)
        }

        let processed = preprocess(samples, sampleRate: sampleRate)
        let envelope = normalizeEnvelope(makeEnvelope(processed, sampleRate: sampleRate),
                                          sampleRate: sampleRate)
        let selectedDetection = bestDetection(envelope: envelope,
                                              sampleRate: sampleRate,
                                              selectedBPH: selectedBPH,
                                              expectedPeriod: expectedPeriod,
                                              expectedTickCount: expectedTickCount)

        guard let selectedDetection else {
            let detection = fallbackDetection(envelope: envelope,
                                              sampleRate: sampleRate,
                                              expectedPeriod: expectedPeriod)
            return fallback(selectedBPH: selectedBPH,
                            reasonScore: 10,
                            detectionStats: detection.stats,
                            audioStats: audioStats,
                            expectedTickCount: expectedTickCount,
                            sampleRate: sampleRate,
                            sampleCount: samples.count,
                            routeDescription: routeDescription,
                            routeWarning: routeWarning,
                            isAutoBPH: isAutoBPH)
        }

        let detection = selectedDetection.detection
        let fit = selectedDetection.fit
        let detectedBPH = 3600.0 / fit.period
        let rate = (detectedBPH / Double(selectedBPH) - 1.0) * 86_400.0
        var qualityScore = qualityScore(validPeaks: fit.validCount,
                                        candidatePeakCount: detection.stats.candidatePeakCount,
                                        expectedTickCount: expectedTickCount,
                                        beatCoverage: fit.beatCoverage,
                                        outlierRatio: fit.outlierRatio,
                                        windowRates: fit.windowRates,
                                        periodicityScore: selectedDetection.periodicityScore)
        let tickRecallEstimate = tickRecallEstimate(validPeaks: fit.validCount,
                                                    expectedTickCount: expectedTickCount)
        let quality: SignalQuality
        let hasConfidentCoverage = hasConfidentCoverage(beatCoverage: fit.beatCoverage,
                                                        candidatePeakCount: detection.stats.candidatePeakCount,
                                                        validPeakCount: fit.validCount,
                                                        expectedTickCount: expectedTickCount)
        let hasRecoverableRealGrid = fit.validCount >= 100
            && fit.beatCoverage >= 0.70
            && tickRecallEstimate >= 0.70
            && selectedDetection.periodicityScore >= 0.50
            && fit.outlierRatio < 0.70
        if hasRecoverableRealGrid {
            qualityScore = max(qualityScore, 55)
        }

        if qualityScore >= 80, fit.beatCoverage >= 0.80, selectedDetection.periodicityScore >= 0.70 {
            quality = .high
        } else if qualityScore >= 50, hasConfidentCoverage, selectedDetection.periodicityScore >= 0.50 {
            quality = .medium
        } else {
            quality = .low
        }
        let competition = checksCompetingBeatRates
            ? beatRateCompetition(envelope: envelope,
                                  sampleRate: sampleRate,
                                  selectedBPH: selectedBPH,
                                  expectedTickCount: expectedTickCount,
                                  selectedDetection: selectedDetection,
                                  preliminaryQuality: quality)
            : .none(selectedScore: selectedDetection.selectionScore)
        let finalQuality: SignalQuality
        let finalQualityScore: Double
        if competition.isLikelyWrongBeatRate {
            finalQuality = .low
            finalQualityScore = min(qualityScore, 49)
        } else {
            finalQuality = quality
            finalQualityScore = qualityScore
        }
        let recognitionConfidence = recognitionConfidence(qualityScore: qualityScore,
                                                          beatCoverage: fit.beatCoverage,
                                                          tickRecallEstimate: tickRecallEstimate,
                                                          periodicityScore: selectedDetection.periodicityScore)
        let dominantIssue = dominantFailureReason(quality: finalQuality,
                                                  audioStats: audioStats,
                                                  detectionStats: detection.stats,
                                                  fit: fit,
                                                  expectedTickCount: expectedTickCount,
                                                  routeWarning: routeWarning,
                                                  forcedIssue: competition.isLikelyWrongBeatRate ? .wrongBPHLikely : nil)

        return WatchMeasurementResult(selectedBPH: selectedBPH,
                                      isAutoBPH: isAutoBPH,
                                      detectedBPH: detectedBPH,
                                      rateSecondsPerDay: rate,
                                      qualityScore: finalQualityScore,
                                      quality: finalQuality,
                                      detectedPeakCount: detection.stats.candidatePeakCount,
                                      validPeakCount: fit.validCount,
                                      expectedTickCount: expectedTickCount,
                                      beatCoverage: fit.beatCoverage,
                                      outlierRatio: fit.outlierRatio,
                                      chosenThresholdScale: detection.stats.thresholdScale,
                                      rmsLevel: audioStats.rmsLevel,
                                      peakLevel: audioStats.peakLevel,
                                      clippingRatio: audioStats.clippingRatio,
                                      estimatedSnrDb: detection.stats.estimatedSnrDb,
                                      periodicityScore: selectedDetection.periodicityScore,
                                      recognitionConfidence: competition.isLikelyWrongBeatRate ? min(recognitionConfidence, 0.49) : recognitionConfidence,
                                      tickRecallEstimate: tickRecallEstimate,
                                      analysisWindowCount: fit.analysisWindowCount,
                                      successfulWindowCount: fit.successfulWindowCount,
                                      dominantFailureReason: dominantIssue,
                                      detectionThreshold: detection.stats.threshold,
                                      envelopeMedian: detection.stats.envelopeMedian,
                                      envelopeP95: detection.stats.envelopeP95,
                                      sampleRate: sampleRate,
                                      sampleCount: samples.count,
                                      routeDescription: routeDescription,
                                      routeWarning: routeWarning)
    }

    private static func fallback(
        selectedBPH: Int,
        reasonScore: Double,
        detectionStats: PeakDetectionStats,
        audioStats: AudioLevelStats,
        expectedTickCount: Int,
        sampleRate: Double,
        sampleCount: Int,
        routeDescription: String,
        routeWarning: String?,
        isAutoBPH: Bool = false
    ) -> WatchMeasurementResult {
        WatchMeasurementResult(selectedBPH: selectedBPH,
                               isAutoBPH: isAutoBPH,
                               detectedBPH: Double(selectedBPH),
                               rateSecondsPerDay: 0,
                               qualityScore: reasonScore,
                               quality: .low,
                               detectedPeakCount: detectionStats.candidatePeakCount,
                               validPeakCount: 0,
                               expectedTickCount: expectedTickCount,
                               beatCoverage: 0,
                               outlierRatio: 1,
                               chosenThresholdScale: detectionStats.thresholdScale,
                               rmsLevel: audioStats.rmsLevel,
                               peakLevel: audioStats.peakLevel,
                               clippingRatio: audioStats.clippingRatio,
                               estimatedSnrDb: detectionStats.estimatedSnrDb,
                               periodicityScore: 0,
                               recognitionConfidence: 0,
                               tickRecallEstimate: 0,
                               analysisWindowCount: 0,
                               successfulWindowCount: 0,
                               dominantFailureReason: fallbackFailureReason(audioStats: audioStats,
                                                                            detectionStats: detectionStats,
                                                                            routeWarning: routeWarning),
                               detectionThreshold: detectionStats.threshold,
                               envelopeMedian: detectionStats.envelopeMedian,
                               envelopeP95: detectionStats.envelopeP95,
                               sampleRate: sampleRate,
                               sampleCount: sampleCount,
                               routeDescription: routeDescription,
                               routeWarning: routeWarning)
    }

    private static func expectedTickCount(sampleCount: Int, sampleRate: Double, expectedPeriod: Double) -> Int {
        guard sampleRate > 0, expectedPeriod > 0 else { return 0 }
        return max(0, Int((Double(sampleCount) / sampleRate / expectedPeriod).rounded()))
    }

    private static func preprocess(_ input: [Float], sampleRate: Double) -> [Float] {
        guard !input.isEmpty else { return [] }

        let mean = input.reduce(Float(0), +) / Float(input.count)
        var output = [Float]()
        output.reserveCapacity(input.count)

        // DC removal, rumble suppression, and transient emphasis keep handling noise from driving detection.
        var previous: Float = input[0] - mean
        var hp: Float = 0
        var previousHP: Float = 0
        let cutoff = max(40.0, min(180.0, sampleRate / 600.0))
        let dt = 1.0 / sampleRate
        let rc = 1.0 / (2.0 * Double.pi * cutoff)
        let alpha = Float(rc / (rc + dt))

        for raw in input {
            let x = raw - mean
            hp = alpha * (hp + x - previous)
            previous = x
            let derivative = hp - previousHP
            let transient = hp * 0.35 + derivative * 0.90
            previousHP = hp
            output.append(transient)
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

    private static func normalizeEnvelope(_ envelope: [Float], sampleRate: Double) -> [Float] {
        guard !envelope.isEmpty else { return [] }

        let shortNoise = movingAverage(envelope, window: max(16, Int(sampleRate * 0.08)))
        let longNoise = movingAverage(envelope, window: max(16, Int(sampleRate * 0.75)))
        var absoluteDeviation = Array(repeating: Float(0), count: envelope.count)
        for index in envelope.indices {
            absoluteDeviation[index] = abs(envelope[index] - shortNoise[index])
        }
        let localDeviation = movingAverage(absoluteDeviation, window: max(16, Int(sampleRate * 0.12)))
        var normalized = Array(repeating: Float(0), count: envelope.count)

        for index in envelope.indices {
            let floor = max(shortNoise[index] * 0.60 + longNoise[index] * 0.40, 0.000_000_001)
            let lift = max(envelope[index] - floor, 0)
            let deviation = max(localDeviation[index], floor * 0.05, 0.000_000_001)
            let ratio = envelope[index] / floor
            let localLift = 1 + lift / deviation * 0.45
            normalized[index] = max(ratio, localLift)
        }

        return normalized
    }

    private struct PeakDetectionResult {
        let peaks: [Double]
        let stats: PeakDetectionStats
    }

    private struct PeakDetectionStats {
        let candidatePeakCount: Int
        let threshold: Double
        let thresholdScale: Double
        let envelopeMedian: Double
        let envelopeP95: Double
        let estimatedSnrDb: Double

        static let empty = PeakDetectionStats(candidatePeakCount: 0,
                                              threshold: 0,
                                              thresholdScale: 1,
                                              envelopeMedian: 0,
                                              envelopeP95: 0,
                                              estimatedSnrDb: 0)
    }

    private struct SelectedDetection {
        let detection: PeakDetectionResult
        let fit: FitResult
        let periodicityScore: Double
        let selectionScore: Double
    }

    private static let thresholdScales: [Float] = [1.0, 0.85, 0.70, 0.55, 0.40]

    private static func bestDetection(
        envelope: [Float],
        sampleRate: Double,
        selectedBPH: Int,
        expectedPeriod: Double,
        expectedTickCount: Int
    ) -> SelectedDetection? {
        var best: SelectedDetection?

        for scale in thresholdScales {
            let detection = detectPeaks(envelope: envelope,
                                        sampleRate: sampleRate,
                                        expectedPeriod: expectedPeriod,
                                        thresholdScale: scale)
            guard let fit = robustFit(peaks: detection.peaks, selectedBPH: selectedBPH) else {
                continue
            }

            let score = periodicityScore(candidateCount: detection.stats.candidatePeakCount,
                                         expectedTickCount: expectedTickCount,
                                         fit: fit)
            let selectionScore = detectionSelectionScore(candidateCount: detection.stats.candidatePeakCount,
                                                         expectedTickCount: expectedTickCount,
                                                         fit: fit,
                                                         periodicityScore: score)
            let selected = SelectedDetection(detection: detection,
                                             fit: fit,
                                             periodicityScore: score,
                                             selectionScore: selectionScore)

            if best == nil || selected.selectionScore > best!.selectionScore {
                best = selected
            }
        }

        return best
    }

    private static func fallbackDetection(envelope: [Float], sampleRate: Double, expectedPeriod: Double) -> PeakDetectionResult {
        var best = detectPeaks(envelope: envelope,
                               sampleRate: sampleRate,
                               expectedPeriod: expectedPeriod,
                               thresholdScale: thresholdScales[0])

        for scale in thresholdScales.dropFirst() {
            let detection = detectPeaks(envelope: envelope,
                                        sampleRate: sampleRate,
                                        expectedPeriod: expectedPeriod,
                                        thresholdScale: scale)
            if detection.stats.candidatePeakCount > best.stats.candidatePeakCount {
                best = detection
            }
        }

        return best
    }

    private static func detectPeaks(
        envelope: [Float],
        sampleRate: Double,
        expectedPeriod: Double,
        thresholdScale: Float
    ) -> PeakDetectionResult {
        guard envelope.count > 3 else {
            return PeakDetectionResult(peaks: [], stats: .empty)
        }

        let sortedSample = envelope.strideSample(maxCount: 20_000).sorted()
        let median = percentile(sortedSample, 0.50)
        let p90 = percentile(sortedSample, 0.90)
        let p95 = percentile(sortedSample, 0.95)
        let p99 = percentile(sortedSample, 0.99)
        let threshold = adaptiveThreshold(median: median, p90: p90, p95: p95, p99: p99) * thresholdScale
        let localNoiseFloor = movingAverage(envelope, window: max(16, Int(sampleRate * 0.10)))

        let minDistance = Int(sampleRate * expectedPeriod * 0.45)
        var peaks: [Double] = []
        var lastPeakIndex = -minDistance

        var i = 1
        while i < envelope.count - 1 {
            let value = envelope[i]
            let localThreshold = max(threshold, localNoiseFloor[i] * 1.18)
            if value > localThreshold,
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

        let stats = PeakDetectionStats(candidatePeakCount: peaks.count,
                                       threshold: Double(threshold),
                                       thresholdScale: Double(thresholdScale),
                                       envelopeMedian: Double(median),
                                       envelopeP95: Double(p95),
                                       estimatedSnrDb: estimatedSnrDb(signal: p95, noise: median))
        return PeakDetectionResult(peaks: peaks, stats: stats)
    }

    private static func percentile(_ sortedValues: [Float], _ fraction: Double) -> Float {
        guard !sortedValues.isEmpty else { return 0 }
        let clamped = max(0, min(1, fraction))
        let index = Int((Double(sortedValues.count - 1) * clamped).rounded())
        return sortedValues[index]
    }

    private static func movingAverage(_ values: [Float], window: Int) -> [Float] {
        guard !values.isEmpty else { return [] }

        var output = Array(repeating: Float(0), count: values.count)
        var sum: Float = 0

        for i in values.indices {
            sum += values[i]
            if i >= window {
                sum -= values[i - window]
            }
            output[i] = sum / Float(min(i + 1, window))
        }

        return output
    }

    private static func estimatedSnrDb(signal: Float, noise: Float) -> Double {
        let signalLift = max(signal - noise, 0)
        let ratio = max(Double(signalLift / max(noise, 0.000_000_001)), 1)
        return 20 * log10(ratio)
    }

    private static func adaptiveThreshold(median: Float, p90: Float, p95: Float, p99: Float) -> Float {
        let nearNoiseSpread = max(p90 - median, 0)
        let upperNoiseSpread = max(p95 - median, 0)
        let transientSpread = max(p99 - median, 0)
        let thresholdLift = max(nearNoiseSpread * 1.8,
                                upperNoiseSpread * 0.55,
                                transientSpread * 0.10)
        return median + thresholdLift
    }

    private static func periodicityScore(candidateCount: Int, expectedTickCount: Int, fit: FitResult) -> Double {
        let expected = max(expectedTickCount, 1)
        let countMatch = max(0, 1 - abs(Double(candidateCount - expected)) / Double(expected))
        let outlierScore = max(0, 1 - fit.outlierRatio)

        let stabilityScore: Double
        if fit.windowRates.count >= 3 {
            let mean = fit.windowRates.reduce(0, +) / Double(fit.windowRates.count)
            let variance = fit.windowRates.map { pow($0 - mean, 2) }.reduce(0, +) / Double(fit.windowRates.count)
            stabilityScore = max(0, 1 - sqrt(variance) / 15.0)
        } else {
            stabilityScore = fit.validCount >= max(80, Int(Double(expected) * 0.65)) ? 0.70 : 0.35
        }

        let score = fit.beatCoverage * 0.55
            + outlierScore * 0.20
            + countMatch * 0.13
            + stabilityScore * 0.12
        return max(0, min(1, score))
    }

    private static func detectionSelectionScore(
        candidateCount: Int,
        expectedTickCount: Int,
        fit: FitResult,
        periodicityScore: Double
    ) -> Double {
        let countMatch = candidateCountMatch(candidatePeakCount: candidateCount,
                                             expectedTickCount: expectedTickCount)
        let outlierScore = max(0, 1 - fit.outlierRatio)
        let stabilityScore: Double
        if fit.windowRates.count >= 3 {
            let mean = fit.windowRates.reduce(0, +) / Double(fit.windowRates.count)
            let variance = fit.windowRates.map { pow($0 - mean, 2) }.reduce(0, +) / Double(fit.windowRates.count)
            stabilityScore = max(0, 1 - sqrt(variance) / 15.0)
        } else {
            stabilityScore = fit.validCount >= max(80, Int(Double(max(expectedTickCount, 1)) * 0.65)) ? 0.70 : 0.35
        }

        let recallEstimate = tickRecallEstimate(validPeaks: fit.validCount,
                                                expectedTickCount: expectedTickCount)
        let score = fit.beatCoverage * 0.55
            + recallEstimate * 0.25
            + countMatch * 0.05
            + periodicityScore * 0.10
            + outlierScore * 0.03
            + stabilityScore * 0.02
        return max(0, min(1, score))
    }

    private struct BeatRateCompetition {
        let selectedScore: Double
        let competingBPH: Int?
        let competingScore: Double
        let isLikelyWrongBeatRate: Bool

        static func none(selectedScore: Double) -> BeatRateCompetition {
            BeatRateCompetition(selectedScore: selectedScore,
                                competingBPH: nil,
                                competingScore: 0,
                                isLikelyWrongBeatRate: false)
        }
    }

    private static func beatRateCompetition(
        envelope: [Float],
        sampleRate: Double,
        selectedBPH: Int,
        expectedTickCount: Int,
        selectedDetection: SelectedDetection,
        preliminaryQuality: SignalQuality
    ) -> BeatRateCompetition {
        guard preliminaryQuality != .low else {
            return .none(selectedScore: selectedDetection.selectionScore)
        }

        let selectedCandidateMatch = candidateCountMatch(candidatePeakCount: selectedDetection.detection.stats.candidatePeakCount,
                                                        expectedTickCount: expectedTickCount)
        let selectedLooksAmbiguous = preliminaryQuality == .medium
            || selectedCandidateMatch < 0.85
            || selectedDetection.fit.outlierRatio > 0.25
            || selectedDetection.periodicityScore < 0.80
        guard selectedLooksAmbiguous else {
            return .none(selectedScore: selectedDetection.selectionScore)
        }

        var bestCompetingBPH: Int?
        var bestCompetingDetection: SelectedDetection?

        for beatRate in BeatRate.allCases where beatRate.rawValue != selectedBPH {
            let candidatePeriod = 3600.0 / Double(beatRate.rawValue)
            let candidateExpectedCount = Self.expectedTickCount(sampleCount: envelope.count,
                                                                sampleRate: sampleRate,
                                                                expectedPeriod: candidatePeriod)
            guard let detection = bestDetection(envelope: envelope,
                                                sampleRate: sampleRate,
                                                selectedBPH: beatRate.rawValue,
                                                expectedPeriod: candidatePeriod,
                                                expectedTickCount: candidateExpectedCount) else {
                continue
            }
            let competingCandidateMatch = candidateCountMatch(candidatePeakCount: detection.detection.stats.candidatePeakCount,
                                                              expectedTickCount: candidateExpectedCount)
            let competingCountIsPlausible = competingCandidateMatch >= 0.55
                || competingCandidateMatch >= selectedCandidateMatch + 0.03
            guard detection.fit.validCount >= 80,
                  detection.fit.beatCoverage >= 0.70,
                  detection.periodicityScore >= 0.50,
                  competingCountIsPlausible else {
                continue
            }

            if bestCompetingDetection == nil || detection.selectionScore > bestCompetingDetection!.selectionScore {
                bestCompetingDetection = detection
                bestCompetingBPH = beatRate.rawValue
            }
        }

        guard let bestCompetingDetection, let bestCompetingBPH else {
            return .none(selectedScore: selectedDetection.selectionScore)
        }

        let selectedScore = selectedDetection.selectionScore
        let competingScore = bestCompetingDetection.selectionScore
        let competitorIsMateriallyBetter = competingScore >= selectedScore + 0.06
        let competitorIsCleaner = bestCompetingDetection.fit.outlierRatio + 0.10 < selectedDetection.fit.outlierRatio
            || bestCompetingDetection.periodicityScore >= selectedDetection.periodicityScore + 0.08
            || bestCompetingDetection.fit.beatCoverage >= selectedDetection.fit.beatCoverage + 0.08
        let selectedIsNoisyOrAmbiguous = selectedDetection.fit.outlierRatio > 0.20
            || selectedCandidateMatch < 0.85
            || selectedDetection.periodicityScore < 0.80
        let isLikelyWrong = competitorIsMateriallyBetter
            && competitorIsCleaner
            && selectedIsNoisyOrAmbiguous

        return BeatRateCompetition(selectedScore: selectedScore,
                                   competingBPH: bestCompetingBPH,
                                   competingScore: competingScore,
                                   isLikelyWrongBeatRate: isLikelyWrong)
    }

    private static func candidateCountMatch(candidatePeakCount: Int, expectedTickCount: Int) -> Double {
        let expected = max(expectedTickCount, 1)
        return max(0, 1 - abs(Double(candidatePeakCount - expected)) / Double(expected))
    }

    private static func hasConfidentCoverage(
        beatCoverage: Double,
        candidatePeakCount: Int,
        validPeakCount: Int,
        expectedTickCount: Int
    ) -> Bool {
        if beatCoverage >= 0.80 {
            return true
        }
        if expectedTickCount > 0,
           beatCoverage >= 0.70,
           Double(validPeakCount) / Double(expectedTickCount) >= 0.70 {
            return true
        }
        return beatCoverage >= 0.75
            && candidateCountMatch(candidatePeakCount: candidatePeakCount, expectedTickCount: expectedTickCount) >= 0.80
    }

    private struct FitResult {
        let period: Double
        let validCount: Int
        let beatCoverage: Double
        let outlierRatio: Double
        let windowRates: [Double]
        let analysisWindowCount: Int
        let successfulWindowCount: Int
    }

    private static func robustFit(peaks: [Double], selectedBPH: Int) -> FitResult? {
        guard peaks.count > 50 else { return nil }

        let expectedPeriod = 3600.0 / Double(selectedBPH)
        let sortedPeaks = peaks.sorted()
        let tolerance = max(expectedPeriod * 0.22, 0.014)

        var bestAssignment: GridAssignment?
        var bestScore = -Double.infinity

        for phase in phaseCandidates(peaks: sortedPeaks, period: expectedPeriod) {
            let assignment = assignPeaksToGrid(peaks: sortedPeaks,
                                               phase: phase,
                                               period: expectedPeriod,
                                               tolerance: tolerance)
            guard assignment.pairs.count > 50 else { continue }

            let coverage = beatCoverage(for: assignment.pairs)
            let countScore = min(1, Double(assignment.pairs.count) / Double(max(peaks.count, 1)))
            let residualScore = max(0, 1 - assignment.medianResidual / tolerance)
            let score = coverage * 0.60 + countScore * 0.25 + residualScore * 0.15

            if score > bestScore {
                bestScore = score
                bestAssignment = assignment
            }
        }

        guard var pairs = bestAssignment?.pairs else { return nil }
        guard pairs.count > 50 else { return nil }

        var slope = linearRegressionSlope(pairs: pairs) ?? expectedPeriod
        var intercept = linearRegressionIntercept(pairs: pairs, slope: slope) ?? pairs[0].t

        for _ in 0..<4 {
            let reassigned = assignPeaksToGrid(peaks: sortedPeaks,
                                               phase: intercept,
                                               period: slope,
                                               tolerance: max(expectedPeriod * 0.20, 0.012))
            if reassigned.pairs.count > 50 {
                pairs = reassigned.pairs
            }

            var residuals = pairs.map { abs($0.t - (intercept + slope * $0.n)) }
            residuals.sort()
            let medianResidual = residuals[residuals.count / 2]
            let threshold = max(medianResidual * 3.5, expectedPeriod * 0.10)

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
        let beatCoverage = beatCoverage(for: pairs)
        let windowSummary = windowRateEstimates(pairs: pairs, selectedBPH: selectedBPH)

        guard slope > 0 else { return nil }
        return FitResult(period: slope,
                         validCount: pairs.count,
                         beatCoverage: beatCoverage,
                         outlierRatio: max(0, min(1, outlierRatio)),
                         windowRates: windowSummary.rates,
                         analysisWindowCount: windowSummary.analysisWindowCount,
                         successfulWindowCount: windowSummary.successfulWindowCount)
    }

    private struct GridAssignment {
        let pairs: [(n: Double, t: Double)]
        let medianResidual: Double
    }

    private static func phaseCandidates(peaks: [Double], period: Double) -> [Double] {
        guard period > 0 else { return [] }

        let sampledPeaks = Array(peaks.prefix(300))
        let binCount = 32
        var bins = Array(repeating: 0, count: binCount)
        var phasesByBin = Array(repeating: [Double](), count: binCount)

        for peak in sampledPeaks {
            let phase = normalizedPhase(peak, period: period)
            let bin = min(binCount - 1, Int((phase / period) * Double(binCount)))
            bins[bin] += 1
            if phasesByBin[bin].count < 12 {
                phasesByBin[bin].append(phase)
            }
        }

        let topBins = bins.enumerated()
            .sorted { lhs, rhs in lhs.element > rhs.element }
            .prefix(8)

        var candidates: [Double] = []
        for bin in topBins {
            candidates.append((Double(bin.offset) + 0.5) / Double(binCount) * period)
            candidates.append(contentsOf: phasesByBin[bin.offset])
        }
        candidates.append(contentsOf: sampledPeaks.prefix(30).map { normalizedPhase($0, period: period) })

        var uniqueCandidates: [Double] = []
        let uniquenessTolerance = period / 400
        for candidate in candidates {
            if !uniqueCandidates.contains(where: { circularDistance($0, candidate, period: period) < uniquenessTolerance }) {
                uniqueCandidates.append(candidate)
            }
        }
        return uniqueCandidates
    }

    private static func assignPeaksToGrid(
        peaks: [Double],
        phase: Double,
        period: Double,
        tolerance: Double
    ) -> GridAssignment {
        guard period > 0, tolerance > 0 else {
            return GridAssignment(pairs: [], medianResidual: .infinity)
        }

        var bestBySlot: [Int: (time: Double, residual: Double)] = [:]

        for peak in peaks {
            let slot = Int(round((peak - phase) / period))
            guard slot >= 0 else { continue }

            let predicted = phase + Double(slot) * period
            let residual = abs(peak - predicted)
            guard residual <= tolerance else { continue }

            if let existing = bestBySlot[slot] {
                if residual < existing.residual {
                    bestBySlot[slot] = (time: peak, residual: residual)
                }
            } else {
                bestBySlot[slot] = (time: peak, residual: residual)
            }
        }

        let sortedSlots = bestBySlot.keys.sorted()
        let pairs = sortedSlots.map { slot in
            (n: Double(slot), t: bestBySlot[slot]!.time)
        }
        var residuals = sortedSlots.map { bestBySlot[$0]!.residual }.sorted()
        let medianResidual = residuals.isEmpty ? .infinity : residuals[residuals.count / 2]
        residuals.removeAll()

        return GridAssignment(pairs: pairs, medianResidual: medianResidual)
    }

    private static func normalizedPhase(_ value: Double, period: Double) -> Double {
        let phase = value.truncatingRemainder(dividingBy: period)
        return phase >= 0 ? phase : phase + period
    }

    private static func circularDistance(_ lhs: Double, _ rhs: Double, period: Double) -> Double {
        let distance = abs(lhs - rhs)
        return min(distance, max(0, period - distance))
    }

    private static func beatCoverage(for pairs: [(n: Double, t: Double)]) -> Double {
        guard let first = pairs.first?.n,
              let last = pairs.last?.n,
              last >= first else {
            return 0
        }

        let expectedSlots = max(1, Int(last - first + 1))
        return min(1, Double(pairs.count) / Double(expectedSlots))
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

    private struct WindowRateSummary {
        let rates: [Double]
        let analysisWindowCount: Int
        let successfulWindowCount: Int
    }

    private static func windowRateEstimates(pairs: [(n: Double, t: Double)], selectedBPH: Int) -> WindowRateSummary {
        guard pairs.count > 100 else {
            return WindowRateSummary(rates: [],
                                     analysisWindowCount: pairs.count > 50 ? 1 : 0,
                                     successfulWindowCount: 0)
        }

        let windowSize = 80
        let step = 40
        var rates: [Double] = []
        var analysisWindowCount = 0
        var successfulWindowCount = 0
        var start = 0

        while start + windowSize <= pairs.count {
            analysisWindowCount += 1
            let window = Array(pairs[start..<(start + windowSize)])
            if let slope = linearRegressionSlope(pairs: window), slope > 0 {
                let detectedBPH = 3600.0 / slope
                let rate = (detectedBPH / Double(selectedBPH) - 1.0) * 86_400.0
                rates.append(rate)
                successfulWindowCount += 1
            }
            start += step
        }

        return WindowRateSummary(rates: rates,
                                 analysisWindowCount: analysisWindowCount,
                                 successfulWindowCount: successfulWindowCount)
    }

    private static func qualityScore(
        validPeaks: Int,
        candidatePeakCount: Int,
        expectedTickCount: Int,
        beatCoverage: Double,
        outlierRatio: Double,
        windowRates: [Double],
        periodicityScore: Double
    ) -> Double {
        let expectedValidPeaks = max(50, Int(Double(max(expectedTickCount, 1)) * 0.75))
        let peakScore = min(100, Double(validPeaks) / Double(expectedValidPeaks) * 100.0)
        let outlierScore = max(0, 100.0 - outlierRatio * 150.0)

        let stabilityScore: Double
        if windowRates.count >= 3 {
            let mean = windowRates.reduce(0, +) / Double(windowRates.count)
            let variance = windowRates.map { pow($0 - mean, 2) }.reduce(0, +) / Double(windowRates.count)
            let stdev = sqrt(variance)
            stabilityScore = max(0, 100.0 - stdev * 8.0)
        } else {
            stabilityScore = 40
        }

        let periodicityComponent = periodicityScore * 100
        let baseScore = peakScore * 0.25
            + outlierScore * 0.20
            + stabilityScore * 0.20
            + periodicityComponent * 0.35
        let periodicityPenalty = max(0, min(1, (periodicityScore - 0.40) / 0.30))
        let coveragePenalty = beatCoverage >= 0.70 ? 1 : max(0, beatCoverage / 0.70)
        let score = max(0, min(100, baseScore * periodicityPenalty * coveragePenalty))
        if !hasConfidentCoverage(beatCoverage: beatCoverage,
                                 candidatePeakCount: candidatePeakCount,
                                 validPeakCount: validPeaks,
                                 expectedTickCount: expectedTickCount) {
            return min(score, 49)
        }
        return score
    }

    private static func tickRecallEstimate(validPeaks: Int, expectedTickCount: Int) -> Double {
        guard expectedTickCount > 0 else { return 0 }
        return min(1, Double(validPeaks) / Double(expectedTickCount))
    }

    private static func recognitionConfidence(
        qualityScore: Double,
        beatCoverage: Double,
        tickRecallEstimate: Double,
        periodicityScore: Double
    ) -> Double {
        let score = qualityScore / 100
        let confidence = score * 0.35
            + beatCoverage * 0.25
            + tickRecallEstimate * 0.20
            + periodicityScore * 0.20
        return max(0, min(1, confidence))
    }

    private static func autoBeatRateScore(_ result: WatchMeasurementResult) -> Double {
        let candidateMatch = candidateCountMatch(candidatePeakCount: result.detectedPeakCount,
                                                 expectedTickCount: result.expectedTickCount)
        let qualityComponent: Double
        switch result.quality {
        case .high:
            qualityComponent = 1
        case .medium:
            qualityComponent = 0.72
        case .low:
            qualityComponent = max(0, result.qualityScore / 100) * 0.50
        }

        let score = qualityComponent * 0.22
            + result.beatCoverage * 0.22
            + result.tickRecallEstimate * 0.18
            + result.periodicityScore * 0.18
            + candidateMatch * 0.12
            + max(0, 1 - result.outlierRatio) * 0.08
        return max(0, min(1, score))
    }

    private static func replacing(
        result: WatchMeasurementResult,
        quality: SignalQuality? = nil,
        qualityScore: Double? = nil,
        recognitionConfidence: Double? = nil,
        dominantFailureReason: RecognitionIssue? = nil,
        isAutoBPH: Bool? = nil
    ) -> WatchMeasurementResult {
        WatchMeasurementResult(selectedBPH: result.selectedBPH,
                               isAutoBPH: isAutoBPH ?? result.isAutoBPH,
                               detectedBPH: result.detectedBPH,
                               rateSecondsPerDay: result.rateSecondsPerDay,
                               qualityScore: qualityScore ?? result.qualityScore,
                               quality: quality ?? result.quality,
                               detectedPeakCount: result.detectedPeakCount,
                               validPeakCount: result.validPeakCount,
                               expectedTickCount: result.expectedTickCount,
                               beatCoverage: result.beatCoverage,
                               outlierRatio: result.outlierRatio,
                               chosenThresholdScale: result.chosenThresholdScale,
                               rmsLevel: result.rmsLevel,
                               peakLevel: result.peakLevel,
                               clippingRatio: result.clippingRatio,
                               estimatedSnrDb: result.estimatedSnrDb,
                               periodicityScore: result.periodicityScore,
                               recognitionConfidence: recognitionConfidence ?? result.recognitionConfidence,
                               tickRecallEstimate: result.tickRecallEstimate,
                               analysisWindowCount: result.analysisWindowCount,
                               successfulWindowCount: result.successfulWindowCount,
                               dominantFailureReason: dominantFailureReason ?? result.dominantFailureReason,
                               detectionThreshold: result.detectionThreshold,
                               envelopeMedian: result.envelopeMedian,
                               envelopeP95: result.envelopeP95,
                               sampleRate: result.sampleRate,
                               sampleCount: result.sampleCount,
                               routeDescription: result.routeDescription,
                               routeWarning: result.routeWarning)
    }

    private static func dominantFailureReason(
        quality: SignalQuality,
        audioStats: AudioLevelStats,
        detectionStats: PeakDetectionStats,
        fit: FitResult,
        expectedTickCount: Int,
        routeWarning: String?,
        forcedIssue: RecognitionIssue? = nil
    ) -> RecognitionIssue? {
        guard quality == .low else { return nil }

        if let forcedIssue {
            return forcedIssue
        }
        if routeWarning != nil {
            return .unsupportedRoute
        }
        if audioStats.clippingRatio > 0.001 {
            return .clipping
        }
        if audioStats.peakLevel < 0.002 || detectionStats.candidatePeakCount == 0 {
            return .tooQuiet
        }
        if detectionStats.estimatedSnrDb < 3 {
            return .tooNoisy
        }
        if expectedTickCount > 0,
           fit.beatCoverage < 0.70,
           candidateCountMatch(candidatePeakCount: detectionStats.candidatePeakCount,
                               expectedTickCount: expectedTickCount) < 0.65 {
            return .wrongBPHLikely
        }
        return .unstableGrid
    }

    private static func fallbackFailureReason(
        audioStats: AudioLevelStats,
        detectionStats: PeakDetectionStats,
        routeWarning: String?
    ) -> RecognitionIssue {
        if routeWarning != nil {
            return .unsupportedRoute
        }
        if audioStats.clippingRatio > 0.001 {
            return .clipping
        }
        if audioStats.peakLevel < 0.002 || detectionStats.candidatePeakCount == 0 {
            return .tooQuiet
        }
        if detectionStats.estimatedSnrDb < 3 {
            return .tooNoisy
        }
        return .unstableGrid
    }
}

private extension Array where Element == Float {
    func strideSample(maxCount: Int) -> [Float] {
        guard count > maxCount else { return self }
        let strideBy = Swift.max(1, count / maxCount)
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
