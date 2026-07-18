import AVFoundation
import CoreML
import CreateML
import Darwin
import Foundation
import TabularData

private struct ExperimentManifest: Decodable {
    let schemaVersion: Int
    let captures: [CaptureSpec]
}

private struct CaptureSpec: Decodable {
    let id: String
    let path: String
    let knownBPH: Int
    let watchID: String?
    let deviceID: String?
    let reviewLabelsPath: String?
}

private struct ReviewedLabels: Decodable {
    let schemaVersion: Int
    let featureSchemaVersion: Int?
    let captureID: String
    let knownBPH: Int
    let events: [ReviewedLabelEvent]
}

private struct ReviewedLabelEvent: Decodable {
    let id: String
    let sampleIndex: Int
    let normalizedEnvelope: Double?
    let reviewedLabel: String?
}

private struct CandidateExample {
    let captureID: String
    let watchID: String
    let sampleIndex: Int
    let isTick: Bool
    let envelope: Double
    let features: TickCandidateFeatureVector
}

private enum ModelKind: String {
    case logistic
    case boostedTree = "boosted-tree"

    var reportName: String {
        switch self {
        case .logistic:
            return "CreateML logistic regression over fixed-rate transient features"
        case .boostedTree:
            return "CreateML boosted tree over fixed-rate transient features"
        }
    }
}

private enum TrainedClassifier {
    case logistic(MLLogisticRegressionClassifier)
    case boostedTree(MLBoostedTreeClassifier)
}

private struct ClassificationMetrics: Encodable {
    let truePositive: Int
    let falsePositive: Int
    let trueNegative: Int
    let falseNegative: Int
    let precision: Double
    let recall: Double
    let f1: Double
    let accuracy: Double

    init(labels: [Bool], predictions: [Bool]) {
        precondition(labels.count == predictions.count)
        var truePositive = 0
        var falsePositive = 0
        var trueNegative = 0
        var falseNegative = 0
        for (label, prediction) in zip(labels, predictions) {
            switch (label, prediction) {
            case (true, true): truePositive += 1
            case (false, true): falsePositive += 1
            case (false, false): trueNegative += 1
            case (true, false): falseNegative += 1
            }
        }
        self.init(truePositive: truePositive,
                  falsePositive: falsePositive,
                  trueNegative: trueNegative,
                  falseNegative: falseNegative)
    }

    init(truePositive: Int, falsePositive: Int, trueNegative: Int, falseNegative: Int) {
        self.truePositive = truePositive
        self.falsePositive = falsePositive
        self.trueNegative = trueNegative
        self.falseNegative = falseNegative
        let precisionDenominator = truePositive + falsePositive
        let recallDenominator = truePositive + falseNegative
        let total = truePositive + falsePositive + trueNegative + falseNegative
        precision = precisionDenominator > 0
            ? Double(truePositive) / Double(precisionDenominator)
            : 0
        recall = recallDenominator > 0
            ? Double(truePositive) / Double(recallDenominator)
            : 0
        f1 = precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0
        accuracy = total > 0 ? Double(truePositive + trueNegative) / Double(total) : 0
    }

    static func aggregate(_ metrics: [ClassificationMetrics]) -> ClassificationMetrics {
        ClassificationMetrics(
            truePositive: metrics.reduce(0) { $0 + $1.truePositive },
            falsePositive: metrics.reduce(0) { $0 + $1.falsePositive },
            trueNegative: metrics.reduce(0) { $0 + $1.trueNegative },
            falseNegative: metrics.reduce(0) { $0 + $1.falseNegative }
        )
    }
}

private struct CaptureReport: Encodable {
    let id: String
    let watchID: String
    let deviceID: String
    let knownBPH: Int
    let detectedBPH: Int
    let quality: String
    let sourceCandidateCount: Int
    let mergedCandidateCount: Int
    let exportedEventCount: Int
    let labelingMode: String
    let tickLabelCount: Int
    let noiseLabelCount: Int
    let ignoredLabelCount: Int
}

private struct FoldReport: Encodable {
    let heldOutWatchID: String
    let trainingCaptureIDs: [String]
    let testingCaptureIDs: [String]
    let balancedTrainingExampleCount: Int
    let testingExampleCount: Int
    let baselineEnvelopeThreshold: Double
    let modelMetrics: ClassificationMetrics
    let envelopeBaselineMetrics: ClassificationMetrics
}

private struct ExperimentReport: Encodable {
    let schemaVersion: Int
    let featureSchemaVersion: Int
    let analysisMode: String
    let labelSource: String
    let modelType: String
    let captureCount: Int
    let labeledWatchCount: Int
    let labeledDeviceCount: Int
    let labeledCandidateCount: Int
    let reviewedCandidateCount: Int
    let provisionalCandidateCount: Int
    let ignoredCandidateCount: Int
    let usesOnlyReviewedLabels: Bool
    let folds: [FoldReport]
    let aggregateModelMetrics: ClassificationMetrics
    let aggregateEnvelopeBaselineMetrics: ClassificationMetrics
    let modelImprovesF1OverEnvelopeBaseline: Bool
    let candidateMetricGatePassed: Bool
    let productionEligible: Bool
    let modelOutputPath: String?
    let caveats: [String]
    let captures: [CaptureReport]
}

private enum ExperimentError: LocalizedError {
    case usage
    case unsupportedManifestVersion(Int)
    case emptyManifest
    case duplicateCaptureID(String)
    case duplicateCapturePath(String)
    case invalidCapture(String)
    case missingWatchID(String)
    case missingDeviceID(String)
    case unsupportedBPH(Int, String)
    case insufficientWatches(Int)
    case unusableLabels(String)
    case unsupportedModelType(String)
    case invalidReviewedLabels(String)
    case invalidPrediction

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: run-tick-candidate-ml-experiment <manifest.json> [--model-type logistic|boosted-tree] [--model-output /tmp/model.mlmodel]"
        case .unsupportedManifestVersion(let version):
            return "Unsupported experiment manifest schemaVersion \(version)."
        case .emptyManifest:
            return "The experiment manifest contains no captures."
        case .duplicateCaptureID(let id):
            return "Capture id \(id) appears more than once."
        case .duplicateCapturePath(let path):
            return "Capture path \(path) appears more than once."
        case .invalidCapture(let id):
            return "Capture \(id) is empty, unreadable, or has an invalid sample rate."
        case .missingWatchID(let id):
            return "Capture \(id) needs a watchID for capture-safe evaluation."
        case .missingDeviceID(let id):
            return "Capture \(id) needs a deviceID for device-diversity reporting."
        case .unsupportedBPH(let bph, let id):
            return "Capture \(id) uses unsupported BPH \(bph)."
        case .insufficientWatches(let count):
            return "Leave-one-watch-out evaluation needs at least two watches; found \(count)."
        case .unusableLabels(let description):
            return "Candidate labels cannot train this fold: \(description)."
        case .unsupportedModelType(let value):
            return "Unsupported model type \(value). Use logistic or boosted-tree."
        case .invalidReviewedLabels(let description):
            return "Reviewed labels are invalid: \(description)."
        case .invalidPrediction:
            return "Create ML returned an unexpected prediction column."
        }
    }
}

private func loadSamples(from url: URL, captureID: String) throws -> (samples: [Float], sampleRate: Double) {
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
            throw ExperimentError.invalidCapture(captureID)
        }
        try file.read(into: buffer, frameCount: requestedFrames)
        guard buffer.frameLength > 0 else { break }
        guard let channelData = buffer.floatChannelData else {
            throw ExperimentError.invalidCapture(captureID)
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
        throw ExperimentError.invalidCapture(captureID)
    }
    return (samples, format.sampleRate)
}

private func loadReviewedLabels(
    for spec: CaptureSpec,
    manifestURL: URL
) throws -> ReviewedLabels? {
    guard let path = spec.reviewLabelsPath else { return nil }
    let url = URL(fileURLWithPath: path,
                  relativeTo: manifestURL.deletingLastPathComponent()).standardizedFileURL
    let labels = try JSONDecoder().decode(ReviewedLabels.self,
                                          from: Data(contentsOf: url))
    guard labels.schemaVersion == 1 else {
        throw ExperimentError.invalidReviewedLabels(
            "capture \(spec.id) uses schemaVersion \(labels.schemaVersion)"
        )
    }
    guard labels.captureID == spec.id else {
        throw ExperimentError.invalidReviewedLabels(
            "capture id \(labels.captureID) does not match manifest id \(spec.id)"
        )
    }
    guard labels.knownBPH == spec.knownBPH else {
        throw ExperimentError.invalidReviewedLabels(
            "capture \(spec.id) BPH does not match the manifest"
        )
    }
    if let featureSchemaVersion = labels.featureSchemaVersion,
       featureSchemaVersion != TickCandidateFeatureSchema.version {
        throw ExperimentError.invalidReviewedLabels(
            "capture \(spec.id) uses feature schema \(featureSchemaVersion)"
        )
    }

    var ids = Set<String>()
    var sampleIndices = Set<Int>()
    for event in labels.events {
        guard ids.insert(event.id).inserted,
              sampleIndices.insert(event.sampleIndex).inserted else {
            throw ExperimentError.invalidReviewedLabels(
                "capture \(spec.id) contains duplicate reviewed events"
            )
        }
        if let label = event.reviewedLabel,
           !["tick", "noise", "unsure"].contains(label) {
            throw ExperimentError.invalidReviewedLabels(
                "capture \(spec.id) contains unsupported label \(label)"
            )
        }
        if let envelope = event.normalizedEnvelope, !envelope.isFinite {
            throw ExperimentError.invalidReviewedLabels(
                "capture \(spec.id) contains a non-finite envelope"
            )
        }
    }
    return labels
}

private func dataFrame(from examples: [CandidateExample]) -> DataFrame {
    var columns = TickCandidateFeatureSchema.featureNames.enumerated().map { index, name in
        Column<Double>(name: name, contents: examples.map { $0.features[index] })
            .eraseToAnyColumn()
    }
    columns.append(Column<String>(name: "label",
                                  contents: examples.map { $0.isTick ? "tick" : "noise" })
        .eraseToAnyColumn())
    return DataFrame(columns: columns)
}

private func trainClassifier(
    examples: [CandidateExample],
    modelKind: ModelKind
) throws -> TrainedClassifier {
    guard examples.contains(where: \.isTick), examples.contains(where: { !$0.isTick }) else {
        throw ExperimentError.unusableLabels("training data must contain tick and noise candidates")
    }
    let frame = dataFrame(from: examples)
    switch modelKind {
    case .logistic:
        let parameters = MLLogisticRegressionClassifier.ModelParameters(
            validation: .none,
            maxIterations: 100,
            l1Penalty: 0,
            l2Penalty: 0.1,
            stepSize: 1,
            convergenceThreshold: 0.001,
            featureRescaling: true
        )
        return .logistic(try MLLogisticRegressionClassifier(
            trainingData: frame,
            targetColumn: "label",
            featureColumns: TickCandidateFeatureSchema.featureNames,
            parameters: parameters
        ))
    case .boostedTree:
        let parameters = MLBoostedTreeClassifier.ModelParameters(
            validation: .none,
            maxDepth: 4,
            maxIterations: 60,
            minLossReduction: 0,
            minChildWeight: 1,
            randomSeed: 42,
            stepSize: 0.1,
            earlyStoppingRounds: nil,
            rowSubsample: 0.8,
            columnSubsample: 0.8
        )
        return .boostedTree(try MLBoostedTreeClassifier(
            trainingData: frame,
            targetColumn: "label",
            featureColumns: TickCandidateFeatureSchema.featureNames,
            parameters: parameters
        ))
    }
}

private func predictions(
    from classifier: TrainedClassifier,
    examples: [CandidateExample]
) throws -> [Bool] {
    let frame = dataFrame(from: examples)
    let column: AnyColumn
    switch classifier {
    case .logistic(let model):
        column = try model.predictions(from: frame)
    case .boostedTree(let model):
        column = try model.predictions(from: frame)
    }
    return try (0..<column.count).map { index in
        guard let label = column[index] as? String else {
            throw ExperimentError.invalidPrediction
        }
        return label == "tick"
    }
}

private func diverseSample(_ examples: [CandidateExample], limit: Int) -> [CandidateExample] {
    guard limit > 0, examples.count > limit else { return Array(examples.prefix(max(0, limit))) }
    let ordered = examples.sorted {
        if $0.captureID != $1.captureID { return $0.captureID < $1.captureID }
        return $0.sampleIndex < $1.sampleIndex
    }
    var selected: [CandidateExample] = []
    selected.reserveCapacity(limit)
    let sourceCount = Double(ordered.count)
    let selectedCount = Double(limit)
    for index in 0..<limit {
        let position = (Double(index) + 0.5) * sourceCount / selectedCount
        let sourceIndex = min(ordered.count - 1, Int(position))
        selected.append(ordered[sourceIndex])
    }
    return selected
}

private func balancedTrainingExamples(_ examples: [CandidateExample]) -> [CandidateExample] {
    let grouped = Dictionary(grouping: examples, by: \.captureID)
    return grouped.keys.sorted().flatMap { captureID in
        let captureExamples = grouped[captureID] ?? []
        let ticks = captureExamples.filter(\.isTick)
        let noise = captureExamples.filter { !$0.isTick }
        let count = min(ticks.count, noise.count)
        return diverseSample(ticks, limit: count) + diverseSample(noise, limit: count)
    }
}

private func bestEnvelopeThreshold(trainingExamples: [CandidateExample]) -> Double {
    let sortedValues = Array(Set(trainingExamples.map(\.envelope))).sorted()
    guard let first = sortedValues.first, let last = sortedValues.last else { return .infinity }
    let stride = max(1, sortedValues.count / 512)
    var thresholds = [first.nextDown]
    thresholds.append(contentsOf: Swift.stride(from: 0, to: sortedValues.count, by: stride).map {
        sortedValues[$0]
    })
    thresholds.append(last.nextUp)

    let labels = trainingExamples.map(\.isTick)
    return thresholds.max { lhs, rhs in
        let lhsMetrics = ClassificationMetrics(
            labels: labels,
            predictions: trainingExamples.map { $0.envelope >= lhs }
        )
        let rhsMetrics = ClassificationMetrics(
            labels: labels,
            predictions: trainingExamples.map { $0.envelope >= rhs }
        )
        if lhsMetrics.f1 != rhsMetrics.f1 { return lhsMetrics.f1 < rhsMetrics.f1 }
        if lhsMetrics.recall != rhsMetrics.recall { return lhsMetrics.recall < rhsMetrics.recall }
        return lhs < rhs
    } ?? .infinity
}

private func write(
    classifier: TrainedClassifier,
    to url: URL,
    metadata: MLModelMetadata
) throws {
    switch classifier {
    case .logistic(let model):
        try model.write(to: url, metadata: metadata)
    case .boostedTree(let model):
        try model.write(to: url, metadata: metadata)
    }
}

private func parseArguments() throws -> (
    manifestURL: URL,
    modelOutputURL: URL?,
    modelKind: ModelKind
) {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let manifestPath = arguments.first else { throw ExperimentError.usage }
    var modelOutputURL: URL?
    var modelKind = ModelKind.logistic
    var index = 1
    while index < arguments.count {
        guard index + 1 < arguments.count else {
            throw ExperimentError.usage
        }
        switch arguments[index] {
        case "--model-output":
            modelOutputURL = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
        case "--model-type":
            guard let parsedKind = ModelKind(rawValue: arguments[index + 1]) else {
                throw ExperimentError.unsupportedModelType(arguments[index + 1])
            }
            modelKind = parsedKind
        default:
            throw ExperimentError.usage
        }
        index += 2
    }
    return (URL(fileURLWithPath: manifestPath).standardizedFileURL,
            modelOutputURL,
            modelKind)
}

private func run() throws {
    let arguments = try parseArguments()
    let manifest = try JSONDecoder().decode(
        ExperimentManifest.self,
        from: Data(contentsOf: arguments.manifestURL)
    )
    guard manifest.schemaVersion == 1 else {
        throw ExperimentError.unsupportedManifestVersion(manifest.schemaVersion)
    }
    guard !manifest.captures.isEmpty else { throw ExperimentError.emptyManifest }

    var captureIDs = Set<String>()
    var capturePaths = Set<String>()
    var examples: [CandidateExample] = []
    var captureReports: [CaptureReport] = []
    var reviewedCandidateCount = 0
    var provisionalCandidateCount = 0
    for spec in manifest.captures {
        guard captureIDs.insert(spec.id).inserted else {
            throw ExperimentError.duplicateCaptureID(spec.id)
        }
        guard let watchID = spec.watchID, !watchID.isEmpty else {
            throw ExperimentError.missingWatchID(spec.id)
        }
        guard let deviceID = spec.deviceID, !deviceID.isEmpty else {
            throw ExperimentError.missingDeviceID(spec.id)
        }
        guard BeatRate.allCases.contains(where: { $0.rawValue == spec.knownBPH }) else {
            throw ExperimentError.unsupportedBPH(spec.knownBPH, spec.id)
        }

        let captureURL = URL(fileURLWithPath: spec.path,
                             relativeTo: arguments.manifestURL.deletingLastPathComponent())
            .standardizedFileURL
        guard capturePaths.insert(captureURL.path).inserted else {
            throw ExperimentError.duplicateCapturePath(captureURL.path)
        }
        let loaded = try loadSamples(from: captureURL, captureID: spec.id)
        let capture = AudioCapture(samples: loaded.samples,
                                   sampleRate: loaded.sampleRate,
                                   routeDescription: spec.id)
        let result = WatchDSP.analyzeAuto(capture: capture)
        let trace = WatchDSP.makeCandidateTrace(capture: capture, result: result)
        let reviewedLabels = try loadReviewedLabels(for: spec,
                                                    manifestURL: arguments.manifestURL)

        var tickCount = 0
        var noiseCount = 0
        var ignoredCount = 0
        let labelingMode: String
        if let reviewedLabels {
            labelingMode = "manual-review-v1"
            let traceEvents = trace.events.reduce(into: [Int: TickCandidateEvent]()) {
                $0[$1.sampleIndex] = $1
            }
            for event in reviewedLabels.events {
                let isTick: Bool
                switch event.reviewedLabel {
                case "tick":
                    tickCount += 1
                    isTick = true
                case "noise":
                    noiseCount += 1
                    isTick = false
                case "unsure", nil:
                    ignoredCount += 1
                    continue
                default:
                    throw ExperimentError.invalidReviewedLabels(
                        "capture \(spec.id) contains an unsupported reviewed label"
                    )
                }
                guard loaded.samples.indices.contains(event.sampleIndex) else {
                    throw ExperimentError.invalidReviewedLabels(
                        "capture \(spec.id) contains an out-of-range sample index"
                    )
                }
                guard let envelope = event.normalizedEnvelope
                    ?? traceEvents[event.sampleIndex]?.normalizedEnvelope else {
                    throw ExperimentError.invalidReviewedLabels(
                        "capture \(spec.id) event \(event.id) has no candidate envelope"
                    )
                }
                let features = TickCandidateFeatureSchema.extract(
                    samples: loaded.samples,
                    sampleRate: loaded.sampleRate,
                    centerIndex: event.sampleIndex,
                    normalizedEnvelope: envelope
                )
                examples.append(CandidateExample(captureID: spec.id,
                                                 watchID: watchID,
                                                 sampleIndex: event.sampleIndex,
                                                 isTick: isTick,
                                                 envelope: envelope,
                                                 features: features))
            }
            reviewedCandidateCount += tickCount + noiseCount
        } else {
            labelingMode = "dsp-grid-v1-provisional-review-required"
            guard result.selectedBPH == spec.knownBPH, result.quality != .low else {
                throw ExperimentError.unusableLabels(
                    "capture \(spec.id) did not recognize its known BPH with usable quality"
                )
            }
            for event in trace.events {
                let isTick: Bool
                switch event.provisionalLabel {
                case .likelyTick:
                    tickCount += 1
                    isTick = true
                case .likelyNoise:
                    noiseCount += 1
                    isTick = false
                case .unknown:
                    ignoredCount += 1
                    continue
                }
                let features = TickCandidateFeatureSchema.extract(
                    samples: loaded.samples,
                    sampleRate: loaded.sampleRate,
                    centerIndex: event.sampleIndex,
                    normalizedEnvelope: event.normalizedEnvelope
                )
                examples.append(CandidateExample(captureID: spec.id,
                                                 watchID: watchID,
                                                 sampleIndex: event.sampleIndex,
                                                 isTick: isTick,
                                                 envelope: event.normalizedEnvelope,
                                                 features: features))
            }
            provisionalCandidateCount += tickCount + noiseCount
        }
        captureReports.append(CaptureReport(id: spec.id,
                                            watchID: watchID,
                                            deviceID: deviceID,
                                            knownBPH: spec.knownBPH,
                                            detectedBPH: result.selectedBPH,
                                            quality: result.quality.rawValue,
                                            sourceCandidateCount: trace.sourceCandidateCount,
                                            mergedCandidateCount: trace.mergedCandidateCount,
                                            exportedEventCount: trace.events.count,
                                            labelingMode: labelingMode,
                                            tickLabelCount: tickCount,
                                            noiseLabelCount: noiseCount,
                                            ignoredLabelCount: ignoredCount))
    }

    let watchIDs = Set(manifest.captures.compactMap(\.watchID)).sorted()
    guard watchIDs.count >= 2 else { throw ExperimentError.insufficientWatches(watchIDs.count) }

    var folds: [FoldReport] = []
    var modelFoldMetrics: [ClassificationMetrics] = []
    var baselineFoldMetrics: [ClassificationMetrics] = []
    for heldOutWatchID in watchIDs {
        let rawTraining = examples.filter { $0.watchID != heldOutWatchID }
        let training = balancedTrainingExamples(rawTraining)
        let testing = examples.filter { $0.watchID == heldOutWatchID }
        guard training.contains(where: \.isTick),
              training.contains(where: { !$0.isTick }),
              testing.contains(where: \.isTick),
              testing.contains(where: { !$0.isTick }) else {
            throw ExperimentError.unusableLabels("watch holdout \(heldOutWatchID) is missing a class")
        }

        let classifier = try trainClassifier(examples: training,
                                             modelKind: arguments.modelKind)
        let modelPredictions = try predictions(from: classifier, examples: testing)
        let labels = testing.map(\.isTick)
        let modelMetrics = ClassificationMetrics(labels: labels,
                                                 predictions: modelPredictions)
        let threshold = bestEnvelopeThreshold(trainingExamples: training)
        let baselineMetrics = ClassificationMetrics(
            labels: labels,
            predictions: testing.map { $0.envelope >= threshold }
        )
        modelFoldMetrics.append(modelMetrics)
        baselineFoldMetrics.append(baselineMetrics)

        let trainingIDs = Set(training.map(\.captureID)).sorted()
        let testingIDs = Set(testing.map(\.captureID)).sorted()
        folds.append(FoldReport(heldOutWatchID: heldOutWatchID,
                                trainingCaptureIDs: trainingIDs,
                                testingCaptureIDs: testingIDs,
                                balancedTrainingExampleCount: training.count,
                                testingExampleCount: testing.count,
                                baselineEnvelopeThreshold: threshold,
                                modelMetrics: modelMetrics,
                                envelopeBaselineMetrics: baselineMetrics))
    }

    let usesOnlyReviewedLabels = reviewedCandidateCount > 0
        && provisionalCandidateCount == 0
    let labelSource: String
    if usesOnlyReviewedLabels {
        labelSource = "manual-review-v1"
    } else if reviewedCandidateCount > 0 {
        labelSource = "mixed-manual-review-and-dsp-provisional"
    } else {
        labelSource = "dsp-grid-v1-provisional-review-required"
    }

    if let modelOutputURL = arguments.modelOutputURL {
        let model = try trainClassifier(examples: balancedTrainingExamples(examples),
                                        modelKind: arguments.modelKind)
        let metadata = MLModelMetadata(
            author: "Chronobeat research",
            shortDescription: "Experimental watch tick candidate verifier. Not production approved.",
            version: "feature-schema-\(TickCandidateFeatureSchema.version)",
            additional: [
                "featureSchemaVersion": String(TickCandidateFeatureSchema.version),
                "labelSource": labelSource,
                "productionEligible": "false"
            ]
        )
        try write(classifier: model, to: modelOutputURL, metadata: metadata)
    }

    let aggregateModel = ClassificationMetrics.aggregate(modelFoldMetrics)
    let aggregateBaseline = ClassificationMetrics.aggregate(baselineFoldMetrics)
    var caveats = [
        "Candidate metrics do not prove that weighted candidates improve Auto-BPH or sec/day accuracy.",
        "The generated model must remain outside the app until it beats DSP-only end-to-end on a frozen held-out benchmark.",
        "The manifest contains \(watchIDs.count) watches, \(Set(manifest.captures.map(\.knownBPH)).count) BPH values, and \(Set(manifest.captures.compactMap(\.deviceID)).count) devices."
    ]
    if provisionalCandidateCount > 0 {
        caveats.append("Provisional labels are DSP grid outputs, not manually reviewed ground truth.")
        caveats.append("Only captures already recognized at their known BPH can produce provisional labels, so those labels cannot measure recovery of failed captures.")
    }
    if reviewedCandidateCount > 0 {
        caveats.append("Manual labels reflect reviewer judgment and still require capture-level held-out validation.")
    }
    let report = ExperimentReport(
        schemaVersion: 2,
        featureSchemaVersion: TickCandidateFeatureSchema.version,
        analysisMode: "leaveOneWatchOutCandidateFeasibility",
        labelSource: labelSource,
        modelType: arguments.modelKind.reportName,
        captureCount: captureReports.count,
        labeledWatchCount: watchIDs.count,
        labeledDeviceCount: Set(manifest.captures.compactMap(\.deviceID)).count,
        labeledCandidateCount: examples.count,
        reviewedCandidateCount: reviewedCandidateCount,
        provisionalCandidateCount: provisionalCandidateCount,
        ignoredCandidateCount: captureReports.reduce(0) { $0 + $1.ignoredLabelCount },
        usesOnlyReviewedLabels: usesOnlyReviewedLabels,
        folds: folds,
        aggregateModelMetrics: aggregateModel,
        aggregateEnvelopeBaselineMetrics: aggregateBaseline,
        modelImprovesF1OverEnvelopeBaseline: aggregateModel.f1 > aggregateBaseline.f1,
        candidateMetricGatePassed: aggregateModel.precision >= 0.98
            && aggregateModel.recall >= 0.90,
        productionEligible: false,
        modelOutputPath: arguments.modelOutputURL?.path,
        caveats: caveats,
        captures: captureReports.sorted { $0.id < $1.id }
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(report))
    FileHandle.standardOutput.write(Data("\n".utf8))
}

do {
    try run()
} catch {
    fputs("Tick candidate ML experiment failed: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
