import AVFoundation
import Darwin
import Foundation

private struct ReviewEvent: Encodable {
    let id: String
    let sampleIndex: Int
    let timeSeconds: Double
    let normalizedEnvelope: Double
    let nearestAssignedDistanceSeconds: Double?
    let provisionalLabel: String
    let localPeak: Double
    let waveform: [Double]
}

private struct ReviewPackage: Encodable {
    let schemaVersion: Int
    let featureSchemaVersion: Int
    let captureID: String
    let audioFileName: String
    let audioMimeType: String
    let knownBPH: Int
    let sampleRate: Double
    let sampleCount: Int
    let durationSeconds: Double
    let dspSelectedBPH: Int
    let dspQuality: String
    let dspFailureReason: String?
    let selectionPolicy: String
    let sourceCandidateCount: Int
    let mergedCandidateCount: Int
    let traceEventCount: Int
    let reviewEventCount: Int
    let events: [ReviewEvent]
}

private enum ReviewExportError: LocalizedError {
    case usage
    case unsupportedBPH(Int)
    case invalidMaximumEventCount(Int)
    case invalidCapture(String)
    case outputDirectoryNotEmpty(String)
    case missingTemplate
    case invalidTemplate

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: run-candidate-review <capture.wav> <known-bph> <output-directory> [--capture-id id] [--max-events 600]"
        case .unsupportedBPH(let value):
            return "Unsupported known BPH \(value)."
        case .invalidMaximumEventCount(let value):
            return "max-events must be between 1 and 4000; received \(value)."
        case .invalidCapture(let name):
            return "Capture \(name) is empty, unreadable, or has an invalid sample rate."
        case .outputDirectoryNotEmpty(let path):
            return "Output directory is not empty: \(path)"
        case .missingTemplate:
            return "Candidate review HTML template path is unavailable."
        case .invalidTemplate:
            return "Candidate review HTML template is missing an embedded-data placeholder."
        }
    }
}

private struct Arguments {
    let captureURL: URL
    let knownBPH: Int
    let outputURL: URL
    let captureID: String
    let maximumEventCount: Int
}

private func parseArguments() throws -> Arguments {
    let values = Array(CommandLine.arguments.dropFirst())
    guard values.count >= 3, let knownBPH = Int(values[1]) else {
        throw ReviewExportError.usage
    }
    guard BeatRate.allCases.contains(where: { $0.rawValue == knownBPH }) else {
        throw ReviewExportError.unsupportedBPH(knownBPH)
    }

    let captureURL = URL(fileURLWithPath: values[0]).standardizedFileURL
    let outputURL = URL(fileURLWithPath: values[2], isDirectory: true).standardizedFileURL
    var captureID = defaultCaptureID(for: captureURL)
    var maximumEventCount = 600
    var index = 3
    while index < values.count {
        guard index + 1 < values.count else { throw ReviewExportError.usage }
        switch values[index] {
        case "--capture-id":
            captureID = values[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !captureID.isEmpty else { throw ReviewExportError.usage }
        case "--max-events":
            guard let parsed = Int(values[index + 1]) else { throw ReviewExportError.usage }
            maximumEventCount = parsed
        default:
            throw ReviewExportError.usage
        }
        index += 2
    }
    guard (1...4_000).contains(maximumEventCount) else {
        throw ReviewExportError.invalidMaximumEventCount(maximumEventCount)
    }
    return Arguments(captureURL: captureURL,
                     knownBPH: knownBPH,
                     outputURL: outputURL,
                     captureID: captureID,
                     maximumEventCount: maximumEventCount)
}

private func defaultCaptureID(for url: URL) -> String {
    if url.deletingPathExtension().lastPathComponent.lowercased() == "capture" {
        return url.deletingLastPathComponent().lastPathComponent
    }
    return url.deletingPathExtension().lastPathComponent
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
            throw ReviewExportError.invalidCapture(url.lastPathComponent)
        }
        try file.read(into: buffer, frameCount: requestedFrames)
        guard buffer.frameLength > 0 else { break }
        guard let channelData = buffer.floatChannelData else {
            throw ReviewExportError.invalidCapture(url.lastPathComponent)
        }

        for frame in 0..<Int(buffer.frameLength) {
            var mixed: Float = 0
            for channel in 0..<channels {
                mixed += channelData[channel][frame]
            }
            samples.append(mixed / Float(channels))
        }
    }

    guard samples.count == Int(file.length), format.sampleRate > 0 else {
        throw ReviewExportError.invalidCapture(url.lastPathComponent)
    }
    return (samples, format.sampleRate)
}

private func prepareOutputDirectory(_ url: URL) throws {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else {
            throw ReviewExportError.outputDirectoryNotEmpty(url.path)
        }
        let contents = try fileManager.contentsOfDirectory(atPath: url.path)
        guard contents.isEmpty else {
            throw ReviewExportError.outputDirectoryNotEmpty(url.path)
        }
    } else {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

private func audioMimeType(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "m4a", "mp4": return "audio/mp4"
    case "caf": return "audio/x-caf"
    default: return "audio/wav"
    }
}

private func makeReviewPackage(arguments: Arguments) throws -> ReviewPackage {
    let loaded = try loadSamples(from: arguments.captureURL)
    let capture = AudioCapture(samples: loaded.samples,
                               sampleRate: loaded.sampleRate,
                               routeDescription: "Offline manual review")
    let result = WatchDSP.analyze(capture: capture, selectedBPH: arguments.knownBPH)
    let trace = WatchDSP.makeCandidateTrace(capture: capture, result: result)
    let selected = CandidateReviewSampler.selectEvents(
        trace.events,
        maximumCount: arguments.maximumEventCount
    )
    let events = selected.map { event in
        let preview = CandidateReviewSampler.preview(samples: loaded.samples,
                                                     sampleRate: loaded.sampleRate,
                                                     centerIndex: event.sampleIndex)
        return ReviewEvent(id: "sample-\(event.sampleIndex)",
                           sampleIndex: event.sampleIndex,
                           timeSeconds: event.timeSeconds,
                           normalizedEnvelope: event.normalizedEnvelope,
                           nearestAssignedDistanceSeconds: event.nearestAssignedDistanceSeconds,
                           provisionalLabel: event.provisionalLabel.rawValue,
                           localPeak: preview.localPeak,
                           waveform: preview.waveform)
    }

    return ReviewPackage(
        schemaVersion: 1,
        featureSchemaVersion: TickCandidateFeatureSchema.version,
        captureID: arguments.captureID,
        audioFileName: arguments.captureURL.lastPathComponent,
        audioMimeType: audioMimeType(for: arguments.captureURL),
        knownBPH: arguments.knownBPH,
        sampleRate: loaded.sampleRate,
        sampleCount: loaded.samples.count,
        durationSeconds: capture.duration,
        dspSelectedBPH: result.selectedBPH,
        dspQuality: result.quality.rawValue,
        dspFailureReason: result.dominantFailureReason?.rawValue,
        selectionPolicy: "balanced-provisional-classes-temporal-strength-v1",
        sourceCandidateCount: trace.sourceCandidateCount,
        mergedCandidateCount: trace.mergedCandidateCount,
        traceEventCount: trace.events.count,
        reviewEventCount: events.count,
        events: events
    )
}

private func writeReviewPackage(
    _ package: ReviewPackage,
    arguments: Arguments
) throws {
    try prepareOutputDirectory(arguments.outputURL)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let packageData = try encoder.encode(package)
    let dataURL = arguments.outputURL.appendingPathComponent("review-data.json")
    try packageData.write(to: dataURL, options: .atomic)

    guard let templatePath = ProcessInfo.processInfo.environment["CHRONOBEAT_REVIEW_TEMPLATE"] else {
        throw ReviewExportError.missingTemplate
    }
    let template = try String(contentsOfFile: templatePath, encoding: .utf8)
    guard template.contains("__REVIEW_DATA__"),
          template.contains("__AUDIO_BASE64__") else {
        throw ReviewExportError.invalidTemplate
    }
    let json = String(decoding: packageData, as: UTF8.self)
        .replacingOccurrences(of: "</", with: "<\\/")
    let audioBase64 = try Data(contentsOf: arguments.captureURL).base64EncodedString()
    let html = template
        .replacingOccurrences(of: "__REVIEW_DATA__", with: json)
        .replacingOccurrences(of: "__AUDIO_BASE64__", with: audioBase64)
    let htmlURL = arguments.outputURL.appendingPathComponent("review.html")
    try html.write(to: htmlURL, atomically: true, encoding: .utf8)
}

private func run() throws {
    let arguments = try parseArguments()
    let package = try makeReviewPackage(arguments: arguments)
    try writeReviewPackage(package, arguments: arguments)

    let summary = [
        "reviewHTML": arguments.outputURL.appendingPathComponent("review.html").path,
        "reviewData": arguments.outputURL.appendingPathComponent("review-data.json").path,
        "captureID": package.captureID,
        "dspQuality": package.dspQuality,
        "reviewEventCount": String(package.reviewEventCount)
    ]
    let data = try JSONSerialization.data(withJSONObject: summary,
                                          options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

do {
    try run()
} catch {
    fputs("Candidate review export failed: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
