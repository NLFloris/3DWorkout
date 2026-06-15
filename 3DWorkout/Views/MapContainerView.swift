import SwiftUI

struct MapContainerView: View {
    @ObservedObject var viewModel: WorkoutDetailViewModel

    var body: some View {
        ZStack(alignment: .bottom) {
            AnimatedMapView(viewModel: viewModel)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Live metrics HUD top-left
                HStack {
                    MetricsOverlayView(viewModel: viewModel)
                        .padding(.horizontal)
                        .padding(.top, 8)
                    Spacer()
                }

                Spacer()

                // Playback controls at the bottom
                PlaybackControlsView(viewModel: viewModel)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .background(.ultraThinMaterial)
            }
        }
    }
}

// MARK: - Playback Controls

private struct PlaybackControlsView: View {
    @ObservedObject var viewModel: WorkoutDetailViewModel

    var body: some View {
        VStack(spacing: 8) {
            // Progress bar + time labels
            HStack {
                Text(elapsedTimeLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { viewModel.animator.progress },
                        set: { viewModel.animator.seek(to: $0) }
                    )
                )
                Text(totalTimeLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            // Buttons row
            HStack(spacing: 24) {
                // Stop / rewind
                Button {
                    viewModel.animator.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.title3)
                }
                .foregroundStyle(.secondary)

                Spacer()

                // Play / Pause
                Button {
                    viewModel.animator.isPlaying
                        ? viewModel.animator.pause()
                        : viewModel.animator.play()
                } label: {
                    Image(systemName: viewModel.animator.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.red)
                }

                Spacer()

                // Speed cycle
                Button {
                    viewModel.cycleSpeed()
                } label: {
                    Text(viewModel.animationSpeed.displayName)
                        .font(.callout.bold())
                        .foregroundStyle(.primary)
                        .frame(width: 40)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
    }

    private var elapsedTimeLabel: String {
        guard let route = viewModel.route, !route.points.isEmpty else { return "0:00" }
        let idx = viewModel.animator.currentPointIndex
        let elapsed = route.points[idx].timestamp.timeIntervalSince(route.points[0].timestamp)
        return formatTime(elapsed)
    }

    private var totalTimeLabel: String {
        guard let route = viewModel.route, route.points.count > 1 else { return "0:00" }
        let total = route.points.last!.timestamp.timeIntervalSince(route.points.first!.timestamp)
        return formatTime(total)
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}
