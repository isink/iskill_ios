# Skiller 多设备收藏同步设计

**日期：** 2026-08-24

**状态：** 已完成对话设计，待书面确认

**范围：** 仅实现多设备收藏同步；安装流程、GitHub OAuth 权限和中文详情摘要分别在后续任务处理。

## 目标

让游客继续使用本地收藏；用户登录后，收藏能够在多台设备之间同步。弱网或离线操作必须立即在本机生效，联网后自动补传，不因远端旧数据覆盖用户尚未同步的操作。

## 非目标

- 不引入 Supabase Realtime；设备在启动、回到前台、进入收藏页或手动刷新时对账。
- 不增加长期后台任务或定时轮询。
- 不改变技能列表、搜索、推荐或详情内容结构。
- 不在这一任务中优化收藏详情的串行加载请求。
- 不部署、发布或合并未获单独授权的其他改动。

## 已确认的产品规则

1. 首次登录采用并集合并：游客收藏与云端收藏都保留。
2. 游客与账号、不同账号之间相互隔离。
3. 收藏操作本地优先；同步失败不回滚。
4. 同一账号、同一 Skill 的多次离线切换只保留最后状态。
5. 退出登录后不显示账号收藏；重新登录后恢复。
6. 删除账号时删除该账号的本地收藏、待同步操作和云端收藏，不影响游客或其他账号。
7. 不使用 Realtime；另一台设备在标准对账时机收敛到云端状态。

## 当前状态

- `Favorite` 是 SwiftData 本地模型，`skillId` 具有唯一约束，所有收藏均视为游客数据。
- `FavoritesStore` 直接增删本地 `Favorite`，没有远端调用。
- `SkillCard`、`SkillDetailView` 和 `FavoritesView` 直接查询本地 `Favorite`。
- Supabase 已有 `public.favorites(user_id, skill_id, created_at)`，主键为 `(user_id, skill_id)`，并启用了基于 `auth.uid()` 的 RLS。
- 登录页已承诺“登录后可在多设备间同步收藏”，但当前实现未兑现。

## 方案选择

### 采用：本地优先 + 待同步状态

本机持久化游客收藏、各账号收藏缓存和待同步操作。界面只读取当前范围。远端操作由单一协调器串行执行，失败时保留待同步状态，并在下一次触发时重试。

### 不采用：云端优先

云端优先会让收藏按钮等待网络，离线不可用，也不满足已经确认的本地优先规则。

### 不采用：Realtime

Realtime 能让两台同时打开的设备即时变化，但会增加连接生命周期、订阅恢复和耗电复杂度。当前需求只要求在启动、回前台或刷新时收敛，不需要常驻订阅。

## 本地数据模型

### `Favorite`

保留现有模型不变，只表示游客收藏。这样现有安装升级后无需迁移旧记录，原有收藏自然保留为游客数据。

字段：

- `skillId: String`，继续保持唯一。
- `createdAt: Date`。

### `AccountFavorite`

新增账号收藏缓存模型：

- `recordKey: String`，唯一值为 `"<userId>|<skillId>"`。
- `userId: String`。
- `skillId: String`。
- `createdAt: Date`。

`recordKey` 提供 iOS 17 可用的单字段唯一约束，同时允许不同账号收藏同一个 Skill。

### `PendingFavoriteMutation`

新增待同步操作模型：

- `recordKey: String`，唯一值为 `"<userId>|<skillId>"`。
- `userId: String`。
- `skillId: String`。
- `desiredFavorite: Bool`，表示用户最终想要的状态。
- `updatedAt: Date`。
- `attemptCount: Int`。
- `lastError: String?`。

同一 `recordKey` 再次操作时覆盖 `desiredFavorite` 和 `updatedAt`，而不是追加新行。队列因此表达最终状态，不依赖重复操作顺序。

## 组件职责

### `FavoritesRemoteClient`

定义可替换协议，生产实现使用 Supabase，测试使用内存 Fake：

- `fetchSkillIDs(userId:) async throws -> Set<String>`
- `upsert(userId:skillIDs:) async throws`
- `delete(userId:skillIDs:) async throws`

远端查询显式按 `user_id` 过滤，同时由 RLS 再次限制当前会话只能访问自己的记录。Upsert 包含复合主键所需的 `user_id` 和 `skill_id`。

### `FavoriteSyncCoordinator`

作为收藏状态的单一写入口，运行在主执行器上并持有主 `ModelContext`：

- 发布当前范围的 `favoriteIDs`、`isSyncing`、`pendingCount` 和 `lastSyncError`。
- 接收登录用户 ID；`nil` 表示游客。
- 处理收藏切换、游客迁移、待同步提交、云端拉取和本地缓存对账。
- 每个用户同一时刻最多执行一个同步；同步期间的新触发合并为下一轮，不并发修改同一批记录。

SwiftUI 页面不再直接构造 `FavoritesStore` 或自行修改 SwiftData，而是统一调用协调器。

### `FavoritesRemoteAPI`

实现 `FavoritesRemoteClient`，只使用现有匿名发布密钥和用户会话，不持有 service role 或其他管理密钥。

## 数据流

### App 启动与登录状态

1. Auth 状态为 `unknown` 时，协调器不展示任何账号缓存，避免短暂显示上一个账号的收藏。
2. Auth 确认为未登录时，加载游客 `Favorite`。
3. Auth 确认为已登录时，加载该用户的 `AccountFavorite`，迁移游客收藏，然后开始同步。
4. Supabase 的 `initialSession`、`signedIn` 等事件可能重复确认同一会话；协调器按当前用户 ID 去重，不重复迁移已经为空的游客集合。

### 游客收藏迁移

登录时在一个本地保存周期中完成：

1. 读取全部游客 `Favorite`。
2. 为每个 Skill 创建或更新当前用户的 `AccountFavorite`。
3. 为每个 Skill 创建或更新 `desiredFavorite = true` 的待同步操作。
4. 删除已经迁移的游客 `Favorite`。
5. 保存成功后立刻发布账号收藏集合。

迁移不依赖网络。即使离线，游客收藏也已经安全转入当前账号范围；退出后这些收藏不会泄露给另一个账号。

### 收藏与取消收藏

游客状态：

- 只修改 `Favorite`，不创建远端操作。

登录状态：

- 收藏：创建或保留 `AccountFavorite`，并把对应待同步操作设为 `desiredFavorite = true`。
- 取消：删除对应 `AccountFavorite`，并把对应待同步操作设为 `desiredFavorite = false`。
- 本地缓存和待同步操作在同一次 `ModelContext.save()` 中保存；保存完成后立即更新界面，再异步触发同步。

### 同步算法

每轮同步针对一个明确的用户 ID：

1. 读取该用户当前待同步操作的快照。
2. 将 `desiredFavorite = true` 的 Skill 批量 Upsert。
3. 将 `desiredFavorite = false` 的 Skill 批量删除；删除条件同时包含 `user_id` 与 `skill_id`。
4. 只有对应远端请求成功后，才删除该批待同步记录；失败记录保留并增加 `attemptCount`、更新 `lastError`。
5. 拉取该用户的云端收藏集合。
6. 再读取仍未提交的本地待同步操作，并覆盖到云端集合上：待收藏的加入，待取消的移除。
7. 用覆盖后的集合校正该用户的 `AccountFavorite` 缓存。
8. 如果同步期间又产生新操作，当前轮结束后再运行一轮。

第 6 步保证远端旧状态不会覆盖离线操作。不同设备同时修改同一 Skill 时，以最后成功到达服务器的操作为云端最终状态；各设备在下一次对账后收敛。

### 自动触发时机

- 用户完成登录或恢复已有会话。
- App 从后台回到前台。
- 打开收藏页。
- 收藏页下拉刷新。
- 登录用户执行收藏或取消收藏。
- 用户在个人页点击手动重试。

不设置固定间隔轮询，也不申请后台执行权限。

### 退出登录

- 立即切换到游客范围，账号收藏不再显示。
- 账号的 `AccountFavorite` 和 `PendingFavoriteMutation` 保留在本机并继续按用户 ID 隔离。
- 不在无会话状态尝试提交账号操作。
- 同一用户再次登录时恢复本地缓存并重试；其他账号无法读取该用户范围。

### 删除账号

1. `delete_my_account()` 在删除 `auth.users` 前，先删除 `public.favorites` 中当前 `auth.uid()` 的记录。
2. RPC 成功后，本机删除该用户的 `AccountFavorite` 和 `PendingFavoriteMutation`。
3. 游客收藏和其他账号缓存不受影响。
4. RPC 失败时不清除本机账号数据，并显示现有删除失败提示。

## 错误处理

- 网络失败、超时和 5xx：保留本地状态与待同步记录，不弹阻塞式警告。
- 会话失效：停止远端同步，等待 Auth 状态切换；本地账号缓存保留但不向游客展示。
- RLS 或权限错误：保留待同步记录，在个人页显示“同步失败，请重新登录或重试”。
- 解码或数据错误：不以空集合覆盖本地缓存，记录可展示的同步失败状态。
- 拉取失败：继续显示本地缓存，不显示“没有收藏”。
- 部分提交成功：只清理已成功批次的待同步记录，失败批次继续保留。

`lastError` 只保存适合本地诊断的简短信息，不包含访问令牌、用户邮箱或 Supabase 密钥。

## 数据库与权限

新增 `pipeline/supabase/migrations/014_favorites_sync.sql`：

1. 启用 `public.favorites` RLS。
2. 撤销 `anon` 对收藏表的全部权限。
3. 仅向 `authenticated` 授予 `select, insert, update, delete`。
4. 重建 owner policy，限定 `to authenticated`，并使用 `auth.uid() = user_id` 的 `using` 与 `with check`。
5. 更新 `delete_my_account()`：先删除调用者的收藏，再删除调用者的 Auth 用户。
6. 保持函数 `security definer`、固定 `search_path`、撤销 public 执行权，只向 authenticated 授予执行权。

迁移必须幂等；重复执行不应产生重复策略或权限错误。上线顺序是先应用数据库迁移并验证 RLS，再发布使用同步功能的 App 版本。

## 界面行为

### 收藏按钮

`SkillCard` 与 `SkillDetailView` 从协调器读取当前范围的收藏集合，并调用统一 `toggle(skillId:)`。按钮点击立即变化，不等待网络。

### 收藏页

- 游客显示本地 `Favorite`。
- 登录用户显示该账号的 `AccountFavorite`。
- 进入页面触发一次对账；下拉刷新强制触发一次对账。
- 同步失败时继续显示本地缓存，并在列表上方显示非阻塞提示和重试按钮。
- 真正没有收藏时才显示空态。

### 个人页

登录状态下显示：

- `已同步`：无待同步操作且最近一轮成功。
- `同步中`：正在提交或拉取。
- `N 项待同步`：存在待同步操作；附带重试按钮。
- `同步失败`：最近一轮失败但没有可计数操作时；附带重试按钮。

“登录后可在多设备间同步收藏”文案保留。

## 文件范围

预计新增：

- `Skiller/Models/AccountFavorite.swift`
- `Skiller/Models/PendingFavoriteMutation.swift`
- `Skiller/Services/FavoritesRemoteAPI.swift`
- `Skiller/Services/FavoriteSyncCoordinator.swift`
- `pipeline/supabase/migrations/014_favorites_sync.sql`
- `SkillerTests/FavoriteSyncCoordinatorTests.swift`
- `SkillerTests/FavoritesStoreTests.swift`

预计修改：

- `Skiller/App/SkillerApp.swift`
- `Skiller/Services/FavoritesStore.swift`
- `Skiller/Services/AuthService.swift`
- `Skiller/Components/SkillCard.swift`
- `Skiller/Views/SkillDetailView.swift`
- `Skiller/Views/FavoritesView.swift`
- `Skiller/Views/ProfileView.swift`
- `Skiller/Resources/en.lproj/Localizable.strings`
- `Skiller/Resources/zh-Hans.lproj/Localizable.strings`
- `project.yml`

`Favorite.swift` 保持游客模型语义和存储结构，避免破坏现有用户数据。

## 测试策略

新增 iOS 单元测试目标，以内存 SwiftData 容器和 Fake `FavoritesRemoteClient` 覆盖：

1. 已有游客收藏在首次登录时转入账号范围且不丢失。
2. 游客与两个不同账号的收藏集合相互隔离。
3. 首次登录结果等于游客集合与云端集合的并集。
4. 离线收藏创建待同步操作，界面状态立即变化。
5. 同一 Skill 的多次切换压缩为一个最终状态。
6. Upsert 成功后只清理成功的待收藏记录。
7. 删除成功后只清理成功的待取消记录。
8. 远端失败时保留本地状态与待同步记录。
9. 拉取云端后，未提交的本地操作覆盖云端旧状态。
10. 同一用户的并发同步触发被串行化，并在有新操作时补跑一轮。
11. 退出后当前集合切回游客，另一个账号看不到前一个账号缓存。
12. 删除账号成功后只清除目标账号的本地缓存和队列。

数据库验收使用两个真实测试账号验证：

- 匿名会话不能读取或写入 `favorites`。
- 账号 A 不能读取、写入或删除账号 B 的收藏。
- 账号删除后该用户的云端收藏数量为零。

手工黄金路径在中文模拟器上验证：游客收藏、首次登录合并、断网切换、恢复联网、第二设备刷新、退出、换账号和删除账号。

## 验收标准

1. 升级前已有本地收藏升级后仍存在。
2. 首次登录展示游客与云端收藏并集。
3. 两个账号在同一设备上互不显示对方收藏。
4. 离线新增、取消和反复切换在联网后同步为最后状态。
5. 第二台设备启动、回前台或刷新收藏页后与云端一致。
6. 退出登录不显示账号收藏；同账号重新登录后恢复。
7. 删除账号后，本地与云端都不保留该账号收藏。
8. 网络失败不会清空收藏列表，也不会丢弃待同步操作。
9. 中英文同步状态文案完整且格式校验通过。
10. 新增单元测试、现有 Swift 编译和完整 iOS 构建均通过；模拟器黄金路径完成。

## 参考资料

- [Supabase Swift 批量 Upsert](https://supabase.com/docs/reference/swift/upsert)
- [Supabase Swift 删除数据](https://supabase.com/docs/reference/swift/v1/delete)
- [Supabase Swift 登录状态事件](https://supabase.com/docs/reference/swift/auth-onauthstatechange)
- [Supabase Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security)
- [Supabase Swift Data API 权限](https://supabase.com/docs/reference/swift/installing)
