import SwiftUI

struct RootTabView: View {
    @State private var selection: Tab = .home
    @State private var exploreCategory: String? = nil

    enum Tab: Hashable { case home, explore, favorites, profile }

    var body: some View {
        TabView(selection: $selection) {
            NavigationRouter { HomeView() }
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(Tab.home)

            NavigationRouter { ExploreView(initialCategory: $exploreCategory) }
                .tabItem { Label("Explore", systemImage: "square.grid.2x2.fill") }
                .tag(Tab.explore)

            NavigationRouter { FavoritesView() }
                .tabItem { Label("Favorites", systemImage: "heart.fill") }
                .tag(Tab.favorites)

            NavigationRouter { ProfileView() }
                .tabItem { Label("Profile", systemImage: "person.fill") }
                .tag(Tab.profile)
        }
        .tint(Color.brand)
    }
}

private struct NavigationRouter<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            content()
                .navigationDestination(for: SkillRoute.self) { route in
                    switch route {
                    case .detail(let id):
                        SkillDetailView(skillId: id)
                    case .allNew:
                        NewSkillsView()
                    }
                }
                .toolbarBackground(Color.bg, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
        .tint(Color.brand)
    }
}
