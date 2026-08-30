import XCTest
@testable import Skiller

final class SkillSourceLinkTests: XCTestCase {
    func testAcceptsHTTPSGitHubRepositoryURL() {
        XCTAssertEqual(
            Skill.githubRepositoryURL(from: "https://github.com/owner/repository")?.absoluteString,
            "https://github.com/owner/repository"
        )
        XCTAssertNotNil(
            Skill.githubRepositoryURL(
                from: "https://github.com/owner/repository/tree/main/skills/example"
            )
        )
    }

    func testRejectsNonHTTPSAndLookalikeHosts() {
        XCTAssertNil(Skill.githubRepositoryURL(from: "http://github.com/owner/repository"))
        XCTAssertNil(Skill.githubRepositoryURL(from: "https://github.com.evil.example/owner/repository"))
        XCTAssertNil(Skill.githubRepositoryURL(from: "javascript:alert(1)"))
    }

    func testRejectsGitHubURLsWithoutRepositoryPath() {
        XCTAssertNil(Skill.githubRepositoryURL(from: "https://github.com/owner"))
    }
}
