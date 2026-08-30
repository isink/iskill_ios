import AuthenticationServices
import SwiftData
import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var favoriteSync: FavoriteSyncCoordinator
    @EnvironmentObject private var adConsent: AdConsentService
    @Query private var recents: [RecentView]
    @State private var signingIn = false
    @State private var authError: String? = nil
    @State private var appleNonce: String? = nil
    @State private var showDeleteConfirm = false
    @State private var deleting = false
    @State private var showGitHubLogin = false

    private var topCategorySlug: String? {
        guard !recents.isEmpty else { return nil }
        let grouped = Dictionary(grouping: recents, by: \.category)
        return grouped.max(by: { $0.value.count < $1.value.count })?.key
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                brandHeader
                accountCard
                footprintCard

                section(title: "Resources") {
                    linkRow(
                        icon: "chevron.left.forwardslash.chevron.right",
                        title: "Anthropic Official Skills",
                        subtitle: "github.com/anthropics/skills",
                        url: "https://github.com/anthropics/skills"
                    )
                    divider
                    linkRow(
                        icon: "book.fill",
                        title: "Claude Skills Documentation",
                        url: "https://docs.anthropic.com/en/docs/claude-code/skills-and-packages"
                    )
                }

                privacyFootnote
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .background(Color.bg.ignoresSafeArea())
        .navigationBarHidden(true)
    }

    // MARK: Brand
    private var brandHeader: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.brand.opacity(0.18))
                    .frame(width: 64, height: 64)
                Image(systemName: "sparkles")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color.brand)
            }
            Text("Skiller")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.textPrimary)
            Text("Discover and install Claude AI skills")
                .font(.system(size: 12))
                .foregroundStyle(Color.textSubtle)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: Account
    @ViewBuilder
    private var accountCard: some View {
        switch auth.state {
        case .unknown:
            EmptyView()
        case .signedOut:
            signedOutCard
        case .signedIn(let identity):
            signedInCard(identity)
        }
    }

    private var signedOutCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to sync favorites across devices")
                .font(.system(size: 13))
                .foregroundStyle(Color.textSubtle)

            SignInWithAppleButton(
                .signIn,
                onRequest: { request in
                    let nonce = AuthService.makeRawNonce()
                    appleNonce = nonce
                    request.requestedScopes = [.fullName, .email]
                    request.nonce = AuthService.sha256Hex(nonce)
                },
                onCompletion: { result in
                    Task { await handleAppleResult(result) }
                }
            )
            .signInWithAppleButtonStyle(.white)
            .frame(height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showGitHubLogin.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Spacer()
                    Text("Other sign-in options")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textSubtle)
                    Image(systemName: showGitHubLogin ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.textSubtle)
                    Spacer()
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showGitHubLogin {
                Button {
                    Task { await signIn() }
                } label: {
                    HStack(spacing: 8) {
                        if signingIn {
                            ProgressView().tint(.black)
                        } else {
                            Image("GitHubMark")
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 16, height: 16)
                        }
                        Text(signingIn ? "Signing in…" : "Sign in with GitHub")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(.black)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(signingIn)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let msg = authError {
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgCard)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.borderSubtle, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func signedInCard(_ identity: AuthService.UserIdentity) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                avatar(identity.avatarUrl)
                VStack(alignment: .leading, spacing: 2) {
                    Text(identity.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text("@\(identity.login)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textSubtle)
                }
                Spacer()
                Button {
                    Task { await auth.signOut() }
                } label: {
                    Text("Sign Out")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.textSubtle)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.bg)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.borderSubtle, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            HStack {
                Spacer()
                Button {
                    showDeleteConfirm = true
                } label: {
                    HStack(spacing: 4) {
                        if deleting { ProgressView().tint(.red).scaleEffect(0.7) }
                        Text(deleting ? "Deleting…" : "Delete account")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .underline(true, color: .red.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)
                .disabled(deleting)
            }

            favoriteSyncStatus

            if let msg = authError {
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgCard)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.borderSubtle, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .alert("Delete account?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                Task { await deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Will permanently delete your Skiller account and synced favorites. Guest favorites and other accounts stay on this device. This cannot be undone.")
        }
    }

    @ViewBuilder
    private var favoriteSyncStatus: some View {
        if favoriteSync.isSyncing {
            Label("Syncing favorites…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(Color.textSubtle)
        } else if favoriteSync.pendingCount > 0 {
            Button {
                Task { await favoriteSync.sync() }
            } label: {
                Label(
                    String(
                        format: String(localized: "Favorites pending sync: %lld"),
                        Int64(favoriteSync.pendingCount)
                    ),
                    systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                )
            }
            .foregroundStyle(Color.brand)
        } else if favoriteSync.lastSyncError != nil {
            Button {
                Task { await favoriteSync.sync() }
            } label: {
                Label("Favorite sync failed — retry", systemImage: "exclamationmark.triangle")
            }
            .foregroundStyle(Color.brand)
        } else {
            Label("Favorites synced", systemImage: "checkmark.icloud")
                .foregroundStyle(Color.textSubtle)
        }
    }

    @MainActor
    private func deleteAccount() async {
        deleting = true
        authError = nil
        do {
            let deletedUserId = try await auth.deleteAccount()
            try favoriteSync.clearLocalAccountData(userId: deletedUserId.uuidString)
        } catch {
            print("Delete account failed: \(error)")
            authError = String(localized: "Delete failed, try again later or contact handwanly@gmail.com")
        }
        deleting = false
    }

    @ViewBuilder
    private func avatar(_ url: URL?) -> some View {
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Color.bg
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.borderSubtle, lineWidth: 1))
        } else {
            ZStack {
                Circle().fill(Color.brand.opacity(0.18))
                Image(systemName: "person.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.brand)
            }
            .frame(width: 40, height: 40)
        }
    }

    @MainActor
    private func signIn() async {
        signingIn = true
        authError = nil
        do {
            try await auth.signInWithGitHub()
        } catch {
            print("GitHub sign-in failed: \(error)")
            if !isUserCancelled(error) {
                authError = String(localized: "Sign-in failed, try again later")
            }
        }
        signingIn = false
    }

    @MainActor
    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let authResult):
            guard
                let credential = authResult.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let token = String(data: tokenData, encoding: .utf8),
                let nonce = appleNonce
            else {
                authError = String(localized: "Apple sign-in failed, try again later")
                return
            }
            do {
                try await auth.signInWithApple(idToken: token, nonce: nonce)
                authError = nil
            } catch {
                print("Apple sign-in failed: \(error)")
                authError = String(localized: "Apple sign-in failed, try again later")
            }
        case .failure(let error):
            print("Apple sign-in failed: \(error)")
            if !isUserCancelled(error) {
                authError = String(localized: "Apple sign-in failed, try again later")
            }
        }
        appleNonce = nil
    }

    private func isUserCancelled(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == "com.apple.AuthenticationServices.WebAuthenticationSession" && ns.code == 1 {
            return true
        }
        if ns.domain == ASAuthorizationError.errorDomain
            && ns.code == ASAuthorizationError.canceled.rawValue {
            return true
        }
        return false
    }

    // MARK: Footprint
    private var footprintCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.brand)
                Text("My footprint")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.textSubtle)
            }

            HStack(spacing: 0) {
                stat(value: "\(favoriteSync.favoriteIDs.count)", label: String(localized: "Favorited"))
                statDivider
                stat(value: "\(recents.count)", label: String(localized: "Browsed"))
                statDivider
                topStat
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgCard)
        .overlay(
            RoundedRectangle(cornerRadius: 16).strokeBorder(Color.borderSubtle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func stat(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.textPrimary)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.textSubtle)
        }
        .frame(maxWidth: .infinity)
    }

    private var topStat: some View {
        VStack(spacing: 4) {
            if let slug = topCategorySlug {
                HStack(spacing: 4) {
                    Image(systemName: CategoryMeta.sfSymbol(slug))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.brand)
                    Text(CategoryMeta.displayName(slug))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.textPrimary)
                }
                .frame(height: 30)
            } else {
                Text("—")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.textSubtle)
                    .frame(height: 30)
            }
            Text("Most viewed")
                .font(.system(size: 11))
                .foregroundStyle(Color.textSubtle)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Color.borderSubtle)
            .frame(width: 1, height: 36)
    }

    // MARK: Section
    private func section<Content: View>(
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.textSubtle)
                .tracking(1.4)
                .textCase(.uppercase)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .background(Color.bgCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 16).strokeBorder(Color.borderSubtle, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.borderSubtle)
            .frame(height: 1)
            .padding(.leading, 50)
    }

    // MARK: Privacy footnote
    private var privacyFootnote: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                Spacer()
                Link(destination: ComplianceConfig.privacyURL) {
                    Text("Privacy Policy")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textSubtle)
                        .underline(true, color: Color.textSubtle.opacity(0.5))
                }
                Link(destination: ComplianceConfig.termsURL) {
                    Text("Terms of Use")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textSubtle)
                        .underline(true, color: Color.textSubtle.opacity(0.5))
                }
                Link(destination: URL(string: "mailto:handwanly@gmail.com?subject=Skiller%20Feedback")!) {
                    Text("Feedback")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textSubtle)
                        .underline(true, color: Color.textSubtle.opacity(0.5))
                }
                Spacer()
            }

            if adConsent.isPrivacyOptionsRequired {
                Button("Ad Privacy Options") {
                    Task { await adConsent.presentPrivacyOptions() }
                }
                .font(.caption)
                .foregroundStyle(Color.textSubtle)
                .underline(true, color: Color.textSubtle.opacity(0.5))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }

            if !ComplianceConfig.icpFilingNumber.isEmpty {
                Link(destination: ComplianceConfig.icpQueryURL) {
                    Text(ComplianceConfig.icpFilingNumber)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.textSubtle.opacity(0.7))
                }
            }
        }
        .padding(.top, 16)
    }

    private func linkRow(icon: String, title: LocalizedStringKey, subtitle: String? = nil, url: String) -> some View {
        Link(destination: URL(string: url) ?? URL(string: "https://example.com")!) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.brand)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.textSubtle)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textSubtle)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
    }
}
