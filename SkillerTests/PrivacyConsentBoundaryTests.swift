import XCTest
@testable import Skiller

final class PrivacyConsentBoundaryTests: XCTestCase {
    func testSupabaseAutoRefreshIsDisabledUntilAppConsent() {
        XCTAssertFalse(SupabaseConfig.authOptions.autoRefreshToken)
    }
}
