import SwiftUI

struct HomeView: View {
    @State private var query = ""
    @State private var debouncedQuery = ""
    @State private var fresh: [Skill] = []
    @State private var stats: HomeStats? = nil
    @State private var results: [Skill] = []
    @State private var loading = true
    @State private var loadError = false

    var body: some View {
        Group {
            if showingSearch { searchScreen } else { feedScreen }
        }
        .background(Color.bg.ignoresSafeArea())
        .navigationBarHidden(true)
        .task { await loadHome() }
        .onChange(of: query) { _, new in
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if new == query { debouncedQuery = new }
            }
        }
        .onChange(of: debouncedQuery) { _, new in
            Task { results = (try? await SkillsAPI.searchSkills(new)) ?? [] }
        }
    }

    private var showingSearch: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Feed (no search)
    private var feedScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                banner.padding(.bottom, 20)
                if loading {
                    newSectionLoading
                } else if loadError {
                    newSectionError
                } else if !fresh.isEmpty {
                    newSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .refreshable { await loadHome(refresh: true) }
    }

    // MARK: Search
    private var searchScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                banner
                Text("Found \(results.count) results for \"\(query)\"")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textMuted)
                if results.isEmpty {
                    EmptyState(icon: "magnifyingglass", title: "No matching results", subtitle: "Try other keywords")
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(results) { SkillCard(skill: $0) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Banner
    private var banner: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skiller")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Color.textPrimary)
                    Text("Discover quality Claude skills")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textSubtle)
                }
                Spacer()
                if let last = stats?.lastSyncAt {
                    HStack(spacing: 4) {
                        Circle().fill(Color.accentGreen).frame(width: 6, height: 6)
                        Text("Updated \(Format.timeAgoShort(last))")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.textSubtle)
                    }
                }
            }

            HStack(spacing: 12) {
                StatCard(
                    icon: "square.grid.2x2",
                    value: stats.map { "\($0.total)" } ?? "—",
                    label: "Total skills",
                    fullWidth: !(stats.map { $0.newToday > 0 } ?? false)
                )
                if let s = stats, s.newToday > 0 {
                    StatCard(icon: "bolt.fill", value: "+\(s.newToday)", label: "New today", accent: true)
                }
            }

            SearchBar(text: $query, placeholder: "Search skills, tags, authors")
        }
    }

    // MARK: New section
    private var newSectionHeader: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.brand)
                Text("Latest")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.textPrimary)
            }
            Spacer()
            NavigationLink(value: SkillRoute.allNew) {
                HStack(spacing: 2) {
                    Text("More").font(.system(size: 12)).foregroundStyle(Color.textSubtle)
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Color.textSubtle)
                }
            }.buttonStyle(.plain)
        }
    }

    private var newSectionLoading: some View {
        VStack(alignment: .leading, spacing: 12) {
            newSectionHeader
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.bgElevated)
                            .frame(width: 168, height: 196)
                    }
                }
            }
        }
    }

    private var newSectionError: some View {
        VStack(alignment: .leading, spacing: 12) {
            newSectionHeader
            VStack(spacing: 12) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.textMuted)
                Text("Loading failed, check your network")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textMuted)
                Button {
                    Task { await loadHome() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12))
                        Text("Retry").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.brand)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(Color.bgCard)
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.borderSubtle, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private var newSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            newSectionHeader
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(fresh.prefix(10)) { skill in
                        HotSkillCard(
                            skill: skill,
                            kicker: "@\(Format.author(skill.author)) · \(Format.timeAgo(skill.publishedAt ?? skill.createdAt))"
                        )
                    }
                }
            }
        }
    }

    // MARK: Loading
    @MainActor
    private func loadHome(refresh: Bool = false) async {
        if refresh { await SkillsCache.shared.clear() }
        loadError = false

        let cache = SkillsCache.shared
        let (sStale, sFresh) = await cache.homeStats(force: refresh)
        let (nStale, nFresh) = await cache.newSkills(limit: 10, force: refresh)

        if let v = sStale { stats = v }
        if let v = nStale { fresh = v }

        let hadStale = (sStale != nil) || (nStale != nil)
        if hadStale { loading = false } else { loading = true }

        let s = await sFresh.value
        let n = await nFresh.value

        if let s { stats = s }
        if let n { fresh = n }

        if !hadStale && s == nil && n == nil { loadError = true }
        loading = false
    }
}

private struct StatCard: View {
    let icon: String
    let value: String
    let label: LocalizedStringKey
    var accent: Bool = false
    var fullWidth: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(accent ? Color.accentGreen : Color.brand)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accent ? Color.accentGreen : Color.textSubtle)
            }
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.textPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
        .frame(maxWidth: fullWidth ? .infinity : .infinity)
        .background(Color.bgCard)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.borderSubtle, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
