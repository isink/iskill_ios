import Combine
import XCTest
@testable import Skiller

@MainActor
final class AdConsentServiceTests: XCTestCase {
    func testPrepareStartsAdsOnlyAfterConsentAllowsRequests() async {
        let manager = FakeAdConsentManager(
            canRequestAdsAfterUpdate: false,
            canRequestAdsAfterRequiredForm: true
        )
        var startCount = 0
        let service = AdConsentService(manager: manager) { startCount += 1 }

        await service.prepare()

        XCTAssertEqual(manager.updateCount, 1)
        XCTAssertEqual(manager.requiredFormCount, 1)
        XCTAssertEqual(startCount, 1)
        XCTAssertTrue(service.canRequestAds)
    }

    func testPrepareDoesNotStartAdsWithoutConsent() async {
        let manager = FakeAdConsentManager(
            canRequestAdsAfterUpdate: false,
            canRequestAdsAfterRequiredForm: false
        )
        var startCount = 0
        let service = AdConsentService(manager: manager) { startCount += 1 }

        await service.prepare()

        XCTAssertEqual(startCount, 0)
        XCTAssertFalse(service.canRequestAds)
    }

    func testPrepareRunsOnlyOncePerAppSession() async {
        let manager = FakeAdConsentManager(
            canRequestAdsAfterUpdate: true,
            canRequestAdsAfterRequiredForm: true
        )
        var startCount = 0
        let service = AdConsentService(manager: manager) { startCount += 1 }

        await service.prepare()
        await service.prepare()

        XCTAssertEqual(manager.updateCount, 1)
        XCTAssertEqual(startCount, 1)
    }

    func testPrepareConfiguresAdsBeforePublishingPermission() async {
        let manager = FakeAdConsentManager(
            canRequestAdsAfterUpdate: true,
            canRequestAdsAfterRequiredForm: true
        )
        var events: [String] = []
        let service = AdConsentService(manager: manager) { events.append("start") }
        let observation = service.$canRequestAds
            .dropFirst()
            .filter { $0 }
            .sink { _ in events.append("publish") }

        await service.prepare()

        XCTAssertEqual(events, ["start", "publish"])
        withExtendedLifetime(observation) {}
    }

    func testPrivacyOptionsRefreshesRequirementAndAdPermission() async {
        let manager = FakeAdConsentManager(
            canRequestAdsAfterUpdate: true,
            canRequestAdsAfterRequiredForm: true,
            privacyOptionsRequired: true
        )
        let service = AdConsentService(manager: manager) {}
        await service.prepare()

        manager.privacyOptionsRequired = false
        await service.presentPrivacyOptions()

        XCTAssertEqual(manager.privacyOptionsCount, 1)
        XCTAssertFalse(service.isPrivacyOptionsRequired)
    }
}

@MainActor
private final class FakeAdConsentManager: AdConsentManaging {
    private let canRequestAdsAfterUpdate: Bool
    private let canRequestAdsAfterRequiredForm: Bool

    var canRequestAds = false
    var privacyOptionsRequired: Bool
    var updateCount = 0
    var requiredFormCount = 0
    var privacyOptionsCount = 0

    init(
        canRequestAdsAfterUpdate: Bool,
        canRequestAdsAfterRequiredForm: Bool,
        privacyOptionsRequired: Bool = false
    ) {
        self.canRequestAdsAfterUpdate = canRequestAdsAfterUpdate
        self.canRequestAdsAfterRequiredForm = canRequestAdsAfterRequiredForm
        self.privacyOptionsRequired = privacyOptionsRequired
    }

    func requestConsentInfoUpdate() async throws {
        updateCount += 1
        canRequestAds = canRequestAdsAfterUpdate
    }

    func presentRequiredForm() async throws {
        requiredFormCount += 1
        canRequestAds = canRequestAdsAfterRequiredForm
    }

    func presentPrivacyOptions() async throws {
        privacyOptionsCount += 1
    }
}
