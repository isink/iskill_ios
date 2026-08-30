import Foundation
import SwiftData

@Model
final class AccountFavorite {
    @Attribute(.unique) var recordKey: String
    var userId: String
    var skillId: String
    var createdAt: Date

    init(userId: String, skillId: String, createdAt: Date = .now) {
        self.recordKey = Self.key(userId: userId, skillId: skillId)
        self.userId = userId
        self.skillId = skillId
        self.createdAt = createdAt
    }

    static func key(userId: String, skillId: String) -> String {
        "\(userId)|\(skillId)"
    }
}
