import Foundation
import AVFoundation

protocol WatchAudioMetering: AnyObject, Sendable {
    var actualSampleRate: Double { get }
    var routeDescription: String { get }
    var routeWarning: String? { get }
    var capturedSampleCount: Int { get }
    var latestLevels: AudioLevelStats { get }

    func requestPermissionIfNeeded() async throws
    func start(liveLevel: @escaping (Float) -> Void) throws
    func stop()
    func stopAndReturnSamples() -> [Float]
}

final class AudioWatchMeter: WatchAudioMetering, @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var tappedInputNode: AVAudioInputNode?
    private var samples: [Float] = []
    private var storedLatestLevels: AudioLevelStats = .empty
    private var lastLiveLevelDeliveryTime: TimeInterval = 0

    private(set) var actualSampleRate: Double = 48_000
    private(set) var routeDescription: String = "Unknown"
    private(set) var routeWarning: String?

    private let liveLevelMinimumInterval: TimeInterval = 0.1

    var latestLevels: AudioLevelStats {
        lock.lock()
        let levels = storedLatestLevels
        lock.unlock()
        return levels
    }

    var capturedSampleCount: Int {
        lock.lock()
        let count = samples.count
        lock.unlock()
        return count
    }

    func requestPermissionIfNeeded() async throws {
        let granted = await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        }

        if !granted {
            throw AudioMeterError.microphonePermissionDenied
        }
    }

    func start(liveLevel: @escaping (Float) -> Void) throws {
        stop()
        resetSamples(reservingCapacity: nil)
        lastLiveLevelDeliveryTime = 0

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.02)
        configurePreferredBuiltInInput(for: session)
        try session.setActive(true)
        configurePreferredBuiltInInput(for: session)

        actualSampleRate = session.sampleRate
        updateRouteInfo(from: session)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        actualSampleRate = format.sampleRate > 0 ? format.sampleRate : session.sampleRate
        resetSamples(reservingCapacity: Int(max(actualSampleRate, 48_000) * 65))

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handle(buffer: buffer, liveLevel: liveLevel)
        }
        tappedInputNode = input
        self.engine = engine

        engine.prepare()
        try engine.start()
    }

    func stop() {
        tappedInputNode?.removeTap(onBus: 0)
        tappedInputNode = nil
        engine?.stop()
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func stopAndReturnSamples() -> [Float] {
        stop()
        lock.lock()
        let copy = samples
        lock.unlock()
        return copy
    }

    private func handle(buffer: AVAudioPCMBuffer, liveLevel: (Float) -> Void) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        let channelCount = max(1, Int(buffer.format.channelCount))
        var sumSquares: Float = 0
        var peak: Float = 0
        var clipped = 0

        lock.lock()
        for i in 0..<frameLength {
            var mixedValue: Float = 0
            for channel in 0..<channelCount {
                mixedValue += channelData[channel][i]
            }
            let value = mixedValue / Float(channelCount)
            samples.append(value)
            sumSquares += value * value
            let magnitude = abs(value)
            peak = max(peak, magnitude)
            if magnitude >= 0.98 {
                clipped += 1
            }
        }

        let now = ProcessInfo.processInfo.systemUptime
        let shouldDeliverLiveLevel = now - lastLiveLevelDeliveryTime >= liveLevelMinimumInterval
        if shouldDeliverLiveLevel {
            lastLiveLevelDeliveryTime = now
        }
        let levels = AudioLevelStats(rmsLevel: Double(sqrt(sumSquares / Float(frameLength))),
                                     peakLevel: Double(peak),
                                     clippingRatio: Double(clipped) / Double(frameLength))
        storedLatestLevels = levels
        lock.unlock()

        let normalizedLevel = min(1, Float(levels.rmsLevel) * 50)
        if shouldDeliverLiveLevel {
            liveLevel(normalizedLevel)
        }
    }

    private func resetSamples(reservingCapacity capacity: Int?) {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        if let capacity {
            samples.reserveCapacity(capacity)
        }
        storedLatestLevels = .empty
        lock.unlock()
    }

    private func configurePreferredBuiltInInput(for session: AVAudioSession) {
        guard let builtInInput = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
            return
        }

        if let dataSource = preferredDataSource(for: builtInInput) {
            try? builtInInput.setPreferredDataSource(dataSource)
        }
        try? session.setPreferredInput(builtInInput)
    }

    private func preferredDataSource(for input: AVAudioSessionPortDescription) -> AVAudioSessionDataSourceDescription? {
        guard let dataSources = input.dataSources, !dataSources.isEmpty else { return nil }

        let preferredNames = ["bottom", "back", "front"]
        for preferredName in preferredNames {
            if let match = dataSources.first(where: { $0.dataSourceName.localizedCaseInsensitiveContains(preferredName) }) {
                return match
            }
        }

        return dataSources.first
    }

    private func updateRouteInfo(from session: AVAudioSession) {
        let inputs = session.currentRoute.inputs
        guard let primaryInput = inputs.first else {
            routeDescription = "No input route"
            routeWarning = "No microphone input route was detected."
            return
        }

        let dataSourceName = primaryInput.selectedDataSource?.dataSourceName
        if let dataSourceName {
            routeDescription = "\(primaryInput.portName) \(dataSourceName) (\(primaryInput.portType.rawValue))"
        } else {
            routeDescription = "\(primaryInput.portName) (\(primaryInput.portType.rawValue))"
        }

        if primaryInput.portType == .builtInMic {
            routeWarning = nil
        } else {
            routeWarning = "Current input is \(primaryInput.portName). Use the built-in iPhone microphone for best results."
        }
    }
}

enum AudioMeterError: LocalizedError {
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access is required to measure watch accuracy. Enable it in Settings."
        }
    }
}
