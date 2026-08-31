/**
 * Auto-review pending UGC submissions.
 *
 * Workflow:
 *   1. Pull all submissions where status='pending'.
 *   2. For each: shallow-clone the GitHub repo into a temp dir.
 *   3. Locate every SKILL.md (root + one level deep).
 *   4. Run `skill-validator check` against each SKILL.md's parent dir.
 *   5. If all SKILL.md packages pass → upsert each into `skills` and flip
 *      submission status to 'approved'. Otherwise → 'rejected' with the
 *      validator output collected into reviewer_note.
 *   6. Always store the full validator JSON in `submissions.health`.
 *
 *   npm run review:pending
 *
 * Required env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
 * Optional: GITHUB_TOKEN (used by raw fetches if needed; clone uses public).
 *
 * Requires `skill-validator` CLI on PATH (brew install agent-ecosystem/tap/skill-validator).
 */

import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { db } from "../import/lib/supabase";
import { idToDisplayName, toSlug } from "../import/lib/slugify";
import { mapCategory } from "../import/lib/category-map";
import { assertNoBatchFailures } from "../lib/batch-failures";

type SubmissionRow = {
  id: string;
  github_url: string;
  submitter_user_id: string | null;
};

type SkillPackage = {
  /** Absolute path to the directory containing SKILL.md. */
  dir: string;
  /** Path component used as slug suffix (e.g. "research-writer" or ""). */
  relativePath: string;
  /** Raw markdown content. */
  md: string;
};

type ValidatorReport = {
  raw: unknown;
  errors: string[];
};

type SubmissionSkillRow = {
  slug: string;
  name: string;
  description: string;
  category: string;
  tags: string[];
  author: string;
  github_url: string;
  skill_md_content: string;
  rank: number;
  score: number;
  featured: boolean;
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
    const skillPath = join(dir, "SKILL.md");
    try {
      const md = readFileSync(skillPath, "utf-8");
      out.push({ dir, relativePath, md });
    } catch {
      // no SKILL.md here
    }
  }

  // Root SKILL.md
  tryRead(rootDir, "");

  // One level deep
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

function runValidator(skillDir: string): ValidatorReport {
  const result = spawnSync(VALIDATOR_BIN, ["check", skillDir, "-o", "json"], {
    encoding: "utf-8",
    maxBuffer: 16 * 1024 * 1024,
  });

  if (result.error) {
    throw new Error(`skill-validator not found or failed to launch: ${result.error.message}`);
  }

  const stdout = result.stdout || "";
  let raw: unknown = null;
  try {
    raw = stdout.trim() ? JSON.parse(stdout) : null;
  } catch {
    raw = { rawStdout: stdout };
  }

  const errors = collectErrors(raw, result.status);
  return { raw, errors };
}

/**
 * Best-effort error collection from skill-validator's JSON output. The schema
 * is loose across releases, so we look for common shapes.
 */
function collectErrors(raw: unknown, exitCode: number | null): string[] {
  const errors: string[] = [];

  if (raw && typeof raw === "object") {
    const r = raw as Record<string, unknown>;

    // Common patterns: top-level errors / issues / problems arrays
    for (const key of ["errors", "issues", "problems", "violations"]) {
      const v = r[key];
      if (Array.isArray(v)) {
        for (const item of v) errors.push(stringifyIssue(item));
      }
    }

    // Per-check sections like { checks: { structure: { errors: [...] }, ... } }
    const checks = r.checks;
    if (checks && typeof checks === "object") {
      for (const [checkName, checkVal] of Object.entries(checks as Record<string, unknown>)) {
        if (checkVal && typeof checkVal === "object") {
          const cv = checkVal as Record<string, unknown>;
          const passed = cv.passed ?? cv.ok;
          if (passed === false) {
            const msg = cv.error || cv.message || cv.errors;
            errors.push(`${checkName}: ${stringifyIssue(msg)}`);
          }
          if (Array.isArray(cv.errors)) {
            for (const e of cv.errors) errors.push(`${checkName}: ${stringifyIssue(e)}`);
          }
        }
      }
    }

    // Top-level passed / ok flag
    const topPassed = r.passed ?? r.ok ?? r.success;
    if (topPassed === false && errors.length === 0) {
      errors.push("validator reported failure (no detailed errors in JSON)");
    }
  }

  if (errors.length === 0 && exitCode && exitCode !== 0) {
    errors.push(`skill-validator exited with status ${exitCode}`);
  }

  return errors;
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

type Frontmatter = {
  name?: string;
  description?: string;
  tags?: string[];
  category?: string;
  [key: string]: unknown;
};

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

    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }

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

function makeSkillRow(
  pkg: SkillPackage,
  owner: string,
  repo: string,
): SubmissionSkillRow {
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

  return {
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

}

async function applyDecision(
  submissionId: string,
  decision: "approve" | "reject",
  reviewerNote: string,
  health: unknown,
  skillRows: SubmissionSkillRow[] = [],
): Promise<void> {
  const { error } = await db.rpc("apply_submission_decision", {
    p_submission_id: submissionId,
    p_decision: decision,
    p_reviewer_note: reviewerNote.slice(0, 2000),
    p_health: health,
    p_skill_rows: skillRows,
  });
  if (error) throw new Error(`apply submission decision: ${error.message}`);
}

async function reviewOne(row: SubmissionRow): Promise<void> {
  const parsed = parseRepoUrl(row.github_url);
  if (!parsed) {
    await applyDecision(
      row.id,
      "reject",
      `Not a valid GitHub repo URL: ${row.github_url}`,
      null,
    );
    console.log(`  ✖ ${row.id}: rejected — bad URL ${row.github_url}`);
    return;
  }
  const { owner, repo } = parsed;

  const tmp = mkdtempSync(join(tmpdir(), `skiller-review-${row.id}-`));
  try {
    try {
      shallowClone(owner, repo, tmp);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      throw new Error(`git clone failed: ${msg}`);
    }

    const packages = locateSkillPackages(tmp);
    if (packages.length === 0) {
      await applyDecision(
        row.id,
        "reject",
        "No SKILL.md found at repo root or in any top-level subdirectory.",
        null,
      );
      console.log(`  ✖ ${row.id}: rejected — no SKILL.md in ${owner}/${repo}`);
      return;
    }

    const reports: Array<{ relativePath: string; report: ValidatorReport }> = [];
    let firstError: string | null = null;

    for (const pkg of packages) {
      const report = runValidator(pkg.dir);
      reports.push({ relativePath: pkg.relativePath || "(root)", report });
      if (report.errors.length > 0 && !firstError) {
        firstError = `${pkg.relativePath || "(root)"}: ${report.errors.join("; ")}`;
      }
    }

    const aggregateHealth = {
      reviewedAt: new Date().toISOString(),
      validator: VALIDATOR_BIN,
      packages: reports.map((r) => ({
        relativePath: r.relativePath,
        errors: r.report.errors,
        raw: r.report.raw,
      })),
    };

    if (firstError) {
      await applyDecision(row.id, "reject", firstError, aggregateHealth);
      console.log(`  ✖ ${row.id}: rejected — ${firstError}`);
      return;
    }

    const skillRows = packages.map((pkg) => makeSkillRow(pkg, owner, repo));
    await applyDecision(row.id, "approve", "", aggregateHealth, skillRows);
    console.log(
      `  ✓ ${row.id}: approved — ${packages.length} skill(s) ingested from ${owner}/${repo}`,
    );
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

async function main(): Promise<void> {
  const { data, error } = await db
    .from("submissions")
    .select("id, github_url, submitter_user_id")
    .eq("status", "pending")
    .order("created_at", { ascending: true });

  if (error) {
    console.error(`✖ Failed to fetch pending submissions: ${error.message}`);
    process.exit(1);
  }

  const rows = (data ?? []) as SubmissionRow[];
  console.log(`→ ${rows.length} pending submission(s)`);

  let failed = 0;
  for (const row of rows) {
    try {
      await reviewOne(row);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      console.error(`✖ ${row.id}: review failed — ${msg}`);
      failed++;
    }
  }

  console.log(`✅ Done. ${rows.length - failed} reviewed, ${failed} failed.`);
  assertNoBatchFailures("submission review", failed);
}

main().catch((err) => {
  console.error("\n✖ Review pipeline crashed:");
  console.error(err);
  process.exit(1);
});
