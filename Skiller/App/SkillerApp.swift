import SwiftData
import SwiftUI
import UIKit

@main
struct SkillerApp: App {
    @StateObject private var auth = AuthService.shared
    @StateObject private var favoriteSync = FavoriteSyncCoordinator()
    @StateObject private var adConsent = AdConsentService()
    @AppStorage("privacyConsentAccepted") private var consentAccepted = false

    var body: some Scene {
        WindowGroup {
            Group {
                if consentAccepted {
                    RootTabView()
                        .environmentObject(auth)
                        .environmentObject(favoriteSync)
                        .environmentObject(adConsent)
                        .task {
                            auth.startListening()
                            await supabase.auth.startAutoRefresh()
                            await auth.bootstrap()
                            if ComplianceConfig.adsEnabled {
                                await adConsent.prepare()
                            }
                        }
                        .onOpenURL { url in
                            Task { await auth.handle(url: url) }
                        }
                        .onReceive(
                            NotificationCenter.default.publisher(
                                for: UIApplication.didBecomeActiveNotification)
                        ) { _ in
                            Task {
                                await favoriteSync.sync()
                            }
                        }
                } else {
                    ConsentGateView {
                        consentAccepted = true
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
        .modelContainer(for: [
            Favorite.self,
            AccountFavorite.self,
            PendingFavoriteMutation.self,
            LastSeen.self,
            RecentView.self,
        ])
    }
}
