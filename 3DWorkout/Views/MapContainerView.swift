import SwiftUI

struct MapContainerView: View {
    @ObservedObject var viewModel: WorkoutDetailViewModel
    @State private var showElevation = true

    var body: some View {
        ZStack {
            AnimatedMapView(viewModel: viewModel)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Metrics HUD — floats at the top
                HStack {
                    Spacer()
                    MetricsOverlayView(viewModel: viewModel)
                    Spacer()
                }
                .padding(.top, 8)
                .padding(.horizontal)

                Spacer()

                // Bottom stack — elevation profile + playback controls
                VStack(spacing: 10) {
                    if showElevation {
                        ElevationProfileView(viewModel: viewModel)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                            )
                            .shadow(color: .black.opacity(0.18), radius: 20, y: 6)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    PlaybackPanel(viewModel: viewModel, showElevation: $showElevation)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }
}

// MARK: - Playback Panel

private struct PlaybackPanel: View {
    @ObservedObject var viewModel: WorkoutDetailViewModel
    @ObservedObject var animator: RouteAnimator
    @Binding var showElevation: Bool

    init(viewModel: WorkoutDetailViewModel, showElevation: Binding<Bool>) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._animator = ObservedObject(wrappedValue: viewModel.animator)
        self._showElevation = showElevation
    }

    var body: some View {
        VStack(spacing: 12) {
            // Progress scrubber
            HStack(spacing: 10) {
                Text(elapsedLabel)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)

                ProgressScrubber(progress: Binding(
                    get: { animator.progress },
                    set: { animator.seek(to: $0) }
                ))

                Text(totalLabel)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .leading)
            }

            // Control buttons — play stays centered, leading/trailing groups balance it
            HStack(alignment: .center) {
                HStack(spacing: 12) {
                    // Stop
                    CircleButton(icon: "stop.fill", size: 36, tint: .secondary) {
                        animator.stop()
                    }
                    // Elevation profile toggle
                    CircleButton(
                        icon: "chart.xyaxis.line",
                        size: 36,
                        tint: showElevation ? .red : .secondary
                    ) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            showElevation.toggle()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Play / Pause (hero button)
                CircleButton(
                    icon: animator.isPlaying ? "pause.fill" : "play.fill",
                    size: 56,
                    tint: .white,
                    fill: .red
                ) {
                    animator.isPlaying ? animator.pause() : animator.play()
                }

                // Speed
                Button {
                    viewModel.cycleSpeed()
                } label: {
                    Text(viewModel.animationSpeed.displayName)
                        .font(.system(.callout, design: .rounded).bold())
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .background(.quaternary, in: Circle())
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 20, y: 6)
    }

    private var elapsedLabel: String {
        guard let route = viewModel.route, !route.points.isEmpty else { return "0:00" }
        let idx = animator.currentPointIndex
        let t = route.points[idx].timestamp.timeIntervalSince(route.points[0].timestamp)
        return format(t)
    }

    private var totalLabel: String {
        guard let route = viewModel.route, route.points.count > 1 else { return "0:00" }
        let t = route.points.last!.timestamp.timeIntervalSince(route.points.first!.timestamp)
        return format(t)
    }

    private func format(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Supporting components

private struct ProgressScrubber: View {
    @Binding var progress: Double
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(.secondary.opacity(0.25))
                    .frame(height: 4)

                // Fill
                Capsule()
                    .fill(Color.red.gradient)
                    .frame(width: geo.size.width * progress, height: 4)

                // Thumb
                Circle()
                    .fill(.white)
                    .frame(width: isDragging ? 18 : 12, height: isDragging ? 18 : 12)
                    .shadow(radius: 2)
                    .offset(x: geo.size.width * progress - (isDragging ? 9 : 6))
                    .animation(.spring(response: 0.2), value: isDragging)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        isDragging = true
                        progress = max(0, min(1, v.location.x / geo.size.width))
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .frame(height: 20)
    }
}

private struct CircleButton: View {
    let icon: String
    let size: CGFloat
    let tint: Color
    var fill: Color = .clear
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if fill != .clear {
                    Circle().fill(fill.gradient)
                        .frame(width: size, height: size)
                        .shadow(color: fill.opacity(0.4), radius: 8, y: 3)
                }
                Image(systemName: icon)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
    }
}
