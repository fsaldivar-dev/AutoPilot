import SwiftUI
import MapKit

struct MapExploreView: View {
    @Environment(AppState.self) private var appState
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedEntry: JournalEntry?
    @State private var mapStyle: MapStyleOption = .standard
    @State private var showEntryDetail = false

    enum MapStyleOption: String, CaseIterable {
        case standard = "Estandar"
        case satellite = "Satelite"
        case hybrid = "Hibrido"
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topTrailing) {
                Map(position: $cameraPosition, selection: $selectedEntry) {
                    ForEach(appState.entries.filter { $0.coordinate != nil }) { entry in
                        Annotation(entry.title, coordinate: entry.coordinate!) {
                            mapPin(for: entry)
                        }
                        .tag(entry)
                    }

                    UserAnnotation()
                }
                .mapStyle(currentMapStyle)
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                    MapScaleView()
                }

                // Map style toggle
                VStack(spacing: 8) {
                    Picker("Estilo", selection: $mapStyle) {
                        ForEach(MapStyleOption.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                // Stats overlay
                VStack {
                    Spacer()
                    statsOverlay
                }
            }
            .navigationTitle("Mapa")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: selectedEntry) { _, entry in
                if entry != nil {
                    showEntryDetail = true
                    appState.triggerSelectionHaptic()
                }
            }
            .sheet(isPresented: $showEntryDetail) {
                selectedEntry = nil
            } content: {
                if let entry = selectedEntry {
                    NavigationStack {
                        EntryDetailView(entry: entry)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Cerrar") {
                                        showEntryDetail = false
                                    }
                                }
                            }
                    }
                    .presentationDetents([.medium, .large])
                }
            }
        }
    }

    private var currentMapStyle: MapStyle {
        switch mapStyle {
        case .standard: return .standard
        case .satellite: return .imagery
        case .hybrid: return .hybrid
        }
    }

    // MARK: - Map Pin

    private func mapPin(for entry: JournalEntry) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(entry.category.color)
                    .frame(width: 36, height: 36)
                    .shadow(color: entry.category.color.opacity(0.4), radius: 4, y: 2)

                Image(systemName: entry.category.icon)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
            }

            Image(systemName: "triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(entry.category.color)
                .rotationEffect(.degrees(180))
                .offset(y: -3)
        }
    }

    // MARK: - Stats Overlay

    private var statsOverlay: some View {
        HStack(spacing: 20) {
            statItem(
                icon: "mappin.circle.fill",
                value: "\(appState.entries.filter { $0.coordinate != nil }.count)",
                label: "Lugares"
            )
            statItem(
                icon: "globe.americas.fill",
                value: "\(appState.uniqueLocations)",
                label: "Ciudades"
            )
            statItem(
                icon: "heart.fill",
                value: "\(appState.favoriteEntries.count)",
                label: "Favoritos"
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding()
        .padding(.bottom, 70)
    }

    private func statItem(icon: String, value: String, label: String) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(AppTheme.primary)
                Text(value)
                    .font(.headline)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

