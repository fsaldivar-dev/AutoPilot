import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Binding var showNewEntry: Bool
    @State private var showFavoritesOnly = false

    var body: some View {
        @Bindable var appState = appState

        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Category filter chips
                    categoryFilterSection

                    // Favorites toggle
                    Toggle(isOn: $showFavoritesOnly) {
                        Label("Solo favoritos", systemImage: "heart.fill")
                            .font(.subheadline.weight(.medium))
                    }
                    .tint(AppTheme.primary)
                    .padding(.horizontal)

                    // Entries list
                    let displayEntries = showFavoritesOnly ? appState.filteredEntries.filter(\.isFavorite) : appState.filteredEntries

                    if displayEntries.isEmpty {
                        emptyStateView
                    } else {
                        LazyVStack(spacing: 16) {
                            ForEach(Array(displayEntries.enumerated()), id: \.element.id) { index, entry in
                                NavigationLink(destination: EntryDetailView(entry: entry)) {
                                    if index == 0 {
                                        heroEntryCard(entry)
                                    } else {
                                        compactEntryCard(entry)
                                    }
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        appState.toggleFavorite(entry)
                                    } label: {
                                        Label(
                                            entry.isFavorite ? "Quitar favorito" : "Favorito",
                                            systemImage: entry.isFavorite ? "heart.slash" : "heart"
                                        )
                                    }

                                    Button {
                                        let text = "\(entry.title) - \(entry.locationName)"
                                        appState.copyToClipboard(text)
                                    } label: {
                                        Label("Copiar", systemImage: "doc.on.doc")
                                    }

                                    Divider()

                                    Button(role: .destructive) {
                                        appState.deleteEntry(entry)
                                    } label: {
                                        Label("Eliminar", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.bottom, 100)
            }
            .refreshable {
                try? await Task.sleep(for: .seconds(1))
            }
            .navigationTitle("Mis Viajes")
            .searchable(text: $appState.searchText, prompt: "Buscar destinos, experiencias...")
        }
    }

    // MARK: - Category Filter

    private var categoryFilterSection: some View {
        @Bindable var appState = appState

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                categoryChip(nil, label: "Todos", icon: "globe")

                ForEach(TravelCategory.allCases) { category in
                    categoryChip(category, label: category.rawValue, icon: category.icon)
                }
            }
            .padding(.horizontal)
        }
    }

    private func categoryChip(_ category: TravelCategory?, label: String, icon: String) -> some View {
        let isSelected = appState.selectedCategory == category

        return Button {
            withAnimation(.spring(response: 0.3)) {
                appState.selectedCategory = category
            }
            appState.triggerSelectionHaptic()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                Text(label)
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                isSelected
                    ? AnyShapeStyle(AppTheme.primaryGradient)
                    : AnyShapeStyle(Color(.systemGray6))
            )
            .foregroundStyle(isSelected ? .white : AppTheme.darkText)
            .clipShape(Capsule())
        }
    }

    // MARK: - Hero Card

    private func heroEntryCard(_ entry: JournalEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top gradient with category
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            colors: [entry.category.color, entry.category.color.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 160)
                    .overlay(alignment: .topTrailing) {
                        if entry.isFavorite {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(.white)
                                .padding(12)
                        }
                    }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: entry.category.icon)
                        Text(entry.category.rawValue)
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(.white.opacity(0.9))

                    Text(entry.title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                }
                .padding(16)
            }

            // Bottom info
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack {
                    Label(entry.locationName, systemImage: "mappin")
                    Spacer()
                    Text(entry.moodEmoji)
                        .font(.title3)
                    Text(entry.formattedDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .cardStyle()
    }

    // MARK: - Compact Card

    private func compactEntryCard(_ entry: JournalEntry) -> some View {
        HStack(spacing: 14) {
            // Category icon
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(entry.category.color.opacity(0.15))
                    .frame(width: 50, height: 50)

                Image(systemName: entry.category.icon)
                    .font(.title3)
                    .foregroundStyle(entry.category.color)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.darkText)
                        .lineLimit(1)

                    Spacer()

                    if entry.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(AppTheme.primary)
                    }
                }

                HStack(spacing: 12) {
                    Label(entry.locationName, systemImage: "mappin")
                    Spacer()
                    Text(entry.moodEmoji)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.quaternary)
        }
        .padding(14)
        .cardStyle()
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "airplane.departure")
                .font(.system(size: 50))
                .foregroundStyle(AppTheme.lightText)

            Text("No hay viajes aun")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.darkText)

            Text("Empieza a documentar tus aventuras")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                showNewEntry = true
            } label: {
                Label("Crear primera entrada", systemImage: "plus.circle.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 40)
        }
        .padding(.top, 60)
    }
}
