import Foundation
import SwiftData

@MainActor
final class FavoriteSyncCoordinator: ObservableObject {
    @Published private(set) var scope: FavoriteScope = .unknown
    @Published private(set) var favoriteIDs: Set<String> = []
    @Published private(set) var isSyncing = false
    @Published private(set) var pendingCount = 0
    @Published private(set) var lastSyncError: String?

    var isReady: Bool { scope != .unknown }

    private var store: FavoritesStore?
    private let remote: any FavoritesRemoteClient
    private var syncTask: Task<Void, Never>?
    private var rerunRequested = false

    init(remote: any FavoritesRemoteClient = FavoritesRemoteAPI()) {
        self.remote = remote
    }

    init(store: FavoritesStore, remote: any FavoritesRemoteClient) {
        self.store = store
        self.remote = remote
    }

    func configure(context: ModelContext) {
        guard store == nil else { return }
        store = FavoritesStore(context)
    }

    func activate(_ newScope: FavoriteScope) async {
        scope = newScope
        lastSyncError = nil

        guard let store else {
            favoriteIDs = []
            pendingCount = 0
            return
        }

        do {
            switch newScope {
            case .unknown:
                favoriteIDs = []
                pendingCount = 0
            case .guest:
                favoriteIDs = try store.favoriteIDs(in: .guest)
                pendingCount = 0
            case let .account(userId):
                try store.migrateGuest(to: userId)
                try refreshPublishedState()
                await sync()
            }
        } catch {
            lastSyncError = String(localized: "Could not save favorites")
        }
    }

    func toggle(_ skillId: String) {
        guard let store, scope != .unknown else { return }

        do {
            let isNowFavorite = try store.toggle(skillId, in: scope)
            if isNowFavorite {
                favoriteIDs.insert(skillId)
            } else {
                favoriteIDs.remove(skillId)
            }
            try refreshPendingCount()
        } catch {
            lastSyncError = String(localized: "Could not save favorites")
            return
        }

        if case .account = scope {
            Task { await sync() }
        }
    }

    func sync() async {
        guard store != nil, case .account = scope else { return }

        if let syncTask {
            rerunRequested = true
            await syncTask.value
            return
        }

        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.runSyncLoop()
        }
        syncTask = task
        await task.value
    }

    func clearLocalAccountData(userId: String) throws {
        guard let store else { return }
        try store.clearAccountData(userId: userId)
        if scope == .account(userId) {
            favoriteIDs = []
            pendingCount = 0
            lastSyncError = nil
        }
    }

    static func overlay(
        remoteIDs: Set<String>,
        pending: [PendingFavoriteChange]
    ) -> Set<String> {
        pending.reduce(into: remoteIDs) { result, change in
            if change.desiredFavorite {
                result.insert(change.skillId)
            } else {
                result.remove(change.skillId)
            }
        }
    }

    private func runSyncLoop() async {
        isSyncing = true
        defer {
            isSyncing = false
            syncTask = nil
            do {
                try refreshPublishedState()
            } catch {
                lastSyncError = String(localized: "Could not load favorites")
            }
        }

        repeat {
            rerunRequested = false
            guard case let .account(userId) = scope else { break }
            await syncOnce(userId: userId)
            if scope != .account(userId), case .account = scope {
                rerunRequested = true
            }
        } while rerunRequested
    }

    private func syncOnce(userId: String) async {
        guard let store else { return }
        let failureMessage = String(localized: "Favorite sync failed")
        var roundFailed = false
        let snapshot: [PendingFavoriteChange]

        do {
            snapshot = try store.pendingChanges(for: userId)
        } catch {
            publishSyncFailure(failureMessage, for: userId)
            return
        }

        let additions = snapshot.filter(\.desiredFavorite)
        let deletions = snapshot.filter { !$0.desiredFavorite }

        if !additions.isEmpty {
            do {
                try await remote.upsert(
                    userId: userId,
                    skillIDs: Set(additions.map(\.skillId))
                )
                try store.clearPending(additions)
            } catch {
                roundFailed = true
                do {
                    try store.markPendingFailed(additions, message: failureMessage)
                } catch {
                    roundFailed = true
                }
            }
        }

        if !deletions.isEmpty {
            do {
                try await remote.delete(
                    userId: userId,
                    skillIDs: Set(deletions.map(\.skillId))
                )
                try store.clearPending(deletions)
            } catch {
                roundFailed = true
                do {
                    try store.markPendingFailed(deletions, message: failureMessage)
                } catch {
                    roundFailed = true
                }
            }
        }

        do {
            let remoteIDs = try await remote.fetchSkillIDs(userId: userId)
            let currentPending = try store.pendingChanges(for: userId)
            let reconciledIDs = Self.overlay(remoteIDs: remoteIDs, pending: currentPending)
            try store.replaceAccountFavorites(for: userId, with: reconciledIDs)

            if scope == .account(userId) {
                favoriteIDs = reconciledIDs
                pendingCount = currentPending.count
                lastSyncError = roundFailed ? failureMessage : nil
            }
        } catch {
            roundFailed = true
            publishSyncFailure(failureMessage, for: userId)
        }

        if roundFailed, scope == .account(userId) {
            lastSyncError = failureMessage
            do {
                try refreshPendingCount()
            } catch {
                lastSyncError = String(localized: "Could not load favorites")
            }
        }
    }

    private func publishSyncFailure(_ message: String, for userId: String) {
        guard scope == .account(userId) else { return }
        lastSyncError = message
        do {
            try refreshPendingCount()
        } catch {
            lastSyncError = String(localized: "Could not load favorites")
        }
    }

    private func refreshPublishedState() throws {
        guard let store else {
            favoriteIDs = []
            pendingCount = 0
            return
        }

        favoriteIDs = try store.favoriteIDs(in: scope)
        try refreshPendingCount()
    }

    private func refreshPendingCount() throws {
        guard let store, case let .account(userId) = scope else {
            pendingCount = 0
            return
        }
        pendingCount = try store.pendingChanges(for: userId).count
    }
}
