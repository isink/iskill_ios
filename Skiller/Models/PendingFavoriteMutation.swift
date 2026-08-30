import Foundation
import SwiftData

@Model
final class PendingFavoriteMutation {
    @Attribute(.unique) var recordKey: String
    var userId: String
    var skillId: String
    var desiredFavorite: Bool
    var revision: String
    var updatedAt: Date
    var attemptCount: Int
    var lastError: String?

    init(
        userId: String,
        skillId: String,
        desiredFavorite: Bool,
        revision: String = UUID().uuidString,
        updatedAt: Date = .now,
        attemptCount: Int = 0,
        lastError: String? = nil
    ) {
        self.recordKey = AccountFavorite.key(userId: userId, skillId: skillId)
        self.userId = userId
        self.skillId = skillId
        self.desiredFavorite = desiredFavorite
        self.revision = revision
        self.updatedAt = updatedAt
        self.attemptCount = attemptCount
        self.lastError = lastError
    }
}

struct PendingFavoriteChange: Equatable, Sendable {
    let recordKey: String
    let userId: String
    let skillId: String
    let desiredFavorite: Bool
    let revision: String
}
