import CryptoKit
import Foundation
import Supabase

/// Holds the current Supabase auth session and exposes provider login flows.
/// SwiftUI views observe `state` to switch between guest and signed-in UI.
@MainActor
final class AuthService: ObservableObject {
    static let shared = AuthService()

    enum State: Equatable {
        case unknown
        case signedOut
        case signedIn(UserIdentity)

        var favoriteScope: FavoriteScope {
            switch self {
            case .unknown:
                return .unknown
            case .signedOut:
                return .guest
            case let .signedIn(identity):
                return .account(identity.userId.uuidString)
            }
        }
    }

    struct UserIdentity: Equatable {
        enum Provider: String, Equatable { case github, apple }
        let userId: UUID
        let provider: Provider
        let displayName: String
        let login: String
        let avatarUrl: URL?
    }

    @Published private(set) var state: State = .unknown

    private var listenerTask: Task<Void, Never>?

    private init() {}

    func startListening() {
        guard listenerTask == nil else { return }
        listenerTask = Task { [weak self] in
            guard let self else { return }
            for await change in supabase.auth.authStateChanges {
                await self.apply(session: change.session)
            }
        }
    }

    deinit { listenerTask?.cancel() }

    func bootstrap() async {
        do {
            let session = try await supabase.auth.session
            await apply(session: session)
        } catch {
            await apply(session: nil)
        }
    }

    /// Native callback URL — must match the entry in Supabase → Auth → URL Configuration → Redirect URLs.
    static let redirectURL = URL(string: "com.iskill.app://login-callback")!

    func signInWithGitHub() async throws {
        try await supabase.auth.signInWithOAuth(
            provider: .github,
            redirectTo: Self.redirectURL,
            scopes: "read:user"
        )
    }

    /// Exchanges an Apple ID token (from native Sign in with Apple) for a Supabase session.
    func signInWithApple(idToken: String, nonce: String) async throws {
        try await supabase.auth.signInWithIdToken(
            credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
        )
    }

    func signOut() async {
        try? await supabase.auth.signOut()
    }

    /// Deletes the current user's auth.users row via a SECURITY DEFINER RPC
    /// (gated on auth.uid()), then signs out locally. Required by App Store
    /// guideline 5.1.1(v).
    @discardableResult
    func deleteAccount() async throws -> UUID {
        guard case let .signedIn(identity) = state else {
            throw AuthServiceError.notSignedIn
        }
        try await supabase.rpc("delete_my_account").execute()
        do {
            try await supabase.auth.signOut()
        } catch {
            state = .signedOut
        }
        return identity.userId
    }

    /// Called from SceneDelegate / onOpenURL to complete OAuth.
    func handle(url: URL) async {
        do {
            try await supabase.auth.session(from: url)
        } catch {
            print("Auth callback failed: \(error)")
        }
    }

    // MARK: - Apple nonce helpers

    static func makeRawNonce(length: Int = 32) -> String {
        let chars: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        precondition(status == errSecSuccess, "Unable to generate nonce")
        return String(bytes.map { chars[Int($0) % chars.count] })
    }

    static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - Private

    private func apply(session: Session?) async {
        guard let session else {
            state = .signedOut
            return
        }
        let user = session.user
        let providerString = user.appMetadata["provider"]?.stringValue ?? ""
        let provider: UserIdentity.Provider = providerString == "apple" ? .apple : .github
        let identity: UserIdentity
        switch provider {
        case .github:
            identity = makeGitHubIdentity(user: user)
        case .apple:
            identity = makeAppleIdentity(user: user)
        }
        state = .signedIn(identity)
    }

    private func makeGitHubIdentity(user: User) -> UserIdentity {
        let meta = user.userMetadata
        let metaLogin = meta["user_name"]?.stringValue ?? meta["preferred_username"]?.stringValue
        let emailLogin = user.email?.split(separator: "@").first.map(String.init)
        let login = metaLogin ?? emailLogin ?? "github_user"
        let metaName = meta["full_name"]?.stringValue ?? meta["name"]?.stringValue
        let displayName = metaName ?? login
        let avatar = meta["avatar_url"]?.stringValue.flatMap(URL.init(string:))
        return UserIdentity(
            userId: user.id,
            provider: .github,
            displayName: displayName,
            login: login,
            avatarUrl: avatar
        )
    }

    private func makeAppleIdentity(user: User) -> UserIdentity {
        let meta = user.userMetadata
        let emailLogin = user.email?.split(separator: "@").first.map(String.init)
        let login = emailLogin ?? "apple_user"
        let metaName = meta["full_name"]?.stringValue ?? meta["name"]?.stringValue
        let displayName = metaName ?? String(localized: "Apple User")
        return UserIdentity(
            userId: user.id,
            provider: .apple,
            displayName: displayName,
            login: login,
            avatarUrl: nil
        )
    }
}

enum AuthServiceError: LocalizedError {
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return String(localized: "Sign in before deleting your account")
        }
    }
}
