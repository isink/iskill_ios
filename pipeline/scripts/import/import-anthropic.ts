/**
 * Import official Anthropic skills from https://github.com/anthropics/skills
 *
 * Unlike the antigravity index, anthropics/skills doesn't ship a manifest —
 * it's a flat list of directories, each containing a SKILL.md with YAML
 * frontmatter + markdown body. We walk the tree via the GitHub REST API,
 * parse each SKILL.md, and upsert into Supabase with the full markdown
 * preserved in `skill_md_content` so the app can render it on the detail
 * screen.
 *
 *   npm run import:anthropic
 *
 * Set GITHUB_TOKEN in .env if you hit rate limits (60 req/hr unauthenticated,
 * 5000 req/hr authenticated).
 */

import { db } from "./lib/supabase";
import { env } from "./lib/env";
import { idToDisplayName } from "./lib/slugify";
import { mapCategory } from "./lib/category-map";
import { applyOverrides } from "./lib/overrides";
import { fetchRepoStars, repoStarsPatch } from "./lib/github";
import { assertNoBatchFailures } from "../lib/batch-failures";
import { fetchEarliestCommitDate } from "../lib/commit-history";

const OWNER = "anthropics";
const REPO = "skills";
const BRANCH = "main";

type GhEntry = {
  name: string;
  path: string;
  type: "dir" | "file";
  sha: string;
  url: string;
};

type Frontmatter = {
  name?: string;
  description?: string;
  tags?: string[];
  category?: string;
  [key: string]: unknown;
};

function authHeaders(): HeadersInit {
  const headers: Record<string, string> = {
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "skiller-importer",
  };
  if (env.githubToken) headers.Authorization = `Bearer ${env.githubToken}`;
  return headers;
}

async function ghJson<T>(url: string): Promise<T> {
  const res = await fetch(url, { headers: authHeaders() });
  if (!res.ok) {
    throw new Error(`GitHub ${res.status} ${res.statusText}: ${url}`);
  }
  return (await res.json()) as T;
}

async function listSkillDirs(): Promise<string[]> {
  const url = `https://api.github.com/repos/${OWNER}/${REPO}/contents?ref=${BRANCH}`;
  const entries = await ghJson<GhEntry[]>(url);
  return entries
    .filter((e) => e.type === "dir" && !e.name.startsWith("."))
    .map((e) => e.name);
}

async function fetchFirstCommitDate(dir: string): Promise<string | undefined> {
  const path = `${dir}/SKILL.md`;
  return fetchEarliestCommitDate(async (page, perPage) => {
    const query = new URLSearchParams({
      path,
      per_page: String(perPage),
      page: String(page),
    });
    const url = `https://api.github.com/repos/${OWNER}/${REPO}/commits?${query}`;
    return ghJson<unknown>(url);
  });
}

async function fetchSkillMd(dir: string): Promise<string | null> {
  // Raw URL is cheaper than going through the API again.
  const url = `https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH}/${dir}/SKILL.md`;
  const res = await fetch(url, { headers: { "User-Agent": "iskill-importer" } });
  if (res.status === 404) return null;
  if (!res.ok) {
    throw new Error(`Raw fetch ${res.status} ${res.statusText}: ${url}`);
  }
  return await res.text();
}

/**
 * Parse YAML frontmatter without pulling in a full yaml dep.
 * Handles key: value pairs, quoted strings, and simple [a, b] arrays.
 */
function parseFrontmatter(md: string): { frontmatter: Frontmatter; body: string } {
  const match = md.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  if (!match) return { frontmatter: {}, body: md };

  const [, rawYaml, body] = match;
  const fm: Frontmatter = {};

  for (const line of rawYaml.split(/\r?\n/)) {
    const kv = line.match(/^([A-Za-z0-9_-]+)\s*:\s*(.*)$/);
    if (!kv) continue;
    const [, key, rawValue] = kv;
    let value: string | string[] = rawValue.trim();

    // Quoted string
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }

    // Inline array
    const arrMatch = typeof value === "string" && value.match(/^\[(.*)\]$/);
    if (arrMatch) {
      value = arrMatch[1]
        .split(",")
        .map((s) => s.trim().replace(/^["']|["']$/g, ""))
        .filter(Boolean);
    }

    fm[key] = value;
  }

  return { frontmatter: fm, body };
}

// Category hints for the known Anthropic official skills. Falls back to
// mapCategory() for anything unlisted.
const KNOWN_CATEGORIES: Record<string, string> = {
  pdf: "office",
  docx: "office",
  xlsx: "office",
  pptx: "office",
  "skill-creator": "official",
  "mcp-builder": "devops",
  "artifacts-builder": "code",
  "webapp-testing": "code",
  "data-analyst": "data",
  "financial-analysis": "data",
  "research-writer": "research",
  canva: "design",
  "brand-guidelines": "design",
  "slack-gif-creator": "design",
  "algorithmic-art": "design",
  "internal-comms": "docs",
};

async function main() {
  console.log(`→ Fetching GitHub stars for ${OWNER}/${REPO}`);
  const repoStars = await fetchRepoStars(OWNER, REPO);
  console.log(`✓ Stars: ${repoStars ?? "n/a"}`);

  console.log(`→ Listing ${OWNER}/${REPO} skill directories`);
  const dirs = await listSkillDirs();
  console.log(`✓ Found ${dirs.length} directories`);

  let imported = 0;
  let skipped = 0;
  let failed = 0;

  for (const dir of dirs) {
    const [md, publishedAt] = await Promise.all([
      fetchSkillMd(dir),
      fetchFirstCommitDate(dir),
    ]);
    if (!md) {
      skipped++;
      continue;
    }

    const { frontmatter, body } = parseFrontmatter(md);

    const slug = dir;
    const name =
      typeof frontmatter.name === "string"
        ? frontmatter.name
        : idToDisplayName(dir);
    const description =
      typeof frontmatter.description === "string"
        ? frontmatter.description
        : (body.split(/\r?\n\r?\n/)[0] ?? "").replace(/^#+\s*/, "").slice(0, 400);

    const category =
      KNOWN_CATEGORIES[slug] ??
      mapCategory(
        typeof frontmatter.category === "string" ? frontmatter.category : null,
      );

    const tags: string[] = [];
    if (Array.isArray(frontmatter.tags)) {
      for (const t of frontmatter.tags) if (typeof t === "string") tags.push(t);
    }
    tags.push("official", "anthropic");

    const row = {
      slug,
      name,
      description,
      category,
      tags: Array.from(new Set(tags)).slice(0, 8),
      author: "anthropics",
      github_url: `https://github.com/${OWNER}/${REPO}/tree/${BRANCH}/${dir}`,
      skill_md_content: md,
      ...repoStarsPatch(repoStars),
      rank: 80, // baseline for official skills; sources.json can override
      score: 95,
      featured: true,
      ...(publishedAt ? { published_at: publishedAt } : {}),
    };

    const { error } = await db
      .from("skills")
      .upsert(row, { onConflict: "slug" });
    if (error) {
      console.error(`  ✖ ${slug}: ${error.message}`);
      failed++;
      continue;
    }

    imported++;
    process.stdout.write(`  ↳ ${imported} imported · last: ${slug}\r`);
  }

  process.stdout.write("\n");
  console.log(`✓ Imported ${imported} skills, skipped ${skipped}, failed ${failed}`);

  assertNoBatchFailures("skill upsert", failed);

  await applyOverrides();
  console.log("\n✅ Done. Official Anthropic skills are live.");
}

main().catch((err) => {
  console.error("\n✖ Import failed:");
  console.error(err);
  process.exit(1);
});
