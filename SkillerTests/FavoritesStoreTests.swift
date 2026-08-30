import SwiftData
import XCTest
@testable import Skiller

@MainActor
final class FavoritesStoreTests: XCTestCase {
    private var containers: [ModelContainer] = []

    private func makeStore() throws -> FavoritesStore {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Favorite.self,
            AccountFavorite.self,
            PendingFavoriteMutation.self,
            configurations: configuration
        )
        containers.append(container)
        return FavoritesStore(container.mainContext)
    }

    func testMigrateGuestMovesFavoritesAndQueuesAdds() throws {
        let store = try makeStore()
        _ = try store.toggle("guest-a", in: .guest)
        _ = try store.toggle("guest-b", in: .guest)

        try store.migrateGuest(to: "user-a")

        XCTAssertEqual(try store.favoriteIDs(in: .guest), [])
        XCTAssertEqual(try store.favoriteIDs(in: .account("user-a")), ["guest-a", "guest-b"])
        XCTAssertEqual(
            Set(try store.pendingChanges(for: "user-a").map(\.skillId)),
            ["guest-a", "guest-b"]
        )
    }

    func testAccountsRemainIsolated() throws {
        let store = try makeStore()
        _ = try store.toggle("shared-skill", in: .account("user-a"))
        _ = try store.toggle("other-skill", in: .account("user-b"))

        XCTAssertEqual(try store.favoriteIDs(in: .account("user-a")), ["shared-skill"])
        XCTAssertEqual(try store.favoriteIDs(in: .account("user-b")), ["other-skill"])
    }

    func testRepeatedToggleCoalescesToOneFinalMutation() throws {
        let store = try makeStore()
        _ = try store.toggle("skill-a", in: .account("user-a"))
        _ = try store.toggle("skill-a", in: .account("user-a"))
        _ = try store.toggle("skill-a", in: .account("user-a"))

        let pending = try store.pendingChanges(for: "user-a")
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.desiredFavorite, true)
    }

    func testClearingSentSnapshotKeepsNewerOppositeMutation() throws {
        let store = try makeStore()
        _ = try store.toggle("skill-a", in: .account("user-a"))
        let sentSnapshot = try store.pendingChanges(for: "user-a")
        _ = try store.toggle("skill-a", in: .account("user-a"))

        try store.clearPending(sentSnapshot)

        let remaining = try store.pendingChanges(for: "user-a")
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.desiredFavorite, false)
        XCTAssertNotEqual(remaining.first?.revision, sentSnapshot.first?.revision)
    }

    func testRemoteReplacementDoesNotTouchAnotherAccount() throws {
        let store = try makeStore()
        try store.replaceAccountFavorites(for: "user-a", with: ["remote-a"])
        try store.replaceAccountFavorites(for: "user-b", with: ["remote-b"])
        try store.replaceAccountFavorites(for: "user-a", with: ["remote-c"])

        XCTAssertEqual(try store.favoriteIDs(in: .account("user-a")), ["remote-c"])
        XCTAssertEqual(try store.favoriteIDs(in: .account("user-b")), ["remote-b"])
    }

    func testClearAccountDataLeavesGuestAndOtherAccountUntouched() throws {
        let store = try makeStore()
        _ = try store.toggle("guest", in: .guest)
        _ = try store.toggle("a", in: .account("user-a"))
        _ = try store.toggle("b", in: .account("user-b"))

        try store.clearAccountData(userId: "user-a")

        XCTAssertEqual(try store.favoriteIDs(in: .guest), ["guest"])
        XCTAssertEqual(try store.favoriteIDs(in: .account("user-a")), [])
        XCTAssertEqual(try store.favoriteIDs(in: .account("user-b")), ["b"])
        XCTAssertTrue(try store.pendingChanges(for: "user-a").isEmpty)
    }
}
