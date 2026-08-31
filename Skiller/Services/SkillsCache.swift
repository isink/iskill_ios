import Foundation

actor SkillsCache {
    static let shared = SkillsCache()

    private struct Entry {
        let value: Any
        let at: Date
    }

    private var store: [String: Entry] = [:]
    private var skillIndex: [String: Skill] = [:]

    // MARK: - Skill peek (used by detail view to render header instantly)

    func peekSkill(id: String) -> Skill? { skillIndex[id] }

    private func seedSkill(_ s: Skill) {
        // Don't overwrite a record that has full md content with a list-only record.
        if let existing = skillIndex[s.id], existing.skillMdContent != nil, s.skillMdContent == nil {
            return
        }
        skillIndex[s.id] = s
    }

    private func seedFromAny(_ v: Any) {
        if let list = v as? [Skill] { for s in list { seedSkill(s) } }
        else if let s = v as? Skill { seedSkill(s) }
    }

    // MARK: - Stale-while-revalidate

    func swr<T: Sendable>(
        key: String,
        ttl: TimeInterval,
        force: Bool = false,
        fetch: @Sendable @escaping () async throws -> T
    ) -> (stale: T?, fresh: Task<T?, Never>) {
        let stored = store[key]
        let stale: T? = stored?.value as? T
        let isFresh = !force && (stored.map { Date().timeIntervalSince($0.at) < ttl } ?? false)
        if let s = stale { seedFromAny(s) }
        let fresh = Task<T?, Never> { [self] in
            if isFresh, let s = stale { return s }
            do {
                let v = try await fetch()
                self.commit(v, for: key)
                return v
            } catch { return nil }
        }
        return (stale, fresh)
    }

    private func commit<T>(_ value: T, for key: String) {
        store[key] = Entry(value: value, at: Date())
        seedFromAny(value)
    }

    func clear() {
        store.removeAll()
        skillIndex.removeAll()
    }
}

// MARK: - Typed wrappers

extension SkillsCache {
    func newSkills(limit: Int = 10, force: Bool = false) -> (stale: [Skill]?, fresh: Task<[Skill]?, Never>) {
        swr(key: "new:\(limit)", ttl: 60, force: force) {
            try await SkillsAPI.fetchNewSkills(limit: limit)
        }
    }

    func latestBatch(force: Bool = false) -> (stale: [Skill]?, fresh: Task<[Skill]?, Never>) {
        swr(key: "latestBatch", ttl: 120, force: force) {
            try await SkillsAPI.fetchLatestBatch()
        }
    }

    func featuredSkills(limit: Int = 20, force: Bool = false) -> (stale: [Skill]?, fresh: Task<[Skill]?, Never>) {
        swr(key: "featured:\(limit)", ttl: 60, force: force) {
            try await SkillsAPI.fetchFeaturedSkills(limit: limit)
        }
    }

    func allSkills(offset: Int = 0, limit: Int = 50, force: Bool = false) -> (stale: [Skill]?, fresh: Task<[Skill]?, Never>) {
        swr(key: "all:\(offset):\(limit)", ttl: 60, force: force) {
            try await SkillsAPI.fetchAllSkills(offset: offset, limit: limit)
        }
    }

    func skillsByCategory(_ cat: String, offset: Int = 0, limit: Int = 50, force: Bool = false) -> (stale: [Skill]?, fresh: Task<[Skill]?, Never>) {
        swr(key: "cat:\(cat):\(offset):\(limit)", ttl: 60, force: force) {
            try await SkillsAPI.fetchSkillsByCategory(cat, offset: offset, limit: limit)
        }
    }

    func skillsInRepo(_ repo: String) -> (stale: [Skill]?, fresh: Task<[Skill]?, Never>) {
        swr(key: "repo:\(repo)", ttl: 300) {
            try await SkillsAPI.fetchSkillsInRepo(repo)
        }
    }

    func categories() -> (stale: [SkillCategory]?, fresh: Task<[SkillCategory]?, Never>) {
        swr(key: "categories", ttl: 600) {
            try await SkillsAPI.fetchCategories()
        }
    }

    func categoryCounts() -> (stale: [String: Int]?, fresh: Task<[String: Int]?, Never>) {
        swr(key: "categoryCounts", ttl: 300) {
            try await SkillsAPI.fetchCategoryCounts()
        }
    }

    func repoGroups(limit: Int = 30, force: Bool = false) -> (stale: [RepoGroupSummary]?, fresh: Task<[RepoGroupSummary]?, Never>) {
        swr(key: "repos:\(limit)", ttl: 300, force: force) {
            try await SkillsAPI.fetchRepoGroups(limit: limit)
        }
    }

    func homeStats(force: Bool = false) -> (stale: HomeStats?, fresh: Task<HomeStats?, Never>) {
        swr(key: "homeStats", ttl: 60, force: force) {
            try await SkillsAPI.fetchHomeStats()
        }
    }

    /// Detail: stale comes from any prior list (header-only fields) OR a prior full fetch.
    func skillById(_ id: String) -> (stale: Skill?, fresh: Task<Skill?, Never>) {
        let key = "detail:\(id)"
        let stored = store[key]
        let staleFull: Skill? = stored?.value as? Skill
        let stale: Skill? = staleFull ?? skillIndex[id]
        let isFresh = stored.map { Date().timeIntervalSince($0.at) < 300 } ?? false
        let fresh = Task<Skill?, Never> { [self] in
            if isFresh, let s = staleFull { return s }
            do {
                let v = try await SkillsAPI.fetchSkillById(id)
                if let v { self.commit(v, for: key) }
                return v
            } catch { return nil }
        }
        return (stale, fresh)
    }
}
