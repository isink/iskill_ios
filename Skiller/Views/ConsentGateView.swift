import SwiftUI

/// 首次启动隐私同意门。未同意前不展示主界面，也不主动启动业务或广告服务。
/// 同意状态由宿主持久化在 @AppStorage("privacyConsentAccepted")。
struct ConsentGateView: View {
    /// 用户点击"同意并继续"时回调（由宿主负责持久化并启动后续流程）。
    let onAccept: () -> Void

    @State private var showDeclineNote = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    Text("Skiller")
                        .font(.largeTitle.bold())
                        .foregroundStyle(Color.textPrimary)

                    Text("welcome_consent_title")
                        .font(.body)
                        .foregroundStyle(Color.textSubtle)
                        .multilineTextAlignment(.center)
                        .padding(.top, 12)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("consent_body_intro")
                            .font(.callout)
                            .foregroundStyle(Color.textSubtle)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("consent_read_prefix")
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 4) {
                                    legalLinks
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    legalLinks
                                }
                            }
                        }
                        .font(.callout)
                        .tint(Color.brand)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color.textPrimary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.top, 24)
                }
                .padding(.horizontal, 24)
                .padding(.top, 56)
                .padding(.bottom, 24)
            }

            Button(action: onAccept) {
                Text("consent_agree")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Color.brand)
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 24)

            Button {
                showDeclineNote = true
            } label: {
                Text("consent_decline")
                    .font(.subheadline)
                    .foregroundStyle(Color.textSubtle)
                    .frame(minHeight: 44)
            }
        }
        .safeAreaPadding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bg.ignoresSafeArea())
        .alert("consent_decline_title", isPresented: $showDeclineNote) {
            Button("consent_decline_back", role: .cancel) {}
        } message: {
            Text("consent_decline_message")
        }
    }

    @ViewBuilder
    private var legalLinks: some View {
        Link("privacy_policy", destination: ComplianceConfig.privacyURL)
        Text("consent_and")
        Link("terms_of_use", destination: ComplianceConfig.termsURL)
    }
}
