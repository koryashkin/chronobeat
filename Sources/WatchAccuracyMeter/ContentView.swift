import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = MeasurementViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header

                    Picker("Beat rate", selection: $viewModel.selectedBPH) {
                        ForEach(BeatRateSelection.allCases) { selection in
                            Text(selection.label).tag(selection)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!viewModel.canEditBeatRate)
                    .accessibilityIdentifier("beatRatePicker")

                    content

                    Spacer(minLength: 0)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .navigationTitle("Watch Accuracy")
            .onDisappear {
                viewModel.cancelMeasurement()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase != .active else { return }
                viewModel.stopForInactiveScene()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Place your watch near the iPhone microphone.")
                .font(.headline)
            Text("Use a quiet room. Keep the watch still. Audio is processed only on this device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            Button("Start 60 sec measurement") {
                viewModel.startMeasurement()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("startMeasurementButton")

        case .requestingPermission:
            ProgressView("Requesting microphone permission…")
                .accessibilityIdentifier("requestingPermissionView")

        case .measuring:
            VStack(spacing: 12) {
                ProgressView(value: viewModel.progress)
                    .accessibilityIdentifier("measurementProgress")
                Text("Listening… \(Int(viewModel.elapsedSeconds)) / 60 sec")
                    .font(.title3.monospacedDigit())
                CaptureStatusView(isReceivingAudio: viewModel.isReceivingAudio,
                                  capturedAudioSeconds: viewModel.capturedAudioSeconds,
                                  capturedSampleCount: viewModel.capturedSampleCount)
                if let routeWarning = viewModel.routeWarning {
                    Text(routeWarning)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
                Button("Cancel") {
                    viewModel.cancelMeasurement()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("cancelMeasurementButton")
            }
            .accessibilityIdentifier("measuringView")

        case .analyzing:
            ProgressView("Analyzing ticks…")
                .accessibilityIdentifier("analyzingView")

        case .result(let result):
            ResultView(result: result,
                       exportURL: viewModel.latestExportURL,
                       exportStatusText: viewModel.exportStatusText,
                       onExport: {
                viewModel.exportLastMeasurement()
            }, onRetry: {
                viewModel.reset()
            })
            .accessibilityIdentifier("resultView")

        case .failed(let message):
            VStack(spacing: 16) {
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.red)
                Button("Try again") {
                    viewModel.reset()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("tryAgainButton")
            }
        }
    }
}

struct CaptureStatusView: View {
    let isReceivingAudio: Bool
    let capturedAudioSeconds: Double
    let capturedSampleCount: Int

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isReceivingAudio ? .green.opacity(0.18) : .secondary.opacity(0.14))
                    .frame(width: 36, height: 36)
                Image(systemName: isReceivingAudio ? "waveform" : "mic.slash")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isReceivingAudio ? .green : .secondary)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(isReceivingAudio ? "Receiving microphone audio" : "Waiting for microphone audio")
                    .font(.subheadline.weight(.semibold))
                Text("\(String(format: "%.1f", capturedAudioSeconds)) sec recorded · \(capturedSampleCount.formatted()) samples")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("audioCaptureStatus")
    }
}

struct ResultView: View {
    let result: WatchMeasurementResult
    let exportURL: URL?
    let exportStatusText: String?
    let onExport: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(primaryResultText)
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)

            Text("Signal quality: \(result.quality.label)")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                if result.isAutoBPH {
                    Text("Beat rate mode: Auto")
                    Text("Detected beat rate: \(result.selectedBPH.formatted()) bph")
                } else {
                    Text("Selected beat rate: \(result.selectedBPH.formatted()) bph")
                }
                if result.quality != .low {
                    Text("Measured beat rate: \(String(format: "%.1f", result.detectedBPH)) bph")
                }
                Text("Quality score: \(String(format: "%.0f", result.qualityScore)) / 100")
                Text("Candidate ticks: \(result.detectedPeakCount)")
                Text("Valid beats: \(result.validPeakCount)")
                Text("Expected ticks: \(result.expectedTickCount)")
                Text("Beat coverage: \(String(format: "%.1f", result.beatCoverage * 100))%")
                Text("Outlier ratio: \(String(format: "%.1f", result.outlierRatio * 100))%")
                Text("Periodicity: \(String(format: "%.2f", result.periodicityScore))")
                Text("Recognition confidence: \(String(format: "%.1f", result.recognitionConfidence * 100))%")
                Text("Tick recall estimate: \(String(format: "%.1f", result.tickRecallEstimate * 100))%")
                Text("Windows: \(result.successfulWindowCount) / \(result.analysisWindowCount)")
                if let issue = result.dominantFailureReason {
                    Text("Issue: \(issue.label)")
                }
                Text("Threshold scale: \(String(format: "%.2f", result.chosenThresholdScale))")
                Text("RMS level: \(String(format: "%.6f", result.rmsLevel))")
                Text("Peak level: \(String(format: "%.6f", result.peakLevel))")
                Text("Clipping: \(String(format: "%.3f", result.clippingRatio * 100))%")
                Text("Estimated SNR: \(String(format: "%.1f", result.estimatedSnrDb)) dB")
                Text("Detection threshold: \(String(format: "%.6f", result.detectionThreshold))")
                Text("Envelope median: \(String(format: "%.6f", result.envelopeMedian))")
                Text("Envelope p95: \(String(format: "%.6f", result.envelopeP95))")
                Text("Sample rate: \(String(format: "%.0f", result.sampleRate)) Hz")
                Text("Captured samples: \(result.sampleCount)")
                Text("Input route: \(result.routeDescription)")
            }
            .font(.subheadline.monospacedDigit())
            .frame(maxWidth: .infinity, alignment: .leading)

            if let routeWarning = result.routeWarning {
                Text(routeWarning)
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(result.interpretation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Measure again", action: onRetry)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("measureAgainButton")

            VStack(spacing: 8) {
                Button {
                    onExport()
                } label: {
                    Label("Export debug capture", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("exportDebugCaptureButton")

                if let exportStatusText {
                    Text(exportStatusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Share exported folder", systemImage: "folder")
                    }
                    .font(.footnote)
                }
            }
        }
    }

    private var primaryResultText: String {
        if result.quality == .low {
            return "Retry needed"
        }
        return result.rateText
    }
}
