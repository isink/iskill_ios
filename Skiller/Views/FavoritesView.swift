import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject private var favoriteSync: FavoriteSyncCoordinator
    @State private var skills: [Skill] = []
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            if favoriteSync.lastSyncError != nil, favoriteSync.isReady {
                syncErrorBanner
            }

            Group {
                if !favoriteSync.isReady || loading {
                    skeletons
                } else if favoriteSync.favoriteIDs.isEmpty {
                    EmptyState(
                        icon: "heart",
                        title: "No favorites yet",
                        subtitle: "Tap the heart icon on a skill page to favorite it"
                    )
                } else {
                    skillList
                }
            }
        }
        .background(Color.bg.ignoresSafeArea())
        .navigationTitle("Favorites")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.bg, for: .navigationBar)
        .task(id: favoriteSync.favoriteIDs) { await loadSkills() }
        .task { await favoriteSync.sync() }
    }

    private var skeletons: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in SkillCardSkeleton() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
    }

    private var skillList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(skills) { SkillCard(skill: $0) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .refreshable {
            await favoriteSync.sync()
            await loadSkills()
        }
    }

    private var syncErrorBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.icloud")
                .foregroundStyle(Color.brand)
            Text("Some favorites are waiting to sync")
                .font(.system(size: 12))
                .foregroundStyle(Color.textMuted)
            Spacer(minLength: 0)
            Button("Retry sync") {
                Task { await favoriteSync.sync() }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.brand)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.bgCard)
    }

    @MainActor
    private func loadSkills() async {
        let ids = favoriteSync.favoriteIDs.sorted()
        loading = true
        defer { loading = false }

        let loaded = await withTaskGroup(of: Skill?.self, returning: [Skill].self) { group in
            for id in ids {
                group.addTask { try? await SkillsAPI.fetchSkillById(id) }
            }

            var result: [Skill] = []
            for await skill in group {
                if let skill { result.append(skill) }
            }
            return result
        }

        guard !Task.isCancelled, ids == favoriteSync.favoriteIDs.sorted() else { return }
        let byID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        skills = ids.compactMap { byID[$0] }
    }
}
