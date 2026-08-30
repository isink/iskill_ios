import Foundation
import SwiftData

enum FavoriteScope: Equatable, Sendable {
    case unknown
    case guest
    case account(String)
}

enum FavoritesStoreError: Error {
    case scopeUnavailable
}

@MainActor
final class FavoritesStore {
    private var context: ModelContext

    init(_ context: ModelContext) {
        self.context = context
    }

    func favoriteIDs(in scope: FavoriteScope) throws -> Set<String> {
        switch scope {
        case .unknown:
            return []
        case .guest:
            return Set(try context.fetch(FetchDescriptor<Favorite>()).map(\.skillId))
        case let .account(userId):
            let favorites = try context.fetch(FetchDescriptor<AccountFavorite>())
            return Set(favorites.lazy.filter { $0.userId == userId }.map(\.skillId))
        }
    }

    @discardableResult
    func toggle(_ skillId: String, in scope: FavoriteScope) throws -> Bool {
        switch scope {
        case .unknown:
            throw FavoritesStoreError.scopeUnavailable
        case .guest:
            let existing = try guestFavorite(skillId: skillId)
            if let existing {
                context.delete(existing)
            } else {
                context.insert(Favorite(skillId: skillId))
            }
            try context.save()
            return existing == nil
        case let .account(userId):
            let key = AccountFavorite.key(userId: userId, skillId: skillId)
            let existing = try accountFavorite(recordKey: key)
            let desiredFavorite = existing == nil

            if let existing {
                context.delete(existing)
            } else {
                context.insert(AccountFavorite(userId: userId, skillId: skillId))
            }
            try upsertPending(
                recordKey: key,
                userId: userId,
                skillId: skillId,
                desiredFavorite: desiredFavorite
            )
            try context.save()
            return desiredFavorite
        }
    }

    func migrateGuest(to userId: String) throws {
        let guestFavorites = try context.fetch(FetchDescriptor<Favorite>())
        for favorite in guestFavorites {
            let key = AccountFavorite.key(userId: userId, skillId: favorite.skillId)
            if try accountFavorite(recordKey: key) == nil {
                context.insert(AccountFavorite(
                    userId: userId,
                    skillId: favorite.skillId,
                    createdAt: favorite.createdAt
                ))
            }
            try upsertPending(
                recordKey: key,
                userId: userId,
                skillId: favorite.skillId,
                desiredFavorite: true
            )
            context.delete(favorite)
        }
        try context.save()
    }

    func pendingChanges(for userId: String) throws -> [PendingFavoriteChange] {
        try context.fetch(FetchDescriptor<PendingFavoriteMutation>())
            .filter { $0.userId == userId }
            .sorted { $0.updatedAt < $1.updatedAt }
            .map {
                PendingFavoriteChange(
                    recordKey: $0.recordKey,
                    userId: $0.userId,
                    skillId: $0.skillId,
                    desiredFavorite: $0.desiredFavorite,
                    revision: $0.revision
                )
            }
    }

    func clearPending(_ changes: [PendingFavoriteChange]) throws {
        for change in changes {
            guard let pending = try pendingMutation(recordKey: change.recordKey),
                  pending.revision == change.revision else { continue }
            context.delete(pending)
        }
        try context.save()
    }

    func markPendingFailed(_ changes: [PendingFavoriteChange], message: String) throws {
        for change in changes {
            guard let pending = try pendingMutation(recordKey: change.recordKey),
                  pending.revision == change.revision else { continue }
            pending.attemptCount += 1
            pending.lastError = message
        }
        try context.save()
    }

    func replaceAccountFavorites(for userId: String, with skillIDs: Set<String>) throws {
        let allFavorites = try context.fetch(FetchDescriptor<AccountFavorite>())
        let existing = allFavorites.filter { $0.userId == userId }
        let existingBySkill = Dictionary(uniqueKeysWithValues: existing.map { ($0.skillId, $0) })

        for favorite in existing where !skillIDs.contains(favorite.skillId) {
            context.delete(favorite)
        }
        for skillId in skillIDs where existingBySkill[skillId] == nil {
            context.insert(AccountFavorite(userId: userId, skillId: skillId))
        }
        try context.save()
    }

    func clearAccountData(userId: String) throws {
        for favorite in try context.fetch(FetchDescriptor<AccountFavorite>())
            where favorite.userId == userId {
            context.delete(favorite)
        }
        for pending in try context.fetch(FetchDescriptor<PendingFavoriteMutation>())
            where pending.userId == userId {
            context.delete(pending)
        }
        try context.save()
    }

    private func guestFavorite(skillId: String) throws -> Favorite? {
        var descriptor = FetchDescriptor<Favorite>(
            predicate: #Predicate { $0.skillId == skillId }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func accountFavorite(recordKey: String) throws -> AccountFavorite? {
        var descriptor = FetchDescriptor<AccountFavorite>(
            predicate: #Predicate { $0.recordKey == recordKey }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func pendingMutation(recordKey: String) throws -> PendingFavoriteMutation? {
        var descriptor = FetchDescriptor<PendingFavoriteMutation>(
            predicate: #Predicate { $0.recordKey == recordKey }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func upsertPending(
        recordKey: String,
        userId: String,
        skillId: String,
        desiredFavorite: Bool
    ) throws {
        if let existing = try pendingMutation(recordKey: recordKey) {
            existing.desiredFavorite = desiredFavorite
            existing.revision = UUID().uuidString
            existing.updatedAt = .now
            existing.attemptCount = 0
            existing.lastError = nil
        } else {
            context.insert(PendingFavoriteMutation(
                userId: userId,
                skillId: skillId,
                desiredFavorite: desiredFavorite
            ))
        }
    }
}

@MainActor
enum RecentViewStore {
    static func record(_ ctx: ModelContext, skillId: String, category: String) {
        var fd = FetchDescriptor<RecentView>(
            predicate: #Predicate { $0.skillId == skillId }
        )
        fd.fetchLimit = 1
        if let existing = (try? ctx.fetch(fd))?.first {
            existing.viewedAt = .now
            existing.category = category
        } else {
            ctx.insert(RecentView(skillId: skillId, category: category))
        }
        try? ctx.save()
    }
}

@MainActor
final class LastSeenStore {
    static let exploreKey = "explore"
    private var context: ModelContext

    init(_ context: ModelContext) { self.context = context }

    func get(_ key: String) -> Date? {
        var fd = FetchDescriptor<LastSeen>(
            predicate: #Predicate { $0.key == key }
        )
        fd.fetchLimit = 1
        return (try? context.fetch(fd))?.first?.seenAt
    }

    func update(_ key: String, to date: Date = .now) {
        var fd = FetchDescriptor<LastSeen>(
            predicate: #Predicate { $0.key == key }
        )
        fd.fetchLimit = 1
        if let existing = (try? context.fetch(fd))?.first {
            existing.seenAt = date
        } else {
            context.insert(LastSeen(key: key, seenAt: date))
        }
        try? context.save()
    }
}
