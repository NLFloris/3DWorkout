import SwiftUI

/// Bottom sheet that shows the per-unit splits table and the HR zone donut
/// for a workout. Surfaced from the workout detail toolbar.
struct WorkoutStatsSheet: View {
    let session: WorkoutSession
    let route: WorkoutRoute?
    let metrics: WorkoutMetrics?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let route, route.points.count > 1 {
                        SplitsTableView(route: route,
                                        usesPace: session.usesPace)
                    }
                    if let metrics, !metrics.heartRateSamples.isEmpty {
                        HeartRateZoneView(metrics: metrics)
                    }
                    if route == nil && (metrics?.heartRateSamples.isEmpty ?? true) {
                        ContentUnavailableView(
                            "No stats yet",
                            systemImage: "chart.bar.xaxis",
                            description: Text("Splits and zones appear once the route + heart rate have loaded.")
                        )
                        .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Stats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
