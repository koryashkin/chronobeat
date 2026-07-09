import Foundation

struct AudioLevelStats: Codable, Equatable, Sendable {
    let rmsLevel: Double
    let peakLevel: Double
    let clippingRatio: Double

    static let empty = AudioLevelStats(rmsLevel: 0, peakLevel: 0, clippingRatio: 0)

    static func measure(_ samples: [Float]) -> AudioLevelStats {
        guard !samples.isEmpty else { return .empty }

        var sumSquares = 0.0
        var peak = 0.0
        var clipped = 0

        for sample in samples {
            let magnitude = Double(abs(sample))
            sumSquares += magnitude * magnitude
            peak = max(peak, magnitude)
            if magnitude >= 0.98 {
                clipped += 1
            }
        }

        return AudioLevelStats(rmsLevel: sqrt(sumSquares / Double(samples.count)),
                               peakLevel: peak,
                               clippingRatio: Double(clipped) / Double(samples.count))
    }
}

struct AudioCapture: Sendable {
    let samples: [Float]
    let sampleRate: Double
    let routeDescription: String
    let routeWarning: String?
    let capturedAt: Date
    let levels: AudioLevelStats

    var duration: Double {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }

    init(samples: [Float],
         sampleRate: Double,
         routeDescription: String,
         routeWarning: String? = nil,
         capturedAt: Date = Date(),
         levels: AudioLevelStats? = nil) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.routeDescription = routeDescription
        self.routeWarning = routeWarning
        self.capturedAt = capturedAt
        self.levels = levels ?? AudioLevelStats.measure(samples)
    }
}

enum RecognitionIssue: String, Codable, Equatable, Sendable {
    case tooQuiet
    case tooNoisy
    case clipping
    case unstableGrid
    case wrongBPHLikely
    case unsupportedRoute

    var label: String {
        switch self {
        case .tooQuiet:
            return "Too quiet"
        case .tooNoisy:
            return "Too noisy"
        case .clipping:
            return "Clipping"
        case .unstableGrid:
            return "Unstable tick grid"
        case .wrongBPHLikely:
            return "Wrong beat rate likely"
        case .unsupportedRoute:
            return "Unsupported input route"
        }
    }
}
