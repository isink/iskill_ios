import MarkdownUI
import SwiftData
import SwiftUI

struct SkillDetailView: View {
    let skillId: String
    @Environment(\.modelContext) private var ctx
    @EnvironmentObject private var favoriteSync: FavoriteSyncCoordinator
    @State private var skill: Skill?
    @State private var loading = true
    @State private var selectedAgent: AgentId = .claude
    @State private var copiedCommand = false
    @State private var copiedRaw = false
    @State private var showReportSheet = false

    enum AgentId: String, CaseIterable, Hashable {
        case claude, codex, cursor

        var label: String {
            switch self {
            case .claude: return "Claude"
            case .codex:  return "Codex"
            case .cursor: return "Cursor"
            }
        }

        func command(_ slug: String) -> String { "\(rawValue) skill install \(slug)" }
    }

    private var isFavorited: Bool { favoriteSync.favoriteIDs.contains(skillId) }

    private var supportedAgents: [AgentId] {
        guard let skill else { return [.claude] }
        let tagSet = Set(skill.tags)
        let found = AgentId.allCases.filter { tagSet.contains($0.rawValue) }
        return found.isEmpty ? [.claude] : found
    }

    var body: some View {
        Group {
            if let skill {
                content(skill)
            } else if loading {
                ProgressView().tint(Color.brand).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyState(icon: "exclamationmark.triangle", title: "Skill not found")
            }
        }
        .background(Color.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.bg, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { toggleFav() } label: {
                    Image(systemName: isFavorited ? "heart.fill" : "heart")
                        .foregroundStyle(isFavorited ? Color.brand : Color.textMuted)
                }
            }
            if let skill {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: skill.githubUrl) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(Color.textMuted)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showReportSheet = true
                        } label: {
                            Label("Report this skill", systemImage: "flag")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(Color.textMuted)
                    }
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showReportSheet) {
            if let skill {
                ReportSkillSheet(skill: skill)
            }
        }
    }

    @ViewBuilder
    private func content(_ skill: Skill) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(skill)
                installBlock(skill)
                metaBlock(skill)
                if ComplianceConfig.adsEnabled {
                    BannerAdView()
                        .padding(.top, 8)
                }
                if let md = skill.skillMdContent, !md.isEmpty {
                    markdownBlock(md)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
    }

    private func header(_ skill: Skill) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(skill.name)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.textPrimary)
                if skill.featured {
                    Text("Official")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.brand)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.brand.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
            HStack(spacing: 4) {
                if let stars = Format.stars(skill.githubStars) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: 0xF5B400))
                    Text(stars).font(.system(size: 12)).foregroundStyle(Color.textSubtle)
                    Text("·").font(.system(size: 12)).foregroundStyle(Color.textSubtle)
                }
                Text("\(Format.author(skill.author)) · \(Format.timeAgo(skill.publishedAt ?? skill.createdAt))")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textSubtle)
            }
            Text(skill.localizedDescription)
                .font(.system(size: 15))
                .foregroundStyle(Color.textMuted)
                .lineSpacing(3)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func installBlock(_ skill: Skill) -> some View {
        let agents = supportedAgents
        let active = agents.contains(selectedAgent) ? selectedAgent : agents[0]
        let command = active.command(skill.slug)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Install Command")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.textSubtle)

            if agents.count > 1 {
                HStack(spacing: 8) {
                    ForEach(agents, id: \.self) { a in
                        Button { selectedAgent = a } label: {
                            Text(a.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(active == a ? Color.textPrimary : Color.textSubtle)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(active == a ? Color.bgElevated : Color.clear)
                                .overlay(Capsule().strokeBorder(active == a ? Color.borderDefault : Color.borderSubtle, lineWidth: 1))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button { copyCommand(command) } label: {
                HStack {
                    Text(command)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: copiedCommand ? "checkmark.circle.fill" : "doc.on.doc")
                        .foregroundStyle(copiedCommand ? Color.accentGreen : Color.brand)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Color.bgElevated)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.borderDefault, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgCard)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.borderSubtle, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func markdownBlock(_ md: String) -> some View {
        let body = stripFrontmatter(md)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SKILL.md")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textSubtle)
                Spacer()
                Button {
                    UIPasteboard.general.string = md
                    copiedRaw = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copiedRaw = false }
                } label: {
                    Image(systemName: copiedRaw ? "checkmark.circle.fill" : "doc.on.doc")
                        .foregroundStyle(copiedRaw ? Color.accentGreen : Color.brand)
                }.buttonStyle(.plain)
            }

            Markdown(body)
                .markdownTheme(.skiller)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// SKILL.md 顶部的 YAML frontmatter（`--- ... ---`）是给 Claude 解析用的元数据，
    /// 在 UI 上展示属于噪音，渲染前剥掉。复制按钮仍传原始内容。
    private func stripFrontmatter(_ md: String) -> String {
        guard md.hasPrefix("---") else { return md }
        let pattern = #"^---\s*\n[\s\S]*?\n---\s*\n?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return md }
        let range = NSRange(md.startIndex..., in: md)
        let stripped = regex.stringByReplacingMatches(in: md, options: [], range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func metaBlock(_ skill: Skill) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("More")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.textSubtle)
            Link(destination: URL(string: skill.githubUrl) ?? URL(string: "https://github.com")!) {
                HStack {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(Color.brand)
                    Text("View on GitHub")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textSubtle)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgCard)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.borderSubtle, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func copyCommand(_ cmd: String) {
        UIPasteboard.general.string = cmd
        copiedCommand = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copiedCommand = false }
        Task { await SkillsAPI.incrementInstallCount(skillId) }
    }

    private func toggleFav() {
        favoriteSync.toggle(skillId)
    }

    @MainActor
    private func load() async {
        let (stale, freshTask) = await SkillsCache.shared.skillById(skillId)
        if let stale {
            skill = stale
            loading = false
        } else {
            loading = true
        }
        if let fresh = await freshTask.value {
            skill = fresh
        }
        loading = false
        if let s = skill {
            RecentViewStore.record(ctx, skillId: s.id, category: s.category)
        }
    }
}

extension Theme {
    static let skiller: Theme = Theme()
        .text {
            ForegroundColor(Color.textMuted)
            FontSize(16)
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.5))
                .markdownMargin(top: 0, bottom: 12)
        }
        .heading1 { configuration in
            VStack(alignment: .leading, spacing: 0) {
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(24)
                        ForegroundColor(Color.textPrimary)
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 6)
            }
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(20)
                    ForegroundColor(Color.textPrimary)
                }
                .padding(.top, 14)
                .padding(.bottom, 6)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(17)
                    ForegroundColor(Color.textPrimary)
                }
                .padding(.top, 10)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.92))
            ForegroundColor(Color.brand)
            BackgroundColor(Color.bgElevated)
        }
        .codeBlock { configuration in
            configuration.label
                .padding(12)
                .background(Color.bgElevated)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .markdownTextStyle {
                    FontFamilyVariant(.monospaced)
                    FontSize(13)
                    ForegroundColor(Color.textPrimary)
                }
        }
        .link {
            ForegroundColor(Color.brand)
        }
}
