# Skiller 上线 App Store 中国区（最小可行路径）实施方案

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不迁移后端的前提下，补齐工信部 App 备案与 App Store 中国区合规改造，使现有 Skiller app 可在中国区上架。

**Architecture:** 保持 Supabase 后端与现有 supabase-swift 数据访问不动。仅新增「首次启动隐私同意门」、把隐私/条款页迁到已备案域名、把广告 SDK 与设备标识采集推迟到同意之后、app 内展示 App 备案号。备案与 App Store Connect 为流程性任务，穿插在代码任务前后。

**Tech Stack:** SwiftUI (Xcode 16, iOS 17+, xcodegen)、Supabase（不变）、阿里云已备案域名 + OSS 静态托管（仅托管 3 个 html）、工信部移动应用备案。

**验证方式说明：** 本工程 `project.yml` 中 `testTargets: []`，无 Swift 测试 target。强行引入 XCTest/UITest 框架属于范围蔓延，与本任务"最小可行"目标冲突。因此代码任务的验证采用：`xcodegen generate` → 构建 → 模拟器运行 → 人工观察指定行为。这是基于项目现状的有意取舍。

**需求校验关卡（重要）：** 本方案到「上架并可被中国区用户安装」为止。**不要**在拿到真实国区安装/留存数据之前启动任何 Supabase→阿里云后端迁移——那是可选优化，不是上架前提，提前做即落入"大而全"陷阱。Phase 4 给出该关卡的具体判据。

---

## File Structure

| 文件 | 职责 | 动作 |
|---|---|---|
| `Skiller/Services/ComplianceConfig.swift` | 合规相关常量单一来源：已备案域名、隐私/条款 URL、App 备案号、广告开关 | 新建 |
| `Skiller/Views/ConsentGateView.swift` | 首次启动隐私同意全屏门 | 新建 |
| `Skiller/App/SkillerApp.swift` | 同意前不启动广告 SDK、不采集设备标识、不触发网络 | 修改 |
| `Skiller/Views/ProfileView.swift` | 隐私/条款指向已备案域名；新增备案号展示行 | 修改 |
| `Skiller/Views/SkillDetailView.swift` | 广告位受 `adsEnabled` 开关控制 | 修改 |
| `Skiller/Resources/zh-Hans.lproj/Localizable.strings` | 新增同意门/备案号中文文案 | 修改 |
| `Skiller/Resources/en.lproj/Localizable.strings` | 新增对应英文文案 | 修改 |
| `docs/compliance/{index,privacy,terms}.html` | 迁出 GitHub Pages 的页面（已抓取暂存，待上传到已备案域名） | 已新建 |

---

## Phase 0 — App 备案（流程，0 代码，**硬前置**，可与代码任务并行推进）

> Apple 自 2024 年起强制：上架/留在中国区的 app 必须有工信部移动应用备案号，否则下架。你当前只有**域名 ICP 备案**，缺**App 备案**。这是材料+审核，约数周，需尽早启动。

### Task 0: 提交工信部 App 备案

**Files:** 无代码改动。

- [ ] **Step 1: 确认备案主体（已具备）**
  主体见阿里云备案控制台，ICP 主体备案号 `黔ICP备2025060250号`，已备案域名 `duskecho.com`（网站备案号 `黔ICP备2025060250号-2`，管局审核通过），阿里云成都 ECS `8.137.115.144`。App 备案复用此主体与域名/云资源。

- [ ] **Step 2: 在阿里云备案控制台提交 App 备案**
  备案控制台 → 我的 ICP 备案信息 → 互联网信息服务 → 切到 **「App」标签页**（与「网站」并列）→ 新增 App 备案。填写：app 名称（Skiller）、Bundle ID `com.iskill.app`、应用分类、复用现有主体、关联域名 `duskecho.com` / ECS `8.137.115.144`。
  Expected: 生成一条"待审核"的 App 备案订单。

- [ ] **Step 3: 等待管局审核并记录备案号**
  审核通过后记录 App 备案号（形如 `沪ICP备2026XXXXXX号-2A`）。该号将填入 Task 1 的 `ComplianceConfig.icpFilingNumber` 与 Phase 3 的 App Store Connect。

- [ ] **Step 4: 标记关卡**
  备案号未下来之前，代码任务可全部完成（footer 行在备案号为空时自动隐藏），但**不可向 App Store 中国区提交审核**。

---

## Phase 1 — 代码合规改造

### Task 1: 合规配置单一来源

**Files:**
- Create: `Skiller/Services/ComplianceConfig.swift`

- [ ] **Step 1: 新建配置文件**

```swift
import Foundation

/// 中国区 App Store 合规相关常量的单一来源。
///
/// `legalHost` 必须是一个已完成 ICP 备案、在中国大陆可稳定访问的域名
/// （privacy.html / terms.html 托管在该域名下）。
/// 提交中国区审核前，把下面的值替换为你的阿里云已备案域名。
/// 不要用 GitHub Pages（isink.github.io）——它在大陆被 DNS 污染。
///
/// 这是一个"必须由你提供的部署输入"（类似 API key），不是占位符：
/// 保留默认 sentinel 时项目仍可编译、可在开发期运行，仅在中国区提交前必须替换。
enum ComplianceConfig {

    /// 已备案站点上托管隐私/条款页的基地址，无结尾斜杠。
    /// duskecho.com 已完成 ICP 备案（黔ICP备2025060250号-2，
    /// 阿里云成都 ECS 8.137.115.144），子路径同受该备案覆盖，无需额外备案。
    /// 部署 docs/compliance/*.html 到该路径后即生效（见 Task 6）。
    static let legalBase = "https://duskecho.com/skiller"

    static var privacyURL: URL { URL(string: "\(legalBase)/privacy.html")! }
    static var termsURL: URL { URL(string: "\(legalBase)/terms.html")! }

    /// 工信部 App 备案号，按管局要求需在 app 内展示（见 ProfileView 备案行）。
    /// Phase 0 备案通过后填入；为空时备案行自动隐藏，开发构建照常编译。
    /// 例：`"沪ICP备2026XXXXXX号-2A"`
    static let icpFilingNumber = ""

    /// 工信部备案公共查询入口（备案号点击跳转）。
    static let icpQueryURL = URL(string: "https://beian.miit.gov.cn/")!

    /// 广告总开关。若中国区审核对 Google 广告 SDK 有异议，
    /// 改为 false 即可在不删依赖的前提下隐藏所有广告位。
    static let adsEnabled = true
}
```

- [ ] **Step 2: 生成工程并构建验证**

Run: `cd <repo> && xcodegen generate && xcodebuild -scheme Skiller -destination 'platform=iOS Simulator,name=iPhone 16' build -quiet`
Expected: 构建成功（新文件被纳入 target，无引用错误）。

- [ ] **Step 3: 提交**

```bash
git add Skiller/Services/ComplianceConfig.swift
git commit -m "feat(compliance): add ComplianceConfig single source for CN App Store"
```

---

### Task 2: 首次启动隐私同意门

> 当前 `SkillerApp.init()` 立即 `MobileAds.shared.start()`，`didBecomeActive` 立即用 `identifierForVendor` 采集 `device_id` 写入 `app_opens`——**在用户同意隐私政策之前就启动广告 SDK 并采集设备标识**，这是中国区明确的拒审点。本任务加一道同意门，把这两件事推迟到用户明确同意之后。

**Files:**
- Create: `Skiller/Views/ConsentGateView.swift`
- Modify: `Skiller/App/SkillerApp.swift`

- [ ] **Step 1: 新建同意门视图**

```swift
import SwiftUI

/// 首次启动隐私同意门。未同意前不展示主界面、不采集任何个人信息、
/// 不启动广告 SDK。同意状态持久化在 @AppStorage("privacyConsentAccepted")。
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
```

- [ ] **Step 2: 改写 SkillerApp.swift —— 同意前不启动广告 / 不采集标识 / 不触发主界面网络**

完整替换 `Skiller/App/SkillerApp.swift` 为：

```swift
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
```

注意关键变化：
- `init()` 中的 `MobileAds.shared.start` 已移除——改为仅在 `onAccept` 后调用，且受 `adsEnabled` 控制。
- 未同意时只渲染 `ConsentGateView`，`RootTabView`（及其所有 Supabase 网络）与 `auth.bootstrap()` 不触发。
- `recordAppOpen()` 增加 `consentAccepted` 双重保险。
- 已同意的老用户：`@AppStorage` 默认 false，老用户升级后会再看到一次同意门——这是合规所需，可接受。

- [ ] **Step 3: 构建并人工验证**

Run: `cd <repo> && xcodegen generate && xcodebuild -scheme Skiller -destination 'platform=iOS Simulator,name=iPhone 16' build -quiet`
Expected: 构建成功。
人工验证（模拟器，先重置 app 数据或用全新模拟器）：
1. 首次启动 → 显示 ConsentGateView，**未**出现主界面、**无**网络请求。
2. 点"暂不同意"→ 弹说明 alert，停留在门内。
3. 点"同意并继续"→ 进入 RootTabView，此后才有 supabase / 广告请求。
4. 杀进程重开 → 直接进主界面（同意状态已持久化）。

- [ ] **Step 4: 提交**

```bash
git add Skiller/Views/ConsentGateView.swift Skiller/App/SkillerApp.swift
git commit -m "feat(compliance): gate ad SDK & device-id collection behind first-launch consent"
```

---

### Task 3: 隐私/条款指向已备案域名 + app 内展示备案号

> `ProfileView.swift` 的 `privacyFootnote`（约 441–466 行）当前硬编码 `https://isink.github.io/skiller/privacy.html` 与 `.../terms.html`。改为引用 `ComplianceConfig`，并新增工信部备案号展示行（管局要求 app 内可见）。

**Files:**
- Modify: `Skiller/Views/ProfileView.swift`（`privacyFootnote` 计算属性，约 441–466 行）

- [ ] **Step 1: 完整替换 privacyFootnote 计算属性为**

```swift
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
```

- [ ] **Step 2: 构建并人工验证**

Run: `cd <repo> && xcodegen generate && xcodebuild -scheme Skiller -destination 'platform=iOS Simulator,name=iPhone 16' build -quiet`
Expected: 构建成功。Profile 底部链接打开 `https://duskecho.com/skiller/...`；`icpFilingNumber` 为空不显示备案行，临时填值后显示且跳 beian.miit.gov.cn。

- [ ] **Step 3: 提交**

```bash
git add Skiller/Views/ProfileView.swift
git commit -m "feat(compliance): point legal links to beian domain, show ICP filing no."
```

---

### Task 4: 广告位受 adsEnabled 总开关控制

**Files:**
- Modify: `Skiller/Views/SkillDetailView.swift:101`

- [ ] **Step 1: 用 adsEnabled 包裹广告位**

把 `SkillDetailView.swift` 第 101 行 `BannerAdView()` 替换为：

```swift
                if ComplianceConfig.adsEnabled {
                    BannerAdView()
                }
```

- [ ] **Step 2: 构建并人工验证**

Run: `cd <repo> && xcodegen generate && xcodebuild -scheme Skiller -destination 'platform=iOS Simulator,name=iPhone 16' build -quiet`
Expected: 构建成功。`adsEnabled=true` 详情页有 banner；改 false 重建后无 banner。

- [ ] **Step 3: 提交**

```bash
git add Skiller/Views/SkillDetailView.swift
git commit -m "feat(compliance): gate banner ad behind ComplianceConfig.adsEnabled"
```

---

### Task 5: 同意门 / 备案号 文案本地化

**Files:**
- Modify: `Skiller/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `Skiller/Resources/en.lproj/Localizable.strings`

- [ ] **Step 1: 追加中文文案（zh-Hans.lproj/Localizable.strings 末尾）**

```
"welcome_consent_title" = "在使用前，请阅读并同意以下条款";
"consent_body_intro" = "我们仅在你同意后采集必要信息（如设备标识用于统计与广告）。你可随时在系统设置中撤回。";
"consent_read_prefix" = "我已阅读并同意";
"consent_and" = "和";
"consent_agree" = "同意并继续";
"consent_decline" = "暂不同意";
"consent_decline_title" = "需要同意才能使用";
"consent_decline_message" = "Skiller 需要你同意隐私政策与用户协议后才能提供服务。你可以稍后再决定。";
"consent_decline_back" = "返回";
"privacy_policy" = "隐私政策";
"terms_of_use" = "用户协议";
```

- [ ] **Step 2: 追加英文文案（en.lproj/Localizable.strings 末尾）**

```
"welcome_consent_title" = "Please read and agree to the terms before using";
"consent_body_intro" = "We only collect necessary data (e.g. device identifier for analytics and ads) after you agree. You can withdraw consent anytime in Settings.";
"consent_read_prefix" = "I have read and agree to the";
"consent_and" = "and";
"consent_agree" = "Agree and Continue";
"consent_decline" = "Not now";
"consent_decline_title" = "Consent required";
"consent_decline_message" = "Skiller needs your agreement to the Privacy Policy and Terms of Use to provide service. You can decide later.";
"consent_decline_back" = "Back";
"privacy_policy" = "Privacy Policy";
"terms_of_use" = "Terms of Use";
```

- [ ] **Step 3: 构建并人工验证**

Run: `cd <repo> && xcodegen generate && xcodebuild -scheme Skiller -destination 'platform=iOS Simulator,name=iPhone 16' build -quiet`
Expected: 构建成功。中文系统语言下同意门为中文，英文下为英文，无 key 名裸露。

- [ ] **Step 4: 提交**

```bash
git add Skiller/Resources/zh-Hans.lproj/Localizable.strings Skiller/Resources/en.lproj/Localizable.strings
git commit -m "feat(compliance): localize consent gate & ICP strings (zh-Hans/en)"
```

---

## Phase 2 — 隐私/条款页迁出 GitHub Pages 到已备案域名

> GitHub 原站点为 3 个自包含 html（`index.html` 跳转 → `privacy.html`、`terms.html`），纯内联 CSS、无外部资源。已抓取暂存到 `docs/compliance/`。

### Task 6: 内容补齐 + 部署到已备案域名

**Files:**
- `docs/compliance/{index,privacy,terms}.html`（已抓取；需按下列补齐后部署）

- [ ] **Step 1: 隐私政策内容补齐（人工，合规实质项）**
  现有 privacy.html 为英文且与代码现状不一致，按中国区要求补齐：
  - 增加中文版本（中国区合规需中文可读）。
  - 如实披露 `identifierForVendor`（设备标识）经 `app_opens` 采集用于统计——现文案声称"无个人广告标识"但未说明设备标识统计采集，需补。
  - 披露数据存储于 Supabase（境外服务器）及**跨境传输**情况（PIPL 要求）。
  - 增加"首次启动需同意后方采集"的说明，与 Task 2 同意门一致。

- [ ] **Step 2: 部署到 duskecho.com 的 /skiller/ 路径（阿里云成都 ECS 8.137.115.144）**
  在 ECS 上把 3 个文件放到 web 根目录的 `skiller/` 子目录，使其经现有 `duskecho.com` 站点以 `https://duskecho.com/skiller/{index,privacy,terms}.html` 提供。
  Expected: 用手机蜂窝网络（非代理）实测 3 个 URL 均可直接访问。

- [ ] **Step 3: 提交（legalBase 已在 Task 1 设为最终值，无需回填）**

```bash
cd <repo> && xcodegen generate && xcodebuild -scheme Skiller -destination 'platform=iOS Simulator,name=iPhone 16' build -quiet
git add docs/compliance/ Skiller/Services/ComplianceConfig.swift
git commit -m "chore(compliance): host privacy/terms on beian domain, set legalHost"
```

---

## Phase 3 — App Store Connect 中国区上架（流程清单）

### Task 7: App Store Connect 配置与提审

**Files:** 无代码改动（App Store Connect 网页操作）。

- [ ] **Step 1:** 价格与销售范围 → 勾选「中国大陆」。
- [ ] **Step 2:** App 信息 → 中国大陆 App 备案 → 填入 Phase 0 备案号；确认 app 内 footer 行展示同一号。
- [ ] **Step 3:** 补齐 zh-Hans 名称/副标题/描述/关键词/中文截图。
- [ ] **Step 4:** 支持 URL 与隐私政策 URL 均填**已备案域名**可达地址（不要 isink.github.io）。
- [ ] **Step 5:** 年龄分级如实填写；审核备注说明 UGC 先审后显（`apply-agent-decision` 流程）+ 详情页举报入口。
- [ ] **Step 6:** 出口合规：`ITSAppUsesNonExemptEncryption` 已为 false（project.yml），答复保持一致。
- [ ] **Step 7:** 审核账号：支持 Sign in with Apple，审核员可直接登录；Supabase 在审核员所在地（美国）可访问，无需改动。
- [ ] **Step 8:** 确认备案号已下且填入 app + ASC 后，经 Xcode Cloud 构建上传并提交中国区审核。

---

## Phase 4 — 上架后：需求校验关卡（不要跳过）

### Task 8: 决定是否值得做后端迁移

- [ ] **Step 1:** 上架后观察 2–4 周：中国区下载量、次日/7 日留存、`app_opens` 中国区设备数、加载失败/流失迹象。
- [ ] **Step 2:** 用判据决策：
  - 国区活跃少（如 < 数百）或留存差 → **不迁移**，问题在需求不在后端，停在此处。
  - 有可观活跃**且**有证据 Supabase 延迟/失败拖累体验 → 此时才另起独立的「后端迁移」方案。
  - 默认：无数据 = 不迁移。

---

## Self-Review

- **Spec 覆盖**：App 备案(Phase0/Task7-2) ✓；备案号 app 内展示(Task1/3) ✓；隐私/条款迁出 GitHub Pages(Task1/3/6) ✓；首启同意门 + 同意前不收集/不启广告(Task2) ✓；广告可关(Task1/4) ✓；本地化(Task5) ✓；ASC 中国区(Task7) ✓；防大而全关卡(Task8) ✓。已具备项（账号注销、举报、先审后显、Apple 登录）分析中已确认，无需任务。
- **占位符扫描**：`legalBase` 已设为真实值 `https://duskecho.com/skiller`（部署目标确定）；`icpFilingNumber=""` 是"待 Phase 0 App 备案通过后填入"的部署输入，非计划占位符——为空时备案行自动隐藏，开发构建照常编译。
- **类型一致性**：`ComplianceConfig.{legalBase,privacyURL,termsURL,icpFilingNumber,icpQueryURL,adsEnabled}` Task1 定义，Task2/3/4 引用一致；`ConsentGateView(onAccept:)` Task2-1 定义、Task2-2 尾随闭包调用一致；本地化 key Task2 使用、Task5 两 lproj 同名补齐。

---

## Execution Handoff

方案保存于 `docs/superpowers/plans/2026-05-19-skiller-china-app-store-launch.md`（worktree `cn-app-store-launch`）。
两种执行方式：
1. **Subagent-Driven（推荐）** — 每 Task 派新 subagent，任务间双段评审
2. **Inline Execution** — 本会话分批执行带检查点
