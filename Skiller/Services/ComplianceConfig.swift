import Foundation

/// 中国区 App Store 合规相关常量的单一来源。
///
/// 隐私/条款页托管在已 ICP 备案、大陆可稳定访问的域名 duskecho.com
/// （黔ICP备2025060250号-2，阿里云成都 ECS 8.137.115.144）的 /skiller/
/// 子路径下；该子路径同受站点备案覆盖，无需额外备案。
/// 不要用 GitHub Pages（isink.github.io）——它在大陆被 DNS 污染。
enum ComplianceConfig {

    /// 已备案站点上托管隐私/条款页的基地址，无结尾斜杠。
    /// 部署 docs/compliance/*.html 到该路径后即生效（见方案 Task 6）。
    static let legalBase = "https://duskecho.com/skiller"

    static var privacyURL: URL { URL(string: "\(legalBase)/privacy.html")! }
    static var termsURL: URL { URL(string: "\(legalBase)/terms.html")! }

    /// 工信部 App 备案号，按管局要求需在 app 内展示（见 ProfileView 备案行）。
    /// App 备案通过后填入；为空时备案行自动隐藏，开发构建照常编译。
    /// 注意：必须是 App 备案号（形如 `黔ICP备2025060250号-3A`），
    /// 不是网站备案号 `黔ICP备2025060250号-2`。
    static let icpFilingNumber = "黔ICP备2025060250号-3A"

    /// 工信部备案公共查询入口（备案号点击跳转）。
    static let icpQueryURL = URL(string: "https://beian.miit.gov.cn/")!

    /// 广告总开关。若中国区审核对 Google 广告 SDK 有异议，
    /// 改为 false 即可在不删依赖的前提下隐藏所有广告位。
    static let adsEnabled = true
}
