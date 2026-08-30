import SwiftUI

struct SkillCard: View {
    let skill: Skill
    var showInstall: Bool = false

    @EnvironmentObject private var favoriteSync: FavoriteSyncCoordinator

    private var isFavorited: Bool { favoriteSync.favoriteIDs.contains(skill.id) }

    private var chips: [String] {
        let useCases = skill.localizedUseCases
        if !useCases.isEmpty {
            return Array(useCases.prefix(3))
        }
        return skill.tags
            .filter { !["claude", "codex", "cursor"].contains($0) }
            .prefix(3)
            .map { $0 }
    }

    private var installCommand: String { "claude skill install \(skill.slug)" }

    var body: some View {
        NavigationLink(value: SkillRoute.detail(skill.id)) {
            VStack(alignment: .leading, spacing: 0) {
                // Top row
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(skill.name)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(1)
                            if skill.featured {
                                Text("Official")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.brand)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.brand.opacity(0.2))
                                    .clipShape(Capsule())
                            }
                        }
                        HStack(spacing: 4) {
                            if let stars = Format.stars(skill.githubStars) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color(hex: 0xF5B400))
                                Text(stars)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.textSubtle)
                                Text("·")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.textSubtle)
                            }
                            Text("\(Format.author(skill.author)) · \(Format.timeAgo(skill.publishedAt ?? skill.createdAt))")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.textSubtle)
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        toggleFavorite()
                    } label: {
                        Image(systemName: isFavorited ? "heart.fill" : "heart")
                            .font(.system(size: 20))
                            .foregroundStyle(isFavorited ? Color.brand : Color.textSubtle)
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // Description
                Text(skill.localizedDescription)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textMuted)
                    .lineLimit(2)
                    .lineSpacing(2)
                    .padding(.top, 8)

                // Chips
                if !chips.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(chips, id: \.self) { chip in
                            Text(chip)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.brand)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.brand.opacity(0.1))
                                .overlay(
                                    Capsule().strokeBorder(Color.brand.opacity(0.3), lineWidth: 1)
                                )
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.top, 12)
                }

                if showInstall {
                    InstallChip(command: installCommand) { copyInstall() }
                        .padding(.top, 12)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.bgCard)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.borderSubtle, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private func toggleFavorite() {
        favoriteSync.toggle(skill.id)
    }

    private func copyInstall() {
        UIPasteboard.general.string = installCommand
        Task { await SkillsAPI.incrementInstallCount(skill.id) }
    }
}

private struct InstallChip: View {
    let command: String
    let onTap: () -> Void
    @State private var copied = false

    var body: some View {
        Button {
            onTap()
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { copied = false }
        } label: {
            HStack {
                Text(command)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.textMuted)
                    .lineLimit(1)
                Spacer()
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 14))
                    .foregroundStyle(copied ? Color.accentGreen : Color.brand)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.bgElevated)
            .overlay(
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.borderDefault, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
