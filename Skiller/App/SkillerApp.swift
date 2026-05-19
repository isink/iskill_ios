import GoogleMobileAds
import SwiftData
import SwiftUI
import UIKit

@main
struct SkillerApp: App {
    @StateObject private var auth = AuthService.shared
    @AppStorage("privacyConsentAccepted") private var consentAccepted = false

    var body: some Scene {
        WindowGroup {
            Group {
                if consentAccepted {
                    RootTabView()
                        .environmentObject(auth)
                        .task { await auth.bootstrap() }
                        .onOpenURL { url in
                            Task { await auth.handle(url: url) }
                        }
                        .onReceive(
                            NotificationCenter.default.publisher(
                                for: UIApplication.didBecomeActiveNotification)
                        ) { _ in
                            Task { await recordAppOpen() }
                        }
                } else {
                    ConsentGateView {
                        consentAccepted = true
                        startServicesAfterConsent()
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
        .modelContainer(for: [Favorite.self, LastSeen.self, RecentView.self])
    }

    /// 仅在用户同意后调用：启动广告 SDK。
    private func startServicesAfterConsent() {
        if ComplianceConfig.adsEnabled {
            MobileAds.shared.start(completionHandler: nil)
        }
    }

    private func recordAppOpen() async {
        guard consentAccepted else { return }
        guard let deviceId = await UIDevice.current.identifierForVendor?.uuidString else { return }
        try? await supabase
            .from("app_opens")
            .insert(["device_id": deviceId])
            .execute()
    }
}
