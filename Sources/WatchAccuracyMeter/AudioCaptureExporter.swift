import AVFoundation
import Foundation

struct AudioCaptureExport: Equatable {
    let directoryURL: URL
    let audioURL: URL
    let diagnosticsURL: URL
}

enum AudioCaptureExporter {
    static func export(
        capture: AudioCapture,
        result: WatchMeasurementResult,
        directory: URL? = nil
    ) throws -> AudioCaptureExport {
        let baseDirectory = try directory ?? defaultExportDirectory()
        let exportDirectory = baseDirectory.appendingPathComponent("watch-capture-\(timestampString(for: capture.capturedAt))",
                                                                   isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory,
                                                withIntermediateDirectories: true)

        let audioURL = exportDirectory.appendingPathComponent("capture.wav")
        let diagnosticsURL = exportDirectory.appendingPathComponent("diagnostics.json")

        try writeWAV(samples: capture.samples,
                     sampleRate: capture.sampleRate,
                     to: audioURL)
        try writeDiagnostics(capture: capture,
                             result: result,
                             audioFileName: audioURL.lastPathComponent,
                             to: diagnosticsURL)

        return AudioCaptureExport(directoryURL: exportDirectory,
                                  audioURL: audioURL,
                                  diagnosticsURL: diagnosticsURL)
    }

    private static func defaultExportDirectory() throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil,
                                                    create: true)
        let exports = documents.appendingPathComponent("WatchAccuracyExports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        return exports
    }

    private static func writeWAV(samples: [Float], sampleRate: Double, to url: URL) throws {
        let safeSampleRate = sampleRate > 0 ? sampleRate : 48_000
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: safeSampleRate,
                                         channels: 1,
                                         interleaved: false) else {
            throw AudioCaptureExportError.invalidAudioFormat
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard !samples.isEmpty else { return }

        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioCaptureExportError.invalidAudioFormat
        }
        buffer.frameLength = frameCount

        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { pointer in
                guard let baseAddress = pointer.baseAddress else { return }
                channel.update(from: baseAddress, count: samples.count)
            }
        }

        try file.write(from: buffer)
    }

    private static func writeDiagnostics(
        capture: AudioCapture,
        result: WatchMeasurementResult,
        audioFileName: String,
        to url: URL
    ) throws {
        let manifest = ExportManifest(capturedAt: capture.capturedAt,
                                      audioFileName: audioFileName,
                                      sampleRate: capture.sampleRate,
                                      duration: capture.duration,
                                      sampleCount: capture.samples.count,
                                      routeDescription: capture.routeDescription,
                                      routeWarning: capture.routeWarning,
                                      captureLevels: capture.levels,
                                      selectedBPH: result.selectedBPH,
                                      isAutoBPH: result.isAutoBPH,
                                      detectedBPH: result.detectedBPH,
                                      rateSecondsPerDay: result.rateSecondsPerDay,
                                      quality: result.quality.rawValue,
                                      qualityScore: result.qualityScore,
                                      recognitionConfidence: result.recognitionConfidence,
                                      tickRecallEstimate: result.tickRecallEstimate,
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
                                      detectionThreshold: result.detectionThreshold,
                                      envelopeMedian: result.envelopeMedian,
                                      envelopeP95: result.envelopeP95,
                                      analysisWindowCount: result.analysisWindowCount,
                                      successfulWindowCount: result.successfulWindowCount,
                                      dominantFailureReason: result.dominantFailureReason?.rawValue)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    private static func timestampString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

private enum AudioCaptureExportError: Error {
    case invalidAudioFormat
}

private struct ExportManifest: Codable {
    let capturedAt: Date
    let audioFileName: String
    let sampleRate: Double
    let duration: Double
    let sampleCount: Int
    let routeDescription: String
    let routeWarning: String?
    let captureLevels: AudioLevelStats
    let selectedBPH: Int
    let isAutoBPH: Bool
    let detectedBPH: Double
    let rateSecondsPerDay: Double
    let quality: String
    let qualityScore: Double
    let recognitionConfidence: Double
    let tickRecallEstimate: Double
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
    let detectionThreshold: Double
    let envelopeMedian: Double
    let envelopeP95: Double
    let analysisWindowCount: Int
    let successfulWindowCount: Int
    let dominantFailureReason: String?
}
