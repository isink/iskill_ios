# Skiller Data Pipeline

Independent Node.js pipeline that imports skills from GitHub sources into Supabase, then enriches them with Chinese content via DeepSeek API.

Decoupled from the iOS app — the app reads from Supabase, doesn't run this pipeline.

## Quick start

```bash
cd pipeline
npm ci
npm run check

# 一把梭（需要本地代理 127.0.0.1:7890）
npm run sync:local

# 分步
npm run import:all      # 拉新 skill（要代理）
npm run apply:overrides # 最终严格校验精选/排序/分类目标
npm run reclassify      # 重新分类 misc
npm run enrich:skills   # 中文化（不要代理）
```

## Required env vars (.env)

```
SUPABASE_URL=https://<project>.supabase.co
SUPABASE_SERVICE_ROLE_KEY=...
DEEPSEEK_API_KEY=...
GITHUB_TOKEN=...           # 可选，提升 GitHub API 限流
```

## 运行方式

主同步只手动跑——没挂 CI。需要时本地敲 `npm run sync:local`。仓库另有可选的每日 stars backfill wrapper；它会从脚本位置解析当前 pipeline 路径，代理不可用时返回非零状态，避免静默漏跑。

`npm run check` 会先做完整 TypeScript 类型检查，再运行离线单元测试；`npm run check:full` 还会启动两套名称唯一、彼此隔离的本地 Supabase：一套验证最终 schema 和安全行为，另一套从带历史数据的代表性 013 基线 fixture 依次升级到 016，再在升级结果上重放 014–016 验证幂等性。两套实例都会删除容器与数据卷，清理失败也会让门禁失败。GitHub Actions 对 pipeline 相关改动自动运行这道完整门禁。流水线脚本只要有一条写入或 enrichment 失败，就必须返回非零退出码，不能把部分失败伪装成成功。Antigravity 索引少于 1,000 条会被视为异常截断并在写入前失败；若上游确实永久缩小，需要人工核对后再调整该安全线。

`sources.json` 会先完整校验，再由 `apply_skill_overrides` 在一个数据库事务内应用。单来源导入阶段允许尚未出现的 slug 只告警；`sync` 在全部来源完成后会严格再应用一次，仍有遗漏就非零退出。富化会分页审计全部 skill，把空白、越界和双语标签不配对的历史数据重新入队；已有一侧合法标签时保留该侧、只生成对应翻译。`fill_skill_enrichment` 同时校验读取时的 `updated_at`，源内容在生成期间变化就拒绝旧结果并要求重跑。

## 数据库变更与验证

`supabase/schema.sql` 是全新环境使用的最终快照；`supabase/migrations/` 是现有环境的增量历史。不要把最终快照加载到已有项目，也不要把 `supabase/tests/security.sql` 指向线上数据库。

最简单的本地验证命令是 `npm run test:db`。它要求 Docker daemon 和 Supabase CLI 可用，只操作带随机后缀的 `skiller-db-test-*` 一次性本地实例，不连接 linked 项目。若要手工验证另一套一次性 Supabase，也可以这样执行（普通 PostgreSQL 不包含 `auth.users` 和 Supabase 角色，不能替代）：

```bash
test -n "$SKILLER_TEST_DATABASE_URL"
psql "$SKILLER_TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/schema.sql
psql "$SKILLER_TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/security.sql
```

现有环境的发布顺序必须分阶段：

1. 执行 `014_favorites_sync.sql`，建立账号级收藏和账号删除契约。
2. 执行 `015_skills_contract.sql`，先补齐 App/流水线依赖的字段和安全举报 RPC。
3. 发布已经改用 `submit_skill_report` 的 App，并确认旧版直写入口不再需要。
4. 执行 `016_lock_down_public_writes.sql`，关闭旧提交/举报直写、移除 ntfy 触发器和伪安装计数 RPC。
5. 016 成功并读回函数权限后，才更新/运行本版 pipeline；此前暂停 `sync`，因为精选配置和富化写入已依赖新的原子 RPC。

这个项目早期迁移曾通过 SQL Editor 手工执行，远端对象可能存在、migration history 却为空。任何 linked push 之前都必须先运行只读的 `supabase migration list --linked` 和 `supabase db push --linked --dry-run`：只要 dry-run 仍列出 `001`–`013`，立即停止。不得直接 push；需先核对线上对象，再经单独授权修复 migration history。否则会重放含去重删除和旧公开写入口的历史迁移，并可能在中途失败后留下不安全状态。

执行前还要只读检查孤儿收藏、负数安装计数和待处理的提交/举报数量。历史 ntfy topic 曾进入仓库，关闭触发器不能替代在 ntfy 侧轮换或停用该 topic。

## 历史

数据管道原本和 Expo iOS app 共享 `/Skiller/ios/` 目录，2026-04-28 迁移到 native 项目下独立成一个子模块（`native/pipeline/`）。旧 Expo 项目 `Skiller/ios/` 现已整体删除，`Skiller/ios/scripts` 不再存在。同时弃用了 GitHub Actions 自动同步，改为纯手动跑。
