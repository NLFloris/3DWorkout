import SwiftUI

struct WorkoutDetailView: View {
    let session: WorkoutSession
    let healthKitService: HealthKitService
    let store: WorkoutStore

    @EnvironmentObject var settings: AppSettings
    @StateObject private var viewModel: WorkoutDetailViewModel
    @State private var showCustomization = false
    @State private var showVideoExport = false

    init(session: WorkoutSession,
         healthKitService: HealthKitService,
         store: WorkoutStore,
         settings: AppSettings) {
        self.session = session
        self.healthKitService = healthKitService
        self.store = store
        _viewModel = StateObject(wrappedValue: WorkoutDetailViewModel(
            session: session,
            healthKitService: healthKitService,
            store: store,
            settings: settings
        ))
    }

    var body: some View {
        Group {
            if viewModel.isLoading {
                loadingState
            } else if viewModel.route != nil {
                MapContainerView(viewModel: viewModel)
                    .ignoresSafeArea(edges: .bottom)
            } else if let error = viewModel.errorMessage {
                ContentUnavailableView(
                    "Load Failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else {
                ContentUnavailableView(
                    "No GPS Route",
                    systemImage: "location.slash",
                    description: Text("This workout doesn't have GPS route data recorded by Apple Watch.")
                )
            }
        }
        .navigationTitle(session.workoutType)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        viewModel.is3DMode.toggle()
                    }
                } label: {
                    Label(
                        viewModel.is3DMode ? "Switch to 2D" : "Switch to 3D",
                        systemImage: viewModel.is3DMode ? "square.2.layers.3d" : "square.3.layers.3d"
                    )
                    .labelStyle(.iconOnly)
                    .contentTransition(.symbolEffect(.replace))
                }
                .disabled(viewModel.route == nil)

                Button {
                    showVideoExport = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
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
                .environmentObject(settings)
        }
        .sheet(isPresented: $showVideoExport) {
            VideoExportView(detail: viewModel, units: settings.units)
                .environmentObject(settings)
        }
        .task { await viewModel.load() }
    }

    private var loadingState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(.red.opacity(0.1))
                    .frame(width: 80, height: 80)
                ProgressView()
                    .scaleEffect(1.4)
                    .tint(.red)
            }
            Text("Loading route…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}
