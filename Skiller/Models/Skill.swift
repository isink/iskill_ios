import Foundation

struct Skill: Codable, Identifiable, Hashable {
    let id: String
    let slug: String
    let name: String
    let description: String
    let descriptionZh: String?
    let category: String
    let tags: [String]
    let useCases: [String]?
    let useCasesEn: [String]?
    let author: String
    let githubUrl: String
    let githubStars: Int?
    let rank: Int
    let score: Int
    let featured: Bool
    let createdAt: String
    let publishedAt: String?
    let skillMdContent: String?

    enum CodingKeys: String, CodingKey {
        case id, slug, name, description, category, tags, author, rank, score, featured
        case descriptionZh    = "description_zh"
        case useCases         = "use_cases"
        case useCasesEn       = "use_cases_en"
        case githubUrl        = "github_url"
        case githubStars      = "github_stars"
        case createdAt        = "created_at"
        case publishedAt      = "published_at"
        case skillMdContent   = "skill_md_content"
    }
}

struct SkillCategory: Codable, Identifiable, Hashable {
    let id: String
    let slug: String
    let name: String
    let icon: String
}

struct RepoGroupSummary: Codable, Identifiable, Hashable {
    var id: String { repo }
    let repo: String
    let author: String
    let stars: Int?
    let skillCount: Int
    let repSkillId: String

    enum CodingKeys: String, CodingKey {
        case repo, author, stars
        case skillCount = "skill_count"
        case repSkillId = "rep_skill_id"
    }
}

struct HomeStats {
    let total: Int
    let newToday: Int
    let lastSyncAt: Date?
}

extension Skill {
    var githubRepositoryURL: URL? {
        Self.githubRepositoryURL(from: githubUrl)
    }

    static func githubRepositoryURL(from rawValue: String) -> URL? {
        guard let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "github.com",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.path.split(separator: "/").count >= 2,
              let url = components.url
        else { return nil }
        return url
    }

    /// Picks Chinese description for zh users, English for everyone else.
    /// Falls back to whichever exists when the preferred one is missing/empty.
    var localizedDescription: String {
        let prefersChinese = Locale.current.language.languageCode?.identifier == "zh"
        if prefersChinese, let zh = descriptionZh, !zh.isEmpty {
            return zh
        }
        if !description.isEmpty {
            return description
        }
        return descriptionZh ?? ""
    }

    /// Locale-appropriate use-case chips: English for non-zh systems, Chinese
    /// otherwise. Falls back to the other language if the preferred one hasn't
    /// been generated yet (older rows in the DB).
    var localizedUseCases: [String] {
        let prefersChinese = Locale.current.language.languageCode?.identifier == "zh"
        let preferred = prefersChinese ? useCases : useCasesEn
        if let p = preferred, !p.isEmpty { return p }
        let fallback = prefersChinese ? useCasesEn : useCases
        return fallback ?? []
    }
}
