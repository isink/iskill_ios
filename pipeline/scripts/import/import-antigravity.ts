/**
 * Import ~1,400 community agent skills from
 * https://github.com/sickn33/antigravity-awesome-skills
 *
 * The upstream repo publishes a curated skills_index.json at its root. We fetch
 * it directly, map their schema onto our Supabase `skills` table, and upsert
 * every row. Safe to re-run — uses `slug` as the conflict target.
 *
 *   npm run import:antigravity
 */

import { db } from "./lib/supabase";
import { env } from "./lib/env";
import { idToDisplayName } from "./lib/slugify";
import { mapCategory, CURATED_CATEGORIES } from "./lib/category-map";
import { applyOverrides } from "./lib/overrides";
import { fetchRepoStars, repoStarsPatch } from "./lib/github";
import { fetchSkillMarkdown, skillContentPatch } from "./lib/skill-content";
import {
  validateAntigravitySkills,
  type AntigravitySkill as UpstreamSkill,
} from "../lib/antigravity-source";

const SOURCE_URL =
  "https://raw.githubusercontent.com/sickn33/antigravity-awesome-skills/main/skills_index.json";
const REPO_TREE_BASE =
  "https://github.com/sickn33/antigravity-awesome-skills/tree/main/";

type InsertSkill = {
  slug: string;
  name: string;
  description: string;
  category: string;
  tags: string[];
  author: string;
  github_url: string;
  skill_md_content?: string;
  github_stars?: number;
  rank: number;
  score: number;
  featured: boolean;
};

const RAW_BASE =
  "https://raw.githubusercontent.com/sickn33/antigravity-awesome-skills/main/";

const githubHeaders: Record<string, string> = env.githubToken
  ? { Authorization: `Bearer ${env.githubToken}` }
  : {};

/** A missing file is omitted; transient failures abort before any upsert. */
async function fetchSkillMd(path: string): Promise<string | undefined> {
  return fetchSkillMarkdown(`${RAW_BASE}${path}/SKILL.md`, undefined, githubHeaders);
}

/** Fetch SKILL.md for all skills with concurrency limit. */
async function fetchAllSkillMd(
  rows: Array<{ slug: string; path: string }>
): Promise<Map<string, string | undefined>> {
  const CONCURRENCY = 10;
  const results = new Map<string, string | undefined>();
  for (let i = 0; i < rows.length; i += CONCURRENCY) {
    const batch = rows.slice(i, i + CONCURRENCY);
    const fetched = await Promise.all(
      batch.map(({ slug, path }) =>
        fetchSkillMd(path).then((md) => ({ slug, md }))
      )
    );
    for (const { slug, md } of fetched) results.set(slug, md);
    process.stdout.write(`  ↳ fetched SKILL.md ${Math.min(i + CONCURRENCY, rows.length)}/${rows.length}\r`);
  }
  process.stdout.write("\n");
  return results;
}

function authorFromSource(source: string): string {
  if (!source || source === "personal" || source === "community") {
    return "community";
  }
  const match = source.match(/github\.com\/([^/]+)/i);
  if (match) return match[1];
  return source.slice(0, 64);
}

function deriveTags(upstream: UpstreamSkill): string[] {
  const tags = new Set<string>();
  if (upstream.risk && upstream.risk !== "none") tags.add(upstream.risk);
  if (upstream.category) tags.add(upstream.category.toLowerCase());
  if (upstream.plugin?.targets?.claude === "supported") tags.add("claude");
  if (upstream.plugin?.targets?.codex === "supported") tags.add("codex");
  return Array.from(tags).slice(0, 8);
}

function mapSkill(
  upstream: UpstreamSkill,
  skillMd: string | undefined,
  githubStars: number | undefined,
): InsertSkill {
  return {
    slug: upstream.id,
    name: idToDisplayName(upstream.name || upstream.id),
    description: (upstream.description ?? "").slice(0, 1000),
    category: mapCategory(upstream.category),
    tags: deriveTags(upstream),
    author: authorFromSource(upstream.source),
    github_url: REPO_TREE_BASE + upstream.path,
    ...skillContentPatch(skillMd),
    ...repoStarsPatch(githubStars),
    rank: 0,
    score: 0,
    featured: false,
  };
}

async function ensureCategories(): Promise<void> {
  // Idempotent upsert of our 9 curated slugs so the skills FK always resolves.
  const rows = CURATED_CATEGORIES.map((slug) => ({
    slug,
    name: slug.charAt(0).toUpperCase() + slug.slice(1),
    icon: "sparkles",
  }));
  const { error } = await db
    .from("categories")
    .upsert(rows, { onConflict: "slug" });
  if (error) throw error;
  console.log(`✓ Ensured ${rows.length} curated categories`);
}

async function fetchUpstream(): Promise<UpstreamSkill[]> {
  console.log(`→ Fetching ${SOURCE_URL}`);
  const res = await fetch(SOURCE_URL);
  if (!res.ok) {
    throw new Error(`Fetch failed: ${res.status} ${res.statusText}`);
  }
  const skills = validateAntigravitySkills(await res.json());
  console.log(`✓ Fetched ${skills.length} skills`);
  return skills;
}

async function upsertBatch(rows: InsertSkill[]): Promise<void> {
  const BATCH = 200;
  for (let i = 0; i < rows.length; i += BATCH) {
    const slice = rows.slice(i, i + BATCH);
    const { error } = await db
      .from("skills")
      .upsert(slice, { onConflict: "slug" });
    if (error) throw error;
    process.stdout.write(`  ↳ upserted ${i + slice.length}/${rows.length}\r`);
  }
  process.stdout.write("\n");
}

async function main() {
  await ensureCategories();

  console.log("→ Fetching GitHub stars for antigravity repo");
  const repoStars = await fetchRepoStars("sickn33", "antigravity-awesome-skills");
  console.log(`✓ Stars: ${repoStars ?? "n/a"}`);

  const upstream = await fetchUpstream();

  console.log(`→ Fetching SKILL.md for ${upstream.length} skills`);
  const mdMap = await fetchAllSkillMd(
    upstream.map((u) => ({ slug: u.id, path: u.path }))
  );

  const rows: InsertSkill[] = upstream.map((u) => mapSkill(u, mdMap.get(u.id), repoStars));

  console.log(`→ Upserting ${rows.length} skills`);
  await upsertBatch(rows);

  await applyOverrides();

  console.log(`\n✅ Done. Imported ${rows.length} skills from Antigravity.`);
}

main().catch((err) => {
  console.error("\n✖ Import failed:");
  console.error(err);
  process.exit(1);
});
