import SwiftUI

/// 首次启动隐私同意门。未同意前不展示主界面、不采集任何个人信息、
/// 不启动广告 SDK。同意状态由宿主持久化在 @AppStorage("privacyConsentAccepted")。
struct ConsentGateView: View {
    /// 用户点击"同意并继续"时回调（由宿主负责持久化并启动后续流程）。
    let onAccept: () -> Void

    @State private var showDeclineNote = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("Skiller")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Color.textPrimary)

            Text("welcome_consent_title")
                .font(.system(size: 15))
                .foregroundStyle(Color.textSubtle)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
                .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 10) {
                Text("consent_body_intro")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textSubtle)

                HStack(spacing: 4) {
                    Text("consent_read_prefix")
                    Link("privacy_policy", destination: ComplianceConfig.privacyURL)
                    Text("consent_and")
                    Link("terms_of_use", destination: ComplianceConfig.termsURL)
                }
                .font(.system(size: 13))
                .tint(Color.brand)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.textPrimary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 24)
            .padding(.top, 24)

            Spacer()

            Button(action: onAccept) {
                Text("consent_agree")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.brand)
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 24)

            Button {
                showDeclineNote = true
            } label: {
                Text("consent_decline")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textSubtle)
                    .padding(.vertical, 12)
            }
        }
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bg.ignoresSafeArea())
        .alert("consent_decline_title", isPresented: $showDeclineNote) {
            Button("consent_decline_back", role: .cancel) {}
        } message: {
            Text("consent_decline_message")
        }
    }
}
