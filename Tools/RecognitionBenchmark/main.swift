import AVFoundation
import Darwin
import Foundation

private struct BenchmarkManifest: Decodable {
    let schemaVersion: Int
    let captures: [CaptureSpec]
}

private struct CaptureSpec: Decodable {
    let id: String
    let path: String
    let knownBPH: Int
    let watchID: String?
    let deviceID: String?
}

private struct BenchmarkReport: Encodable {
    let schemaVersion: Int
    let analysisMode: String
    let windowDurationSeconds: Double
    let windowHopSeconds: Double
    let captureCount: Int
    let labeledWatchCount: Int
    let labeledDeviceCount: Int
    let totalWindowCount: Int
    let successfulWindowCount: Int
    let windowSuccessRate: Double
    let acceptanceGateEligible: Bool
    let acceptanceGatePassed: Bool
    let caveat: String
    let captures: [CaptureReport]
}

private struct CaptureReport: Encodable {
    let id: String
    let knownBPH: Int
    let watchID: String?
    let deviceID: String?
    let sampleRate: Double
    let durationSeconds: Double
    let successfulWindowCount: Int
    let totalWindowCount: Int
    let windowSuccessRate: Double
    let fullCapture: AnalysisReport
    let windows: [WindowReport]
}

private struct WindowReport: Encodable {
    let startSeconds: Double
    let durationSeconds: Double
    let passed: Bool
    let analysis: AnalysisReport
}

private struct AnalysisReport: Encodable {
    let selectedBPH: Int
    let quality: String
    let qualityScore: Double
    let recognitionConfidence: Double
    let beatCoverage: Double
    let tickRecallEstimate: Double
    let periodicityScore: Double
    let spectralPeriodicityScore: Double
    let alternatingSpectralPeriodicityScore: Double
    let alternatingSpectralConsensus: Double
    let outlierRatio: Double
    let successfulWindowCount: Int
    let analysisWindowCount: Int
    let dominantFailureReason: String?

    init(_ result: WatchMeasurementResult) {
        selectedBPH = result.selectedBPH
        quality = result.quality.rawValue
        qualityScore = result.qualityScore
        recognitionConfidence = result.recognitionConfidence
        beatCoverage = result.beatCoverage
        tickRecallEstimate = result.tickRecallEstimate
        periodicityScore = result.periodicityScore
        spectralPeriodicityScore = result.spectralPeriodicityScore
        alternatingSpectralPeriodicityScore = result.alternatingSpectralPeriodicityScore
        alternatingSpectralConsensus = result.alternatingSpectralConsensus
        outlierRatio = result.outlierRatio
        successfulWindowCount = result.successfulWindowCount
        analysisWindowCount = result.analysisWindowCount
        dominantFailureReason = result.dominantFailureReason?.rawValue
    }
}

private enum BenchmarkError: LocalizedError {
    case usage
    case unsupportedManifestVersion(Int)
    case emptyManifest
    case invalidCapture(String)
    case duplicateCaptureID(String)
    case duplicateCapturePath(String)
    case unsupportedBPH(Int, String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: run-recognition-benchmark <manifest.json> [window-seconds] [hop-seconds]"
        case .unsupportedManifestVersion(let version):
            return "Unsupported benchmark manifest schemaVersion \(version)."
        case .emptyManifest:
            return "The benchmark manifest contains no captures."
        case .invalidCapture(let id):
            return "Capture \(id) is empty, shorter than one analysis window, or has an invalid sample rate."
        case .duplicateCaptureID(let id):
            return "Capture id \(id) appears more than once."
        case .duplicateCapturePath(let path):
            return "Capture path \(path) appears more than once."
        case .unsupportedBPH(let bph, let id):
            return "Capture \(id) uses unsupported BPH \(bph)."
        }
    }
}

private func loadSamples(from url: URL) throws -> (samples: [Float], sampleRate: Double) {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let channels = max(1, Int(format.channelCount))
    var samples: [Float] = []
    samples.reserveCapacity(Int(file.length))

    while file.framePosition < file.length {
        let remaining = file.length - file.framePosition
        let requestedFrames = AVAudioFrameCount(min(remaining, 65_536))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: requestedFrames) else {
            throw BenchmarkError.invalidCapture(url.lastPathComponent)
        }
        try file.read(into: buffer, frameCount: requestedFrames)
        guard buffer.frameLength > 0 else { break }
        guard let channelData = buffer.floatChannelData else {
            throw BenchmarkError.invalidCapture(url.lastPathComponent)
        }

        for frame in 0..<Int(buffer.frameLength) {
            var mixed: Float = 0
            for channel in 0..<channels {
                mixed += channelData[channel][frame]
            }
            samples.append(mixed / Float(channels))
        }
    }

    guard samples.count == Int(file.length) else {
        throw BenchmarkError.invalidCapture(url.lastPathComponent)
    }
    return (samples, format.sampleRate)
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let manifestPath = arguments.first else { throw BenchmarkError.usage }
    let windowDuration = arguments.count > 1 ? Double(arguments[1]) : 20
    let windowHop = arguments.count > 2 ? Double(arguments[2]) : 5
    guard let windowDuration, let windowHop,
          windowDuration > 10, windowHop > 0 else {
        throw BenchmarkError.usage
    }

    let manifestURL = URL(fileURLWithPath: manifestPath)
    let manifest = try JSONDecoder().decode(BenchmarkManifest.self,
                                             from: Data(contentsOf: manifestURL))
    guard manifest.schemaVersion == 1 else {
        throw BenchmarkError.unsupportedManifestVersion(manifest.schemaVersion)
    }
    guard !manifest.captures.isEmpty else { throw BenchmarkError.emptyManifest }

    var captureReports: [CaptureReport] = []
    var captureIDs = Set<String>()
    var capturePaths = Set<String>()
    for capture in manifest.captures {
        guard !capture.id.isEmpty else { throw BenchmarkError.invalidCapture(capture.id) }
        guard captureIDs.insert(capture.id).inserted else {
            throw BenchmarkError.duplicateCaptureID(capture.id)
        }
        guard BeatRate.allCases.contains(where: { $0.rawValue == capture.knownBPH }) else {
            throw BenchmarkError.unsupportedBPH(capture.knownBPH, capture.id)
        }
        let captureURL = URL(fileURLWithPath: capture.path,
                             relativeTo: manifestURL.deletingLastPathComponent()).standardizedFileURL
        guard capturePaths.insert(captureURL.path).inserted else {
            throw BenchmarkError.duplicateCapturePath(captureURL.path)
        }
        let loaded = try loadSamples(from: captureURL)
        let windowFrames = Int((windowDuration * loaded.sampleRate).rounded())
        let hopFrames = Int((windowHop * loaded.sampleRate).rounded())
        guard loaded.sampleRate > 0,
              windowFrames > 0,
              loaded.samples.count >= windowFrames else {
            throw BenchmarkError.invalidCapture(capture.id)
        }

        var windows: [WindowReport] = []
        var start = 0
        while start + windowFrames <= loaded.samples.count {
            let samples = Array(loaded.samples[start..<(start + windowFrames)])
            let result = WatchDSP.analyzeAuto(samples: samples,
                                              sampleRate: loaded.sampleRate,
                                              routeDescription: capture.id)
            let passed = result.selectedBPH == capture.knownBPH && result.quality != .low
            windows.append(WindowReport(startSeconds: Double(start) / loaded.sampleRate,
                                        durationSeconds: windowDuration,
                                        passed: passed,
                                        analysis: AnalysisReport(result)))
            start += hopFrames
        }

        let fullResult = WatchDSP.analyzeAuto(samples: loaded.samples,
                                              sampleRate: loaded.sampleRate,
                                              routeDescription: capture.id)
        let successfulWindows = windows.filter(\.passed).count
        captureReports.append(CaptureReport(id: capture.id,
                                            knownBPH: capture.knownBPH,
                                            watchID: capture.watchID,
                                            deviceID: capture.deviceID,
                                            sampleRate: loaded.sampleRate,
                                            durationSeconds: Double(loaded.samples.count) / loaded.sampleRate,
                                            successfulWindowCount: successfulWindows,
                                            totalWindowCount: windows.count,
                                            windowSuccessRate: Double(successfulWindows) / Double(windows.count),
                                            fullCapture: AnalysisReport(fullResult),
                                            windows: windows))
    }

    let totalWindows = captureReports.reduce(0) { $0 + $1.totalWindowCount }
    let successfulWindows = captureReports.reduce(0) { $0 + $1.successfulWindowCount }
    let successRate = totalWindows > 0 ? Double(successfulWindows) / Double(totalWindows) : 0
    let labeledWatches = Set(manifest.captures.compactMap(\.watchID)).count
    let labeledDevices = Set(manifest.captures.compactMap(\.deviceID)).count
    let gateEligible = captureReports.count >= 20
        && totalWindows >= 100
        && labeledWatches >= 5
        && labeledDevices >= 2
    let report = BenchmarkReport(
        schemaVersion: 1,
        analysisMode: "dspOnly",
        windowDurationSeconds: windowDuration,
        windowHopSeconds: windowHop,
        captureCount: captureReports.count,
        labeledWatchCount: labeledWatches,
        labeledDeviceCount: labeledDevices,
        totalWindowCount: totalWindows,
        successfulWindowCount: successfulWindows,
        windowSuccessRate: successRate,
        acceptanceGateEligible: gateEligible,
        acceptanceGatePassed: gateEligible && successRate >= 0.90,
        caveat: "Overlapping windows are correlated. Report held-out watches and devices separately before claiming product accuracy.",
        captures: captureReports
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(report)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

do {
    try run()
} catch {
    fputs("Recognition benchmark failed: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
