import Foundation
import Supabase

protocol FavoritesRemoteClient: Sendable {
    func fetchSkillIDs(userId: String) async throws -> Set<String>
    func upsert(userId: String, skillIDs: Set<String>) async throws
    func delete(userId: String, skillIDs: Set<String>) async throws
}

struct RemoteFavoriteInsert: Encodable, Sendable {
    let userId: String
    let skillId: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case skillId = "skill_id"
    }
}

private struct RemoteFavoriteRow: Decodable {
    let skillId: String

    enum CodingKeys: String, CodingKey {
        case skillId = "skill_id"
    }
}

struct FavoritesRemoteAPI: FavoritesRemoteClient {
    func fetchSkillIDs(userId: String) async throws -> Set<String> {
        let rows: [RemoteFavoriteRow] = try await supabase
            .from("favorites")
            .select("skill_id")
            .eq("user_id", value: userId)
            .execute()
            .value
        return Set(rows.map(\.skillId))
    }

    func upsert(userId: String, skillIDs: Set<String>) async throws {
        guard !skillIDs.isEmpty else { return }
        let rows = skillIDs.sorted().map {
            RemoteFavoriteInsert(userId: userId, skillId: $0)
        }
        try await supabase
            .from("favorites")
            .upsert(rows, onConflict: "user_id,skill_id")
            .execute()
    }

    func delete(userId: String, skillIDs: Set<String>) async throws {
        guard !skillIDs.isEmpty else { return }
        try await supabase
            .from("favorites")
            .delete()
            .eq("user_id", value: userId)
            .in("skill_id", values: skillIDs.sorted())
            .execute()
    }
}
