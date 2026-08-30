import GoogleMobileAds
import SwiftUI
import UIKit

/// SwiftUI wrapper around Google Mobile Ads `BannerView`. Uses anchored
/// adaptive banner sizing (height auto-derived from device width).
struct BannerAdView: View {
    @EnvironmentObject private var adConsent: AdConsentService

    var body: some View {
        Group {
            if adConsent.canRequestAds {
                GeometryReader { geo in
                    BannerRepresentable(width: geo.size.width)
                }
                .frame(height: BannerAdView.height(for: UIScreen.main.bounds.width))
            }
        }
    }

    static func height(for width: CGFloat) -> CGFloat {
        let size = currentOrientationAnchoredAdaptiveBanner(width: width)
        return size.size.height
    }
}

private struct BannerRepresentable: UIViewRepresentable {
    let width: CGFloat

    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: currentOrientationAnchoredAdaptiveBanner(width: width))
        banner.adUnitID = AdConfig.bannerUnitID
        banner.rootViewController = topViewController()
        let request = Request()
        // Reinforce non-personalized treatment for this request.
        let extras = Extras()
        extras.additionalParameters = ["npa": "1"]
        request.register(extras)
        banner.load(request)
        return banner
    }

    func updateUIView(_ uiView: BannerView, context: Context) {
        uiView.adSize = currentOrientationAnchoredAdaptiveBanner(width: width)
    }
}

private func topViewController() -> UIViewController? {
    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
    else { return nil }
    var top = root
    while let presented = top.presentedViewController { top = presented }
    return top
}

enum AdConfig {
    /// Google's official iOS banner test ID — never tracks, never charges.
    static let testBannerUnitID = "ca-app-pub-3940256099942544/2934735716"

    /// Production banner ad unit for the Skiller iOS app.
    static let prodBannerUnitID = "ca-app-pub-8372639947150676/9669151238"

    static var bannerUnitID: String {
        #if DEBUG
        return testBannerUnitID
        #else
        return prodBannerUnitID
        #endif
    }
}
