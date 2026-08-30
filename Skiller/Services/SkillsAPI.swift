import Foundation
import Supabase

private let LIST_COLUMNS = """
id, slug, name, description, description_zh, category, tags, use_cases, use_cases_en, \
author, github_url, github_stars, rank, score, featured, created_at, published_at
"""

enum SkillsAPI {

    // MARK: - Lists

    static func fetchFeaturedSkills(limit: Int = 20) async throws -> [Skill] {
        try await supabase
            .from("skills")
            .select(LIST_COLUMNS)
            .eq("featured", value: true)
            .order("rank", ascending: false)
            .limit(limit)
            .execute()
            .value
    }

    static func fetchOfficialSkills(offset: Int = 0, limit: Int = 50) async throws -> [Skill] {
        try await supabase
            .from("skills")
            .select(LIST_COLUMNS)
            .eq("featured", value: true)
            .order("rank", ascending: false)
            .range(from: offset, to: offset + limit - 1)
            .execute()
            .value
    }

    static func fetchAllSkills(offset: Int = 0, limit: Int = 50) async throws -> [Skill] {
        try await supabase
            .from("skills")
            .select(LIST_COLUMNS)
            .order("github_stars", ascending: false, nullsFirst: false)
            .range(from: offset, to: offset + limit - 1)
            .execute()
            .value
    }

    static func fetchNewSkills(limit: Int = 10) async throws -> [Skill] {
        let since = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(-30 * 24 * 60 * 60)
        )
        // Pull a wider slice and dedupe on (author, name) — same author publishing
        // the identical skill multiple times in different subdirs is not actually
        // distinct content.
        let rows: [Skill] = try await supabase
            .from("skills")
            .select(LIST_COLUMNS)
            .gte("created_at", value: since)
            .order("created_at", ascending: false)
            .limit(limit * 4)
            .execute()
            .value
        var seen = Set<String>()
        var deduped: [Skill] = []
        for s in rows {
            let key = "\(s.author.lowercased())|\(s.name.lowercased())"
            if seen.insert(key).inserted {
                deduped.append(s)
                if deduped.count >= limit { break }
            }
        }
        return deduped
    }

    /// "最新收录"整批：拉 created_at 降序的近期记录，再用时间间隔切出最新一次同步的整批。
    /// 同一次 sync 的入库时间通常在几分钟内，往前一档跟上次 sync 至少差 1 小时。
    static func fetchLatestBatch(probe: Int = 300, gapHours: Double = 1) async throws -> [Skill] {
        let recent: [Skill] = try await supabase
            .from("skills")
            .select(LIST_COLUMNS)
            .order("created_at", ascending: false)
            .limit(probe)
            .execute()
            .value
        return trimToLatestBatch(recent, gapHours: gapHours)
    }

    private static func trimToLatestBatch(_ skills: [Skill], gapHours: Double) -> [Skill] {
        guard !skills.isEmpty else { return [] }
        var result: [Skill] = []
        var lastTime: Date? = nil
        for s in skills {
            guard let t = Format.parseISO(s.createdAt) else {
                result.append(s)
                continue
            }
            if let lt = lastTime, lt.timeIntervalSince(t) > gapHours * 3600 {
                break
            }
            result.append(s)
            lastTime = t
        }
        return result
    }

    static func fetchSkillsByCategory(
        _ category: String, offset: Int = 0, limit: Int = 50
    ) async throws -> [Skill] {
        try await supabase
            .from("skills")
            .select(LIST_COLUMNS)
            .eq("category", value: category)
            .order("github_stars", ascending: false, nullsFirst: false)
            .range(from: offset, to: offset + limit - 1)
            .execute()
            .value
    }

    static func searchSkills(_ query: String) async throws -> [Skill] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let safe = q.replacingOccurrences(
            of: "[,()*\"]",
            with: " ",
            options: .regularExpression
        )
        .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
        guard !safe.isEmpty else { return [] }

        let filter =
            "name.ilike.%\(safe)%," +
            "description.ilike.%\(safe)%," +
            "description_zh.ilike.%\(safe)%," +
            "author.ilike.%\(safe)%"

        return try await supabase
            .from("skills")
            .select(LIST_COLUMNS)
            .or(filter)
            .order("rank", ascending: false)
            .limit(50)
            .execute()
            .value
    }

    // MARK: - Detail

    static func fetchSkillById(_ id: String) async throws -> Skill? {
        let rows: [Skill] = try await supabase
            .from("skills")
            .select("*")
            .eq("id", value: id)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    static func fetchSkillsInRepo(_ repo: String) async throws -> [Skill] {
        try await supabase
            .from("skills")
            .select(LIST_COLUMNS)
            .ilike("github_url", pattern: "%github.com/\(repo)/%")
            .order("featured", ascending: false)
            .order("rank", ascending: false)
            .execute()
            .value
    }

    // MARK: - Categories & Stats

    static func fetchCategories() async throws -> [SkillCategory] {
        let rows: [SkillCategory] = try await supabase
            .from("categories")
            .select("id, slug, name, icon")
            .execute()
            .value

        return rows.sorted { a, b in
            let ai = CategoryMeta.order.firstIndex(of: a.slug) ?? Int.max
            let bi = CategoryMeta.order.firstIndex(of: b.slug) ?? Int.max
            return ai < bi
        }
    }

    static func fetchCategoryCounts() async throws -> [String: Int] {
        struct Row: Decodable { let category: String; let count: Int }
        let rows: [Row] = try await supabase
            .rpc("get_category_counts")
            .execute()
            .value
        var dict: [String: Int] = [:]
        for r in rows { dict[r.category] = r.count }
        return dict
    }

    static func fetchRepoGroups(offset: Int = 0, limit: Int = 30) async throws -> [RepoGroupSummary] {
        struct Params: Encodable {
            let p_category: String?
            let p_offset: Int
            let p_limit: Int
        }
        return try await supabase
            .rpc("get_repo_groups", params: Params(p_category: nil, p_offset: offset, p_limit: limit))
            .execute()
            .value
    }

    static func fetchHomeStats() async throws -> HomeStats {
        async let totalCount = supabase
            .from("skills")
            .select("*", head: true, count: .exact)
            .execute().count

        let startOfDay = Calendar.current.startOfDay(for: Date())
        let isoToday = ISO8601DateFormatter().string(from: startOfDay)
        async let newCount = supabase
            .from("skills")
            .select("*", head: true, count: .exact)
            .gte("created_at", value: isoToday)
            .execute().count

        struct DateRow: Decodable { let created_at: String }
        async let lastRow: [DateRow] = supabase
            .from("skills")
            .select("created_at")
            .order("created_at", ascending: false)
            .limit(1)
            .execute()
            .value

        let (total, newToday, last) = try await (totalCount, newCount, lastRow)
        let lastDate: Date? = last.first.flatMap {
            ISO8601DateFormatter().date(from: $0.created_at)
        }
        return HomeStats(total: total ?? 0, newToday: newToday ?? 0, lastSyncAt: lastDate)
    }

    // MARK: - Reports

    static func submitReport(
        skillId: String,
        skillSlug: String,
        skillName: String,
        reason: String,
        note: String?,
        userId: UUID?
    ) async throws {
        struct Row: Encodable {
            let skill_id: String
            let skill_slug: String
            let skill_name: String
            let reason: String
            let note: String?
            let reporter_user_id: UUID?
        }
        try await supabase
            .from("skill_reports")
            .insert(Row(
                skill_id: skillId,
                skill_slug: skillSlug,
                skill_name: skillName,
                reason: reason,
                note: note,
                reporter_user_id: userId
            ))
            .execute()
    }

    static func incrementInstallCount(_ id: String) async {
        struct Params: Encodable { let skill_id: String }
        do {
            try await supabase
                .rpc("increment_install_count", params: Params(skill_id: id))
                .execute()
        } catch {
            // Best-effort; ignore failure
        }
    }
}
