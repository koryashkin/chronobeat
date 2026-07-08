import Foundation
import AVFoundation

final class AudioWatchMeter {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var liveLevelCallback: ((Float) -> Void)?

    private(set) var actualSampleRate: Double = 48_000

    func requestPermissionIfNeeded() async throws {
        let granted = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }

        if !granted {
            throw AudioMeterError.microphonePermissionDenied
        }
    }

    func start(liveLevel: @escaping (Float) -> Void) throws {
        liveLevelCallback = liveLevel
        samples.removeAll(keepingCapacity: true)

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)

        actualSampleRate = session.sampleRate

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func stopAndReturnSamples() -> [Float] {
        stop()
        lock.lock()
        let copy = samples
        lock.unlock()
        return copy
    }

    private func handle(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        let firstChannel = channelData[0]
        var chunk = [Float]()
        chunk.reserveCapacity(frameLength)

        var sumSquares: Float = 0
        for i in 0..<frameLength {
            let value = firstChannel[i]
            chunk.append(value)
            sumSquares += value * value
        }

        let rms = sqrt(sumSquares / Float(frameLength))
        let normalizedLevel = min(1, rms * 50)
        liveLevelCallback?(normalizedLevel)

        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
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
