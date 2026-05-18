/**
 * Apply the review-agent's recommendation for a single submission.
 *
 *   npm run review:apply -- <submission-id>
 *
 * - reject  → set submissions.status='rejected', copy agent_reason into
 *             reviewer_note, stamp reviewed_at. No clone, no skills writes.
 * - approve → shallow-clone the repo, validate each SKILL.md, upsert every
 *             package into `skills`, then mark the submission approved.
 *
 * If `agent_decision` is not set, the script refuses to act. Re-run the
 * agent (or fall back to `npm run review:pending`) first.
 *
 * Required env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
 * Requires `skill-validator` on PATH for approve.
 */

import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { db } from "../import/lib/supabase";
import { idToDisplayName, toSlug } from "../import/lib/slugify";
import { mapCategory } from "../import/lib/category-map";

type SubmissionRow = {
  id: string;
  github_url: string;
  status: string;
  agent_decision: string | null;
  agent_reason: string | null;
};

type SkillPackage = {
  dir: string;
  relativePath: string;
  md: string;
};

const VALIDATOR_BIN = process.env.SKILL_VALIDATOR_BIN || "skill-validator";

function parseRepoUrl(url: string): { owner: string; repo: string } | null {
  try {
    const u = new URL(url);
    if (u.host !== "github.com" && u.host !== "www.github.com") return null;
    const parts = u.pathname.split("/").filter(Boolean);
    if (parts.length < 2) return null;
    return { owner: parts[0], repo: parts[1].replace(/\.git$/, "") };
  } catch {
    return null;
  }
}

function shallowClone(owner: string, repo: string, dest: string): void {
  execFileSync(
    "git",
    [
      "clone",
      "--depth=1",
      "--single-branch",
      "--quiet",
      `https://github.com/${owner}/${repo}.git`,
      dest,
    ],
    { stdio: ["ignore", "ignore", "pipe"] },
  );
}

function locateSkillPackages(rootDir: string): SkillPackage[] {
  const out: SkillPackage[] = [];

  function tryRead(dir: string, relativePath: string): void {
    const path = join(dir, "SKILL.md");
    try {
      const md = readFileSync(path, "utf-8");
      out.push({ dir, relativePath, md });
    } catch {
      /* none */
    }
  }

  tryRead(rootDir, "");

  let entries: string[] = [];
  try {
    entries = readdirSync(rootDir);
  } catch {
    return out;
  }
  for (const name of entries) {
    if (name.startsWith(".") || name === "node_modules") continue;
    const childPath = join(rootDir, name);
    let isDir = false;
    try {
      isDir = statSync(childPath).isDirectory();
    } catch {
      continue;
    }
    if (isDir) tryRead(childPath, name);
  }

  return out;
}

function runValidator(skillDir: string): { passed: boolean; errors: string[]; raw: unknown } {
  const result = spawnSync(VALIDATOR_BIN, ["check", skillDir, "-o", "json"], {
    encoding: "utf-8",
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error) {
    return { passed: false, errors: [`validator failed to launch: ${result.error.message}`], raw: null };
  }

  let raw: unknown = null;
  try {
    raw = result.stdout?.trim() ? JSON.parse(result.stdout) : null;
  } catch {
    raw = { rawStdout: result.stdout };
  }

  const errors: string[] = [];
  if (raw && typeof raw === "object") {
    const r = raw as Record<string, unknown>;
    for (const key of ["errors", "issues", "problems", "violations"]) {
      const v = r[key];
      if (Array.isArray(v)) for (const item of v) errors.push(stringifyIssue(item));
    }
    const checks = r.checks;
    if (checks && typeof checks === "object") {
      for (const [name, val] of Object.entries(checks as Record<string, unknown>)) {
        if (val && typeof val === "object") {
          const cv = val as Record<string, unknown>;
          const passed = cv.passed ?? cv.ok;
          if (passed === false) {
            const msg = cv.error || cv.message || cv.errors;
            errors.push(`${name}: ${stringifyIssue(msg)}`);
          }
        }
      }
    }
    const top = r.passed ?? r.ok ?? r.success;
    if (top === false && errors.length === 0) errors.push("validator reported failure");
  }
  if (errors.length === 0 && result.status && result.status !== 0) {
    errors.push(`validator exited with status ${result.status}`);
  }
  return { passed: errors.length === 0, errors, raw };
}

function stringifyIssue(item: unknown): string {
  if (item == null) return "unknown";
  if (typeof item === "string") return item;
  if (typeof item === "object") {
    const i = item as Record<string, unknown>;
    return String(i.message || i.error || i.detail || JSON.stringify(item));
  }
  return String(item);
}

type Frontmatter = { name?: string; description?: string; tags?: string[]; category?: string; [k: string]: unknown };

function parseFrontmatter(md: string): { frontmatter: Frontmatter; body: string } {
  const match = md.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  if (!match) return { frontmatter: {}, body: md };
  const [, yaml, body] = match;
  const fm: Frontmatter = {};
  for (const line of yaml.split(/\r?\n/)) {
    const kv = line.match(/^([A-Za-z0-9_-]+)\s*:\s*(.*)$/);
    if (!kv) continue;
    const [, key, rawValue] = kv;
    let value: string | string[] = rawValue.trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    const arrMatch = typeof value === "string" && value.match(/^\[(.*)\]$/);
    if (arrMatch) {
      value = arrMatch[1].split(",").map((s) => s.trim().replace(/^["']|["']$/g, "")).filter(Boolean);
    }
    fm[key] = value;
  }
  return { frontmatter: fm, body };
}

async function upsertSkill(pkg: SkillPackage, owner: string, repo: string): Promise<void> {
  const { frontmatter, body } = parseFrontmatter(pkg.md);
  const slugBase = pkg.relativePath || repo;
  const slug = toSlug(`${owner}-${slugBase}`);
  const name =
    typeof frontmatter.name === "string" && frontmatter.name.trim()
      ? frontmatter.name.trim()
      : idToDisplayName(slugBase);
  const description =
    typeof frontmatter.description === "string" && frontmatter.description.trim()
      ? frontmatter.description.trim().slice(0, 600)
      : (body.split(/\r?\n\r?\n/)[0] ?? "").replace(/^#+\s*/, "").slice(0, 400);
  const category = mapCategory(
    typeof frontmatter.category === "string" ? frontmatter.category : null,
  );
  const tags: string[] = ["community", "user-submission"];
  if (Array.isArray(frontmatter.tags)) {
    for (const t of frontmatter.tags) if (typeof t === "string") tags.push(t);
  }
  const githubUrl = pkg.relativePath
    ? `https://github.com/${owner}/${repo}/tree/HEAD/${pkg.relativePath}`
    : `https://github.com/${owner}/${repo}`;
  const row = {
    slug,
    name,
    description,
    category,
    tags: Array.from(new Set(tags)).slice(0, 8),
    author: owner,
    github_url: githubUrl,
    skill_md_content: pkg.md,
    rank: 40,
    score: 70,
    featured: false,
  };
  const { error } = await db.from("skills").upsert(row, { onConflict: "slug" });
  if (error) throw new Error(`upsert skills: ${error.message}`);
}

async function applyReject(row: SubmissionRow): Promise<void> {
  const note = (row.agent_reason || "").slice(0, 2000) || "rejected by review-agent";
  const { error } = await db
    .from("submissions")
    .update({
      status: "rejected",
      reviewer_note: note,
      reviewed_at: new Date().toISOString(),
    })
    .eq("id", row.id);
  if (error) throw new Error(`update rejected: ${error.message}`);
  console.log(`  ✖ ${row.id}: applied REJECT — ${note}`);
}

async function applyApprove(row: SubmissionRow): Promise<void> {
  const parsed = parseRepoUrl(row.github_url);
  if (!parsed) throw new Error(`bad github url: ${row.github_url}`);
  const { owner, repo } = parsed;

  const tmp = mkdtempSync(join(tmpdir(), `skiller-apply-${row.id}-`));
  try {
    try {
      shallowClone(owner, repo, tmp);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      throw new Error(`git clone failed: ${msg}`);
    }

    const packages = locateSkillPackages(tmp);
    if (packages.length === 0) {
      throw new Error("No SKILL.md found in repo (agent recommended approve but repo is empty?)");
    }

    const reports: Array<{ relativePath: string; errors: string[]; raw: unknown }> = [];
    for (const pkg of packages) {
      const r = runValidator(pkg.dir);
      reports.push({ relativePath: pkg.relativePath || "(root)", errors: r.errors, raw: r.raw });
      if (!r.passed) {
        throw new Error(`validator failed on ${pkg.relativePath || "(root)"}: ${r.errors.join("; ")}`);
      }
    }

    for (const pkg of packages) {
      await upsertSkill(pkg, owner, repo);
    }

    const health = {
      reviewedAt: new Date().toISOString(),
      validator: VALIDATOR_BIN,
      appliedFrom: "agent",
      packages: reports,
    };

    const { error } = await db
      .from("submissions")
      .update({
        status: "approved",
        reviewer_note: (row.agent_reason || "").slice(0, 2000) || null,
        reviewed_at: new Date().toISOString(),
        health,
      })
      .eq("id", row.id);
    if (error) throw new Error(`update approved: ${error.message}`);

    console.log(`  ✓ ${row.id}: applied APPROVE — ${packages.length} skill(s) from ${owner}/${repo}`);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

async function main(): Promise<void> {
  const submissionId = process.argv[2];
  if (!submissionId) {
    console.error("usage: npm run review:apply -- <submission-id>");
    process.exit(2);
  }

  const { data, error } = await db
    .from("submissions")
    .select("id, github_url, status, agent_decision, agent_reason")
    .eq("id", submissionId)
    .single();
  if (error || !data) {
    console.error(`✖ submission not found: ${submissionId}${error ? ` (${error.message})` : ""}`);
    process.exit(1);
  }

  const row = data as SubmissionRow;

  if (row.status !== "pending") {
    console.error(`✖ submission ${submissionId} is already ${row.status}; refusing to re-apply`);
    process.exit(1);
  }
  if (!row.agent_decision) {
    console.error(`✖ submission ${submissionId} has no agent_decision yet; run the agent first`);
    process.exit(1);
  }

  console.log(`→ applying ${row.agent_decision} for ${row.id} (${row.github_url})`);

  if (row.agent_decision === "reject") {
    await applyReject(row);
  } else if (row.agent_decision === "approve") {
    await applyApprove(row);
  } else {
    console.error(`✖ unknown agent_decision: ${row.agent_decision}`);
    process.exit(1);
  }

  console.log("✅ Done.");
}

main().catch((err) => {
  console.error("\n✖ apply failed:");
  console.error(err);
  process.exit(1);
});
