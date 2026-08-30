import XCTest
@testable import Skiller

final class AuthFavoriteScopeTests: XCTestCase {
    func testUnknownMapsToUnknownFavorites() {
        XCTAssertEqual(AuthService.State.unknown.favoriteScope, .unknown)
    }

    func testSignedOutMapsToGuestFavorites() {
        XCTAssertEqual(AuthService.State.signedOut.favoriteScope, .guest)
    }

    func testSignedInMapsToUserUUID() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let identity = AuthService.UserIdentity(
            userId: id,
            provider: .apple,
            displayName: "Test",
            login: "test",
            avatarUrl: nil
        )

        XCTAssertEqual(
            AuthService.State.signedIn(identity).favoriteScope,
            .account(id.uuidString)
        )
    }
}
