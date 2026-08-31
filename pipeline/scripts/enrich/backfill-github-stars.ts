/**
 * Backfill github_stars for skills where it's NULL.
 *
 * These are mostly community skills imported via `import:discover` that later
 * fell out of GitHub's top-1000 search results, so their stars never got
 * refreshed through the normal sync path.
 *
 * Usage (needs proxy for GitHub access):
 *   https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890 npm run backfill:stars
 *
 * Env:
 *   GITHUB_TOKEN (optional, recommended) — lifts rate limit 60/h → 5000/h
 *   LIMIT                                 — cap rows to process (for testing)
 */

import "dotenv/config";
import { db } from "../import/lib/supabase";
import { assertNoBatchFailures } from "../lib/batch-failures";
import { parseOptionalPositiveInteger } from "../lib/env-number";
import { nextPageSize } from "../lib/pagination";
import { boundedRetryDelayMs } from "../lib/rate-limit";
import { parseGitHubRepositoryURL } from "../lib/github-url";

const LIMIT = parseOptionalPositiveInteger("LIMIT", process.env.LIMIT);
const token = process.env.GITHUB_TOKEN;

type Row = { id: string; github_url: string | null };

async function fetchStars(owner: string, repo: string, attempt = 0): Promise<number | null> {
  const res = await fetch(`https://api.github.com/repos/${owner}/${repo}`, {
    headers: {
      Accept: "application/vnd.github+json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
  });
  if (res.status === 404) return null;
  if (res.status === 403 || res.status === 429) {
    const reset = res.headers.get("x-ratelimit-reset");
    const waitMs = reset
      ? Math.max(0, parseInt(reset, 10) * 1000 - Date.now()) + 1000
      : 60_000;
    const delayMs = boundedRetryDelayMs(attempt, waitMs);
    if (delayMs === undefined) {
      throw new Error(`GitHub API ${res.status} after ${attempt + 1} attempts`);
    }
    console.warn(`  ⚠ rate limited, sleeping ${Math.ceil(delayMs / 1000)}s`);
    await new Promise((resolve) => setTimeout(resolve, delayMs));
    return fetchStars(owner, repo, attempt + 1);
  }
  if (!res.ok) {
    throw new Error(`GitHub API ${res.status} ${res.statusText}: ${owner}/${repo}`);
  }
  const data = (await res.json()) as { stargazers_count?: number };
  if (typeof data.stargazers_count !== "number") {
    throw new Error(`GitHub API returned no star count: ${owner}/${repo}`);
  }
  return data.stargazers_count;
}

async function main() {
  const rows: Row[] = [];
  const PAGE = 1000;
  let offset = 0;
  while (true) {
    const requestSize = nextPageSize(PAGE, rows.length, LIMIT);
    if (requestSize === 0) break;
    const { data, error } = await db
      .from("skills")
      .select("id, github_url")
      .is("github_stars", null)
      .order("id", { ascending: true })
      .range(offset, offset + requestSize - 1);
    if (error) throw error;
    const batch = (data ?? []) as Row[];
    rows.push(...batch);
    if (batch.length < requestSize) break;
    offset += requestSize;
  }
  console.log(`→ Found ${rows.length} skills with NULL github_stars`);

  // Group by owner/repo — many skills share one repo
  const groups = new Map<string, { key: { owner: string; repo: string }; ids: string[] }>();
  const unparsed: string[] = [];
  for (const r of rows) {
    const k = parseGitHubRepositoryURL(r.github_url);
    if (!k) {
      unparsed.push(r.id);
      continue;
    }
    const key = `${k.owner}/${k.repo}`;
    const g = groups.get(key) ?? { key: k, ids: [] };
    g.ids.push(r.id);
    groups.set(key, g);
  }
  console.log(`→ ${groups.size} unique repos to fetch (${unparsed.length} rows had no parseable URL)`);

  const starsCache = new Map<string, number | null>();
  let done = 0;
  let updated = 0;
  let missing = 0;
  let failed = 0;

  for (const [key, { key: { owner, repo }, ids }] of groups) {
    done++;
    process.stdout.write(`  ↳ ${done}/${groups.size} ${key}\r`);
    const stars = await fetchStars(owner, repo);
    starsCache.set(key, stars);

    if (stars === null) {
      missing++;
      continue;
    }

    const { error: updErr } = await db
      .from("skills")
      .update({ github_stars: stars })
      .in("id", ids);
    if (updErr) {
      console.error(`\n  ✖ update ${key}: ${updErr.message}`);
      failed++;
      continue;
    }
    updated += ids.length;

    if (!token) await new Promise((r) => setTimeout(r, 1200));
  }

  process.stdout.write("\n");
  console.log(`✅ Done. Updated ${updated} rows across ${groups.size - missing} repos (${missing} repos deleted, ${failed} writes failed)`);
  assertNoBatchFailures("star backfill", failed);
}

main().catch((err) => {
  console.error("✖ Backfill failed:", err);
  process.exit(1);
});
