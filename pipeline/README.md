# Skiller Data Pipeline

Independent Node.js pipeline that imports skills from GitHub sources into Supabase, then enriches them with Chinese content via DeepSeek API.

Decoupled from the iOS app — the app reads from Supabase, doesn't run this pipeline.

## Quick start

```bash
cd /Users/wenhandong/Desktop/dev/Skiller/native/pipeline
npm install

# 一把梭（需要本地代理 127.0.0.1:7890）
npm run sync:local

# 分步
npm run import:all      # 拉新 skill（要代理）
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

只手动跑——没挂 CI。需要时本地敲 `npm run sync:local`。

## 历史

数据管道原本和 Expo iOS app 共享 `/Skiller/ios/` 目录，2026-04-28 迁移到 native 项目下独立成一个子模块（`native/pipeline/`）。旧 Expo 项目 `Skiller/ios/` 现已整体删除，`Skiller/ios/scripts` 不再存在。同时弃用了 GitHub Actions 自动同步，改为纯手动跑。
