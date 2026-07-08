import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = MeasurementViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                header

                Picker("Beat rate", selection: $viewModel.selectedBPH) {
                    ForEach(BeatRate.allCases) { rate in
                        Text(rate.label).tag(rate)
                    }
                }
                .pickerStyle(.menu)
                .disabled(viewModel.isMeasuring)

                content

                Spacer()
            }
            .padding()
            .navigationTitle("Watch Accuracy")
            .onDisappear {
                viewModel.cancelMeasurement()
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
                Task { await viewModel.startMeasurement() }
            }
            .buttonStyle(.borderedProminent)

        case .requestingPermission:
            ProgressView("Requesting microphone permission…")

        case .measuring:
            VStack(spacing: 12) {
                ProgressView(value: viewModel.progress)
                Text("Listening… \(Int(viewModel.elapsedSeconds)) / 60 sec")
                    .font(.title3.monospacedDigit())
                Text("Live level: \(viewModel.liveLevelText)")
                    .foregroundStyle(.secondary)
                Button("Cancel") {
                    viewModel.cancelMeasurement()
                }
                .buttonStyle(.bordered)
            }

        case .analyzing:
            ProgressView("Analyzing ticks…")

        case .result(let result):
            ResultView(result: result) {
                viewModel.reset()
            }

        case .failed(let message):
            VStack(spacing: 16) {
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.red)
                Button("Try again") {
                    viewModel.reset()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct ResultView: View {
    let result: WatchMeasurementResult
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(result.rateText)
                .font(.system(size: 48, weight: .bold, design: .rounded))

            Text("Signal quality: \(result.quality.label)")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Selected beat rate: \(result.selectedBPH) bph")
                Text("Measured beat rate: \(String(format: "%.1f", result.detectedBPH)) bph")
                Text("Valid beats: \(result.validPeakCount)")
                Text("Outlier ratio: \(String(format: "%.1f", result.outlierRatio * 100))%")
            }
            .font(.subheadline.monospacedDigit())
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(result.interpretation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Measure again", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
    }
}
