import Combine
import SwiftData
import XCTest
@testable import Skiller

@MainActor
final class FavoriteSyncCoordinatorTests: XCTestCase {
    func testUnknownScopePublishesNoFavorites() async throws {
        let harness = try Harness()
        try harness.store.replaceAccountFavorites(for: "user-a", with: ["private-a"])

        await harness.coordinator.activate(.unknown)

        XCTAssertEqual(harness.coordinator.favoriteIDs, [])
        XCTAssertFalse(harness.coordinator.isReady)
    }

    func testGuestActivationUsesExistingFavoriteRows() async throws {
        let harness = try Harness()
        _ = try harness.store.toggle("guest-a", in: .guest)

        await harness.coordinator.activate(.guest)

        XCTAssertEqual(harness.coordinator.favoriteIDs, ["guest-a"])
    }

    func testAccountActivationMigratesGuestBeforeSync() async throws {
        let harness = try Harness()
        _ = try harness.store.toggle("guest-a", in: .guest)
        await harness.remote.setRemote(["remote-a"], for: "user-a")

        await harness.coordinator.activate(.account("user-a"))

        XCTAssertEqual(harness.coordinator.favoriteIDs, ["guest-a", "remote-a"])
        XCTAssertEqual(try harness.store.favoriteIDs(in: .guest), [])
    }

    func testToggleUpdatesPublishedStateBeforeFailedUploadCanRollbackIt() async throws {
        let harness = try Harness()
        await harness.remote.setFailUpsert(true)
        await harness.coordinator.activate(.account("user-a"))

        harness.coordinator.toggle("skill-a")

        XCTAssertTrue(harness.coordinator.favoriteIDs.contains("skill-a"))
    }

    func testFailedUploadKeepsPendingAndLocalFavorite() async throws {
        let harness = try Harness()
        await harness.coordinator.activate(.account("user-a"))
        await harness.remote.setFailUpsert(true)
        harness.coordinator.toggle("skill-a")

        await harness.coordinator.sync()

        XCTAssertEqual(harness.coordinator.favoriteIDs, ["skill-a"])
        XCTAssertEqual(harness.coordinator.pendingCount, 1)
        XCTAssertNotNil(harness.coordinator.lastSyncError)
    }

    func testPendingDeleteOverlaysStaleRemoteFetch() async throws {
        let harness = try Harness()
        await harness.remote.setRemote(["skill-a"], for: "user-a")
        await harness.coordinator.activate(.account("user-a"))
        await harness.remote.setFailDelete(true)
        harness.coordinator.toggle("skill-a")

        await harness.coordinator.sync()

        XCTAssertEqual(harness.coordinator.favoriteIDs, [])
        XCTAssertEqual(harness.coordinator.pendingCount, 1)
    }

    func testSuccessfulRetryClearsOnlySuccessfulMutations() async throws {
        let harness = try Harness()
        await harness.coordinator.activate(.account("user-a"))
        await harness.remote.setFailUpsert(true)
        harness.coordinator.toggle("add-a")
        await harness.coordinator.sync()
        XCTAssertEqual(harness.coordinator.pendingCount, 1)

        await harness.remote.setFailUpsert(false)
        await harness.coordinator.sync()

        let remoteIDs = await harness.remote.snapshot(for: "user-a")
        XCTAssertEqual(harness.coordinator.pendingCount, 0)
        XCTAssertEqual(remoteIDs, ["add-a"])
    }

    func testAddSuccessAndDeleteFailureClearOnlyAddMutation() async throws {
        let harness = try Harness()
        await harness.remote.setRemote(["remove-a"], for: "user-a")
        await harness.coordinator.activate(.account("user-a"))
        await harness.remote.setFailDelete(true)
        harness.coordinator.toggle("add-a")
        harness.coordinator.toggle("remove-a")

        await harness.coordinator.sync()

        let pending = try harness.store.pendingChanges(for: "user-a")
        let remoteIDs = await harness.remote.snapshot(for: "user-a")
        XCTAssertEqual(Set(pending.map(\.skillId)), ["remove-a"])
        XCTAssertEqual(remoteIDs, ["add-a", "remove-a"])
        XCTAssertEqual(harness.coordinator.favoriteIDs, ["add-a"])
    }

    func testConcurrentTriggersNeverOverlapRemoteRequests() async throws {
        let harness = try Harness()
        await harness.remote.setRequestDelay(20_000_000)
        await harness.coordinator.activate(.account("user-a"))

        let first = Task { await harness.coordinator.sync() }
        let second = Task { await harness.coordinator.sync() }
        await first.value
        await second.value

        let maximumConcurrency = await harness.remote.maximumConcurrency()
        XCTAssertEqual(maximumConcurrency, 1)
    }

    func testScopeSwitchDuringRequestNeverPublishesPreviousAccount() async throws {
        let harness = try Harness()
        await harness.remote.setRemote(["remote-a"], for: "user-a")
        await harness.remote.setRemote(["remote-b"], for: "user-b")
        await harness.remote.setRequestDelay(20_000_000)

        let activateA = Task { await harness.coordinator.activate(.account("user-a")) }
        await harness.remote.waitForRequestToStart()
        var publishedAfterSwitch: [Set<String>] = []
        let observation = harness.coordinator.$favoriteIDs.sink {
            publishedAfterSwitch.append($0)
        }
        let activateB = Task { await harness.coordinator.activate(.account("user-b")) }
        await activateA.value
        await activateB.value

        XCTAssertEqual(harness.coordinator.scope, .account("user-b"))
        XCTAssertEqual(harness.coordinator.favoriteIDs, ["remote-b"])
        XCTAssertFalse(publishedAfterSwitch.contains { $0.contains("remote-a") })
        withExtendedLifetime(observation) {}
    }

    func testNewOppositeToggleSurvivesOlderRequestCompletion() async throws {
        let harness = try Harness()
        await harness.coordinator.activate(.account("user-a"))
        await harness.remote.setRequestDelay(20_000_000)

        harness.coordinator.toggle("skill-a")
        await harness.remote.waitForRequestToStart()
        harness.coordinator.toggle("skill-a")
        await harness.coordinator.sync()

        let remoteIDs = await harness.remote.snapshot(for: "user-a")
        XCTAssertEqual(harness.coordinator.favoriteIDs, [])
        XCTAssertEqual(harness.coordinator.pendingCount, 0)
        XCTAssertEqual(remoteIDs, [])
    }

    func testClearLocalAccountDataRemovesOnlyTargetUser() async throws {
        let harness = try Harness()
        _ = try harness.store.toggle("guest", in: .guest)
        _ = try harness.store.toggle("a", in: .account("user-a"))
        _ = try harness.store.toggle("b", in: .account("user-b"))

        try harness.coordinator.clearLocalAccountData(userId: "user-a")

        XCTAssertEqual(try harness.store.favoriteIDs(in: .guest), ["guest"])
        XCTAssertEqual(try harness.store.favoriteIDs(in: .account("user-a")), [])
        XCTAssertEqual(try harness.store.favoriteIDs(in: .account("user-b")), ["b"])
        XCTAssertTrue(try harness.store.pendingChanges(for: "user-a").isEmpty)
    }
}

@MainActor
private struct Harness {
    let container: ModelContainer
    let store: FavoritesStore
    let remote: FakeFavoritesRemoteClient
    let coordinator: FavoriteSyncCoordinator

    init() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: Favorite.self,
            AccountFavorite.self,
            PendingFavoriteMutation.self,
            configurations: configuration
        )
        store = FavoritesStore(container.mainContext)
        remote = FakeFavoritesRemoteClient()
        coordinator = FavoriteSyncCoordinator(store: store, remote: remote)
    }
}
