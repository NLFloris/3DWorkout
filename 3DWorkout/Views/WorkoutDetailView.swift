import SwiftUI

struct WorkoutDetailView: View {
    let session: WorkoutSession
    let healthKitService: HealthKitService

    @StateObject private var viewModel: WorkoutDetailViewModel
    @State private var showCustomization = false

    init(session: WorkoutSession, healthKitService: HealthKitService) {
        self.session = session
        self.healthKitService = healthKitService
        _viewModel = StateObject(wrappedValue: WorkoutDetailViewModel(
            session: session, healthKitService: healthKitService
        ))
    }

    var body: some View {
        Group {
            if viewModel.isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Loading route…")
                        .foregroundStyle(.secondary)
                }
            } else if viewModel.route != nil {
                MapContainerView(viewModel: viewModel)
                    .ignoresSafeArea(edges: .bottom)
            } else if let error = viewModel.errorMessage {
                ContentUnavailableView(
                    "Failed to Load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else {
                ContentUnavailableView(
                    "No GPS Route",
                    systemImage: "location.slash",
                    description: Text("This workout doesn't have GPS route data.")
                )
            }
        }
        .navigationTitle(session.workoutType)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    viewModel.is3DMode.toggle()
                } label: {
                    Label(viewModel.is3DMode ? "2D" : "3D",
                          systemImage: viewModel.is3DMode ? "square.3layers.3d.slash" : "square.3layers.3d")
                }
                .disabled(viewModel.route == nil)

                Button {
                    showCustomization = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .disabled(viewModel.route == nil)
            }
        }
        .sheet(isPresented: $showCustomization) {
            CustomizationView(viewModel: viewModel)
        }
        .task { await viewModel.load() }
    }
}
