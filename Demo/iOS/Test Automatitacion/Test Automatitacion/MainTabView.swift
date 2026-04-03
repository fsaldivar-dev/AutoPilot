import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0
    @State private var showNewEntry = false
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                HomeView(showNewEntry: $showNewEntry)
                    .tag(0)

                CaptureView()
                    .tag(1)

                MapExploreView()
                    .tag(2)

                ProfileView()
                    .tag(3)
            }
            .tabViewStyle(.automatic)
            .overlay(alignment: .bottom) {
                customTabBar
            }
        }
        .sheet(isPresented: $showNewEntry) {
            NewEntryView()
        }
    }

    private var customTabBar: some View {
        HStack {
            tabItem(icon: "book.fill", label: "Inicio", tag: 0)
            tabItem(icon: "camera.fill", label: "Capturar", tag: 1)

            // FAB center button
            Button {
                appState.triggerHaptic(.medium)
                showNewEntry = true
            } label: {
                ZStack {
                    Circle()
                        .fill(AppTheme.primaryGradient)
                        .frame(width: 56, height: 56)
                        .shadow(color: AppTheme.primary.opacity(0.4), radius: 8, y: 4)

                    Image(systemName: "plus")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
            .offset(y: -20)

            tabItem(icon: "map.fill", label: "Mapa", tag: 2)
            tabItem(icon: "person.fill", label: "Perfil", tag: 3)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea(edges: .bottom)
                .shadow(color: .black.opacity(0.05), radius: 10, y: -5)
        )
    }

    private func tabItem(icon: String, label: String, tag: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedTab = tag
            }
            appState.triggerSelectionHaptic()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .symbolEffect(.bounce, value: selectedTab == tag)

                Text(label)
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(selectedTab == tag ? AppTheme.primary : AppTheme.lightText)
            .frame(maxWidth: .infinity)
        }
    }
}
