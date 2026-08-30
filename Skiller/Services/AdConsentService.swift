import GoogleMobileAds
import SwiftUI
import UserMessagingPlatform

@MainActor
protocol AdConsentManaging {
    var canRequestAds: Bool { get }
    var privacyOptionsRequired: Bool { get }

    func requestConsentInfoUpdate() async throws
    func presentRequiredForm() async throws
    func presentPrivacyOptions() async throws
}

@MainActor
final class AdConsentService: ObservableObject {
    @Published private(set) var canRequestAds = false
    @Published private(set) var isPrivacyOptionsRequired = false
    @Published private(set) var lastError: String?

    private let manager: any AdConsentManaging
    private let startAds: @MainActor () -> Void
    private var didPrepare = false
    private var didStartAds = false

    convenience init() {
        self.init(
            manager: UMPAdConsentManager(),
            startAds: AdConsentService.startGoogleMobileAds
        )
    }

    init(
        manager: any AdConsentManaging,
        startAds: @escaping @MainActor () -> Void
    ) {
        self.manager = manager
        self.startAds = startAds
    }

    func prepare() async {
        guard !didPrepare else { return }
        didPrepare = true

        do {
            try await manager.requestConsentInfoUpdate()
            refreshState()
            try await manager.presentRequiredForm()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }

        refreshState()
    }

    func presentPrivacyOptions() async {
        do {
            try await manager.presentPrivacyOptions()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refreshState()
    }

    private func refreshState() {
        let adsAllowed = manager.canRequestAds
        if adsAllowed, !didStartAds {
            didStartAds = true
            startAds()
        }
        if canRequestAds != adsAllowed {
            canRequestAds = adsAllowed
        }
        let privacyOptionsRequired = manager.privacyOptionsRequired
        if isPrivacyOptionsRequired != privacyOptionsRequired {
            isPrivacyOptionsRequired = privacyOptionsRequired
        }
    }

    private static func startGoogleMobileAds() {
        let configuration = MobileAds.shared.requestConfiguration
        configuration.publisherPrivacyPersonalizationState = .disabled
        configuration.setPublisherFirstPartyIDEnabled(false)
        MobileAds.shared.start(completionHandler: nil)
    }
}

@MainActor
private struct UMPAdConsentManager: AdConsentManaging {
    var canRequestAds: Bool {
        ConsentInformation.shared.canRequestAds
    }

    var privacyOptionsRequired: Bool {
        ConsentInformation.shared.privacyOptionsRequirementStatus == .required
    }

    func requestConsentInfoUpdate() async throws {
        try await ConsentInformation.shared.requestConsentInfoUpdate(with: RequestParameters())
    }

    func presentRequiredForm() async throws {
        try await ConsentForm.loadAndPresentIfRequired(from: nil)
    }

    func presentPrivacyOptions() async throws {
        try await ConsentForm.presentPrivacyOptionsForm(from: nil)
    }
}
