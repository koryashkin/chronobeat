import Foundation
import AVFoundation

protocol WatchAudioMetering: AnyObject, Sendable {
    var actualSampleRate: Double { get }
    var routeDescription: String { get }
    var routeWarning: String? { get }
    var captureFailure: AudioMeterError? { get }
    var capturedSampleCount: Int { get }
    var latestLevels: AudioLevelStats { get }
    var peakLevelSinceStart: Double { get }

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
    private var storedPeakLevelSinceStart: Double = 0
    private var storedCaptureFailure: AudioMeterError?
    private var lastLiveLevelDeliveryTime: TimeInterval = 0
    private var notificationObservers: [NSObjectProtocol] = []

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

    var captureFailure: AudioMeterError? {
        lock.lock()
        let failure = storedCaptureFailure
        lock.unlock()
        return failure
    }

    var capturedSampleCount: Int {
        lock.lock()
        let count = samples.count
        lock.unlock()
        return count
    }

    var peakLevelSinceStart: Double {
        lock.lock()
        let peakLevel = storedPeakLevelSinceStart
        lock.unlock()
        return peakLevel
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
        lastLiveLevelDeliveryTime = 0

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.02)
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
        registerRouteChangeObservers(engine: engine,
                                     expectedRoute: inputRouteIdentity(from: session))
    }

    func stop() {
        unregisterRouteChangeObservers()
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

        var sumSquares: Float = 0
        var peak: Float = 0
        var clipped = 0

        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        for i in 0..<frameLength {
            let value = channelData[0][i]
            if samples.count < samples.capacity {
                samples.append(value)
            }
            sumSquares += value * value
            let magnitude = abs(value)
            peak = max(peak, magnitude)
            if magnitude >= 0.98 {
                clipped += 1
            }
        }

        let shouldDeliverLiveLevel = now - lastLiveLevelDeliveryTime >= liveLevelMinimumInterval
        if shouldDeliverLiveLevel {
            lastLiveLevelDeliveryTime = now
        }
        let levels = AudioLevelStats(rmsLevel: Double(sqrt(sumSquares / Float(frameLength))),
                                     peakLevel: Double(peak),
                                     clippingRatio: Double(clipped) / Double(frameLength))
        storedLatestLevels = levels
        storedPeakLevelSinceStart = max(storedPeakLevelSinceStart, levels.peakLevel)
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
        storedPeakLevelSinceStart = 0
        storedCaptureFailure = nil
        lock.unlock()
    }

    private func registerRouteChangeObservers(
        engine: AVAudioEngine,
        expectedRoute: AudioInputRouteIdentity?
    ) {
        unregisterRouteChangeObservers()

        let center = NotificationCenter.default
        let routeObserver = center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                               object: nil,
                                               queue: nil) { [weak self] _ in
            self?.validateCaptureRoute(expectedRoute: expectedRoute, event: .route)
        }
        let engineObserver = center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                object: engine,
                                                queue: nil) { [weak self] _ in
            self?.validateCaptureRoute(expectedRoute: expectedRoute, event: .engineConfiguration)
        }
        notificationObservers = [routeObserver, engineObserver]
    }

    private func validateCaptureRoute(
        expectedRoute: AudioInputRouteIdentity?,
        event: AudioCaptureChangeEvent
    ) {
        let session = AVAudioSession.sharedInstance()
        let currentRoute = inputRouteIdentity(from: session)
        guard AudioCaptureRouteChangePolicy.shouldFailCapture(expectedRoute: expectedRoute,
                                                              currentRoute: currentRoute,
                                                              engineIsRunning: engine?.isRunning ?? false,
                                                              event: event) else {
            return
        }
        markCaptureFailure(.routeChangedDuringCapture)
    }

    private func unregisterRouteChangeObservers() {
        let observers = notificationObservers
        notificationObservers.removeAll()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func markCaptureFailure(_ failure: AudioMeterError) {
        lock.lock()
        storedCaptureFailure = failure
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

    private func inputRouteIdentity(from session: AVAudioSession) -> AudioInputRouteIdentity? {
        guard let input = session.currentRoute.inputs.first else { return nil }
        return AudioInputRouteIdentity(portUID: input.uid,
                                       portType: input.portType.rawValue)
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

struct AudioInputRouteIdentity: Equatable, Sendable {
    let portUID: String
    let portType: String
}

enum AudioCaptureChangeEvent: Sendable {
    case route
    case engineConfiguration
}

enum AudioCaptureRouteChangePolicy {
    static func shouldFailCapture(
        expectedRoute: AudioInputRouteIdentity?,
        currentRoute: AudioInputRouteIdentity?,
        engineIsRunning: Bool,
        event: AudioCaptureChangeEvent
    ) -> Bool {
        guard let expectedRoute,
              let currentRoute else {
            return true
        }
        guard expectedRoute == currentRoute else { return true }

        switch event {
        case .route:
            return false
        case .engineConfiguration:
            return !engineIsRunning
        }
    }
}

enum AudioMeterError: LocalizedError {
    case microphonePermissionDenied
    case unsupportedInputRoute(String)
    case inputTooQuiet
    case routeChangedDuringCapture

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access is required to measure watch accuracy. Enable it in Settings."
        case .unsupportedInputRoute(let routeWarning):
            return routeWarning
        case .inputTooQuiet:
            return "The tick signal is too quiet. Put the watch caseback directly against the bottom microphone and try again."
        case .routeChangedDuringCapture:
            return "The microphone route changed during capture. Use the built-in iPhone microphone and start again."
        }
    }
}
