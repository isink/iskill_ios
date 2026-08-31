/**
 * Discover skills scattered across GitHub by searching for SKILL.md files.
 *
 * GitHub's code search API finds every public SKILL.md, regardless of which
 * repo it lives in. We skip repos already covered by other importers, parse
 * each file's frontmatter, and upsert into Supabase.
 *
 *   npm run import:discover
 *
 * Rate limits:
 *   - Code search: 10 req/min (unauthenticated) / 30 req/min (authenticated)
 *   - Contents API: 60 req/hr (unauthenticated) / 5000 req/hr (authenticated)
 *
 * Set GITHUB_TOKEN in .env to avoid hitting limits.
 */

import { db } from "./lib/supabase";
import { env } from "./lib/env";
import { idToDisplayName, toSlug } from "./lib/slugify";
import { mapCategory } from "./lib/category-map";
import { assertNoBatchFailures } from "../lib/batch-failures";
import { assertCompleteGitHubSearch } from "../lib/github-search";
import { boundedRetryDelayMs } from "../lib/rate-limit";

// Repos already handled by dedicated importers — skip them.
const SKIP_REPOS = new Set([
  "anthropics/skills",
  "sickn33/antigravity-awesome-skills",
]);

// GitHub Search API returns at most 1000 results (10 pages × 100).
const MAX_PAGES = 10;
const PER_PAGE = 100;

// Delay between search page requests to respect the rate limit.
const SEARCH_DELAY_MS = 2500; // ~24 req/min with token, safe margin

type SearchItem = {
  name: string;
  path: string;
  repository: {
    full_name: string;
    html_url: string;
    description: string | null;
    stargazers_count: number;
    default_branch: string;
  };
  url: string; // contents API URL
};

type SearchResponse = {
  total_count: number;
  incomplete_results: boolean;
  items: SearchItem[];
};

function authHeaders(): Record<string, string> {
  const h: Record<string, string> = {
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "skiller-importer",
  };
  if (env.githubToken) h.Authorization = `Bearer ${env.githubToken}`;
  return h;
}

async function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Fetch one page of code search results for filename:SKILL.md */
async function searchPage(page: number, attempt = 0): Promise<SearchResponse> {
  const url =
    `https://api.github.com/search/code` +
    `?q=filename:SKILL.md+extension:md` +
    `&per_page=${PER_PAGE}&page=${page}`;
  try {
    const res = await fetch(url, { headers: authHeaders(), signal: AbortSignal.timeout(30000) });

    if (res.status === 403 || res.status === 429) {
      const retryAfter = Number(res.headers.get("retry-after") ?? 60) * 1000;
      const delayMs = boundedRetryDelayMs(attempt, retryAfter);
      if (delayMs === undefined) {
        throw new Error(`Search API ${res.status} after ${attempt + 1} attempts`);
      }
      console.warn(`  ⚠ Rate limited — waiting ${Math.ceil(delayMs / 1000)}s`);
      await sleep(delayMs);
      return searchPage(page, attempt + 1);
    }
    if (res.status >= 500 || res.status === 408) {
      throw new Error(`Search API ${res.status} ${res.statusText}`);
    }
    if (!res.ok) {
      throw new Error(`Search API ${res.status} ${res.statusText}`);
    }
    return (await res.json()) as SearchResponse;
  } catch (err) {
    if (attempt < 3) {
      const wait = (attempt + 1) * 10000;
      console.warn(`  ⚠ Page ${page} failed (${(err as Error).message}) — retry in ${wait / 1000}s`);
      await sleep(wait);
      return searchPage(page, attempt + 1);
    }
    throw err;
  }
}

/** Fetch raw SKILL.md content via the contents API URL from search results */
async function fetchSkillMdFromUrl(contentsUrl: string): Promise<string | undefined> {
  const res = await fetch(contentsUrl, { headers: authHeaders() });
  if (res.status === 404) return undefined;
  if (!res.ok) {
    throw new Error(`Contents API ${res.status} ${res.statusText}: ${contentsUrl}`);
  }
  const data = (await res.json()) as { content?: string; encoding?: string };
  if (!data.content || data.encoding !== "base64") {
    throw new Error(`Contents API returned no base64 content: ${contentsUrl}`);
  }
  // Node's atob doesn't handle multi-line base64; strip newlines first.
  const decoded = Buffer.from(data.content.replace(/\n/g, ""), "base64").toString("utf8");
  return decoded.replace(/\u0000/g, "");
}

/** Minimal YAML frontmatter parser (same approach as import-anthropic.ts) */
function parseFrontmatter(md: string): {
  name?: string;
  description?: string;
  tags?: string[];
  category?: string;
} {
  const match = md.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!match) return {};
  const fm: Record<string, string | string[]> = {};
  for (const line of match[1].split(/\r?\n/)) {
    const kv = line.match(/^([A-Za-z0-9_-]+)\s*:\s*(.*)$/);
    if (!kv) continue;
    let [, key, val] = kv;
    val = val.trim().replace(/^["']|["']$/g, "");
    const arr = val.match(/^\[(.*)\]$/);
    if (arr) {
      fm[key] = arr[1]
        .split(",")
        .map((s) => s.trim().replace(/^["']|["']$/g, ""))
        .filter(Boolean);
    } else {
      fm[key] = val;
    }
  }
  return fm as { name?: string; description?: string; tags?: string[]; category?: string };
}

/** Derive a stable slug from repo + file path */
function deriveSlug(repoFullName: string, filePath: string): string {
  // e.g. "owner/my-skill-repo" + "skills/foo/SKILL.md" → "owner--foo"
  const dir = filePath.replace(/\/?SKILL\.md$/i, "").replace(/\//g, "-");
  const repoSlug = repoFullName.replace("/", "--");
  const combined = dir ? `${repoSlug}--${dir}` : repoSlug;
  return toSlug(combined).slice(0, 80);
}

async function main() {
  if (!env.githubToken) {
    console.warn(
      "⚠ No GITHUB_TOKEN set — search rate limit is 10 req/min and may be hit quickly.\n" +
      "  Add GITHUB_TOKEN=... to .env for best results.\n"
    );
  }

  console.log("→ Searching GitHub for SKILL.md files...");

  // Collect all search results across pages.
  const allItems: SearchItem[] = [];
  let page = 1;

  while (page <= MAX_PAGES) {
    process.stdout.write(`  ↳ page ${page}/${MAX_PAGES}...\r`);
    const result = await searchPage(page);
    assertCompleteGitHubSearch(result.incomplete_results);

    if (page === 1) {
      console.log(`\n✓ Total matches on GitHub: ${result.total_count}`);
    }

    allItems.push(...result.items);

    if (result.items.length < PER_PAGE) break;

    page++;
    if (page <= MAX_PAGES) await sleep(SEARCH_DELAY_MS);
  }

  process.stdout.write("\n");

  // Filter out known repos and deduplicate by repo.
  const filtered = allItems.filter(
    (item) => !SKIP_REPOS.has(item.repository.full_name)
  );

  // Deduplicate: if a repo has multiple SKILL.md files, keep all of them
  // (each becomes a separate skill entry).
  console.log(
    `✓ ${filtered.length} SKILL.md files in ${new Set(filtered.map((i) => i.repository.full_name)).size} repos after filtering known sources`
  );

  let imported = 0;
  let skipped = 0;
  let failed = 0;

  for (let i = 0; i < filtered.length; i++) {
    const item = filtered[i];
    const { repository: repo, path, url } = item;

    process.stdout.write(
      `  ↳ [${i + 1}/${filtered.length}] ${repo.full_name}/${path}\r`
    );

    const md = await fetchSkillMdFromUrl(url);
    if (!md || md.trim().length < 20) {
      skipped++;
      continue;
    }

    const fm = parseFrontmatter(md);

    // Derive slug from repo + path so each SKILL.md gets a unique row.
    const slug = deriveSlug(repo.full_name, path);

    // Name: frontmatter > repo name cleaned up
    const rawName = typeof fm.name === "string" ? fm.name : "";
    const name = rawName || idToDisplayName(repo.full_name.split("/")[1]);

    // Description: frontmatter > first non-heading paragraph of body
    let description = typeof fm.description === "string" ? fm.description : "";
    if (!description) {
      const body = md.replace(/^---[\s\S]*?---\r?\n?/, "");
      description = body
        .split(/\r?\n\r?\n/)
        .map((p) => p.replace(/^#+\s*/, "").trim())
        .find((p) => p.length > 20) ?? "";
    }
    description = description.slice(0, 1000);

    const rawCategory = typeof fm.category === "string" ? fm.category : null;
    const category = mapCategory(rawCategory ?? repo.full_name);

    const tags: string[] = Array.isArray(fm.tags)
      ? fm.tags.filter((t): t is string => typeof t === "string")
      : [];
    tags.push("community");
    const uniqueTags = Array.from(new Set(tags)).slice(0, 8);

    const row = {
      slug,
      name,
      description,
      category,
      tags: uniqueTags,
      author: repo.full_name.split("/")[0],
      github_url: `${repo.html_url}/blob/${repo.default_branch}/${path}`,
      skill_md_content: md,
      github_stars: repo.stargazers_count,
      rank: 0,
      score: 0,
      featured: false,
    };

    const { error } = await db.from("skills").upsert(row, { onConflict: "slug" });
    if (error) {
      console.error(`\n  ✖ ${slug}: ${error.message}`);
      failed++;
      continue;
    }

    imported++;
  }

  process.stdout.write("\n");
  console.log(`\n✅ Done. Imported ${imported} new skills, skipped ${skipped}, failed ${failed}.`);
  assertNoBatchFailures("skill upsert", failed);
}

main().catch((err) => {
  console.error("\n✖ Import failed:");
  console.error(err);
  process.exit(1);
});
