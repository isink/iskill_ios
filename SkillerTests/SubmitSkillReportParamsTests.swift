import XCTest
@testable import Skiller

final class SubmitSkillReportParamsTests: XCTestCase {
    func testPayloadContainsOnlyServerAcceptedFields() throws {
        let id = try XCTUnwrap(UUID(uuidString: "75F6AE38-0B15-41DD-929C-3C5A3FA66A55"))
        let params = SubmitSkillReportParams(
            skillId: id,
            reason: "malicious",
            note: "Downloads an unexpected binary"
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? [String: String]
        )

        XCTAssertEqual(object, [
            "p_skill_id": id.uuidString,
            "p_reason": "malicious",
            "p_note": "Downloads an unexpected binary",
        ])
        XCTAssertNil(object["reporter_user_id"])
        XCTAssertNil(object["skill_slug"])
        XCTAssertNil(object["skill_name"])
    }

    func testNilNoteIsOmittedSoDatabaseDefaultApplies() throws {
        let params = SubmitSkillReportParams(
            skillId: UUID(uuidString: "75F6AE38-0B15-41DD-929C-3C5A3FA66A55")!,
            reason: "spam",
            note: nil
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? [String: String]
        )

        XCTAssertEqual(Set(object.keys), ["p_skill_id", "p_reason"])
    }

    func testReportReasonCodesMatchDatabaseContract() {
        XCTAssertEqual(
            ReportSkillSheet.Reason.allCases.map(\.rawValue),
            ["abuse", "copyright", "malicious", "spam", "other"]
        )
    }

    func testReportNotePolicyMatchesDatabaseLimit() {
        let oversized = String(repeating: "a", count: 2_001)

        XCTAssertEqual(ReportNotePolicy.length(ReportNotePolicy.limited(oversized)), 2_000)
        XCTAssertNil(ReportNotePolicy.payload("  \n "))
        XCTAssertEqual(ReportNotePolicy.payload(" useful context "), "useful context")
    }

    func testReportNotePolicyUsesUnicodeScalarsLikePostgresLength() {
        let family = "👨‍👩‍👧‍👦"
        let oversized = String(repeating: family, count: 300)
        let limited = ReportNotePolicy.limited(oversized)

        XCTAssertLessThanOrEqual(ReportNotePolicy.length(limited), 2_000)
        XCTAssertGreaterThan(ReportNotePolicy.length(limited), 1_990)
        XCTAssertTrue(limited.hasSuffix(family))
        XCTAssertLessThan(limited.count, 2_000)
    }

    func testReportFailureClassificationUsesStableDatabaseContract() {
        XCTAssertEqual(
            SkillsAPI.classifyReportFailure(code: "42501", message: "Not authenticated"),
            .signInRequired
        )
        XCTAssertEqual(
            SkillsAPI.classifyReportFailure(code: "P0001", message: "Duplicate report"),
            .duplicate
        )
        XCTAssertEqual(
            SkillsAPI.classifyReportFailure(code: "P0001", message: "Report rate limit exceeded"),
            .rateLimited
        )
        XCTAssertEqual(
            SkillsAPI.classifyReportFailure(code: "23503", message: "Skill not found"),
            .skillUnavailable
        )
        XCTAssertEqual(
            SkillsAPI.classifyReportFailure(code: "XX000", message: "unexpected"),
            .unavailable
        )
    }
}
