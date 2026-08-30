import XCTest
@testable import Skiller

final class FavoritesRemoteAPITests: XCTestCase {
    func testInsertRowUsesDatabaseColumnNames() throws {
        let row = RemoteFavoriteInsert(userId: "user-a", skillId: "skill-a")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: String]
        )

        XCTAssertEqual(object, ["user_id": "user-a", "skill_id": "skill-a"])
    }
}
