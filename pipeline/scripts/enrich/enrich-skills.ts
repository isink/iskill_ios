/**
 * Enrich skills with Chinese descriptions and use-case tags using DeepSeek.
 *
 * For each skill that is missing description_zh or has empty use_cases,
 * we call DeepSeek Chat to generate:
 *   - description_zh: 50-80 char Chinese summary
 *   - use_cases: 3-5 short Chinese scenario tags (e.g. "代码审查", "文档生成")
 *
 * Usage:
 *   DEEPSEEK_API_KEY=sk-... npm run enrich:skills
 *
 * Env vars:
 *   DEEPSEEK_API_KEY   — required
 *   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY — required (from .env)
 *   BATCH_SIZE         — optional, default 5 (parallel requests per round)
 *   LIMIT              — optional, max skills to process (for testing)
 */

import "dotenv/config";
import { db } from "../import/lib/supabase";
import { assertNoBatchFailures } from "../lib/batch-failures";
import {
  enrichmentNeeds,
  preservedUseCaseSide,
  validateEnrichmentForExisting,
  type Enrichment,
  type ExistingEnrichment,
} from "../lib/enrichment";
import { parseOptionalPositiveInteger, parsePositiveInteger } from "../lib/env-number";
import { collectKeysetPages } from "../lib/pagination";

const BATCH_SIZE = parsePositiveInteger("BATCH_SIZE", process.env.BATCH_SIZE, 5);
const LIMIT = parseOptionalPositiveInteger("LIMIT", process.env.LIMIT);

const apiKey = process.env.DEEPSEEK_API_KEY;
if (!apiKey) {
  console.error("✖ DEEPSEEK_API_KEY is not set");
  process.exit(1);
}

type SkillRow = ExistingEnrichment & {
  id: string;
  name: string;
  description: string;
  skill_md_content: string | null;
  updated_at: string;
  github_stars: number | null;
};

async function enrichOne(skill: SkillRow): Promise<Enrichment> {
  const mdBody = skill.skill_md_content
    ? skill.skill_md_content.replace(/^---[\s\S]*?---\n?/, "").trimStart()
    : "";
  const context = Array.from(mdBody).slice(0, 800).join("");
  const preservedUseCases = preservedUseCaseSide(skill);
  const useCaseInstruction = preservedUseCases?.field === "use_cases"
    ? `use_cases 必须逐项原样输出 ${JSON.stringify(preservedUseCases.values)}，只为这些中文标签生成一一对应的 use_cases_en。`
    : preservedUseCases?.field === "use_cases_en"
    ? `use_cases_en 必须逐项原样输出 ${JSON.stringify(preservedUseCases.values)}，只为这些英文标签生成一一对应的 use_cases。`
    : "use_cases 与 use_cases_en 必须逐项一一对应。";

  const prompt = `你是一个技术文案专家，帮助用户了解 Claude AI 的技能插件，输出双语内容。

技能名称：${skill.name}
英文描述：${skill.description}
${context ? `\n技能内容（节选）：\n${context}` : ""}

请用 JSON 格式输出以下内容：
1. description_zh：50-80 字的中文描述，准确传达该技能的核心功能，语言简洁自然
2. use_cases：3-5 个中文使用场景短标签（每个 4-8 个字），描述用户会在什么情况下用到这个技能
3. use_cases_en：use_cases 的英文版，3-5 个 Title Case 短标签（每个 1-3 个英文单词），与中文版语义对应
4. skill_md_summary_zh：150-250 字的中文摘要，面向中文用户介绍这个技能的完整功能、使用方式和适用场景，语言流畅易懂

${useCaseInstruction}

只输出 JSON，格式如下：
{"description_zh":"...","use_cases":["...","...","..."],"use_cases_en":["...","...","..."],"skill_md_summary_zh":"..."}`;

  const res = await fetch("https://api.deepseek.com/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: "deepseek-chat",
      max_tokens: 600,
      messages: [{ role: "user", content: prompt }],
    }),
  });
  if (!res.ok) throw new Error(`DeepSeek ${res.status}: ${await res.text()}`);
  const json = await res.json() as { choices?: { message?: { content?: unknown } }[] };
  const content = json.choices?.[0]?.message?.content;
  if (typeof content !== "string" || !content.trim()) {
    throw new Error("DeepSeek response did not contain message content");
  }
  const text = content.trim();
  // Extract JSON even if wrapped in markdown code block
  const jsonMatch = text.match(/\{[\s\S]*\}/);
  if (!jsonMatch) throw new Error(`No JSON in response: ${text}`);
  return validateEnrichmentForExisting(JSON.parse(jsonMatch[0]), skill);
}

async function fetchPendingSkills(): Promise<SkillRow[]> {
  const pageSize = 1_000;
  const all = await collectKeysetPages(
    pageSize,
    async (afterId, size): Promise<SkillRow[]> => {
      let query = db
      .from("skills")
      .select(`
        id,
        name,
        description,
        skill_md_content,
        updated_at,
        github_stars,
        description_zh,
        use_cases,
        use_cases_en,
        skill_md_summary_zh
      `)
      .order("id")
      .limit(size);
      if (afterId !== undefined) query = query.gt("id", afterId);
      const { data, error } = await query;
      if (error) throw error;
      return (data ?? []) as SkillRow[];
    },
    (skill) => skill.id,
  );

  const pending = all
    .filter((skill) => {
      const needs = enrichmentNeeds(skill);
      return needs.descriptionZh || needs.useCasePair || needs.summaryZh;
    })
    .sort((left, right) =>
      (right.github_stars ?? -1) - (left.github_stars ?? -1)
        || left.id.localeCompare(right.id)
    );
  return LIMIT ? pending.slice(0, LIMIT) : pending;
}

async function updateSkill(skill: SkillRow, enrichment: Enrichment): Promise<void> {
  const { data, error } = await db.rpc("fill_skill_enrichment", {
    p_skill_id: skill.id,
    p_source_updated_at: skill.updated_at,
    p_description_zh: enrichment.description_zh,
    p_use_cases: enrichment.use_cases,
    p_use_cases_en: enrichment.use_cases_en,
    p_skill_md_summary_zh: enrichment.skill_md_summary_zh,
  });
  if (error) throw new Error(`fill skill enrichment: ${error.message}`);
  if (data !== true) {
    throw new Error("source changed during enrichment; retry required");
  }
}

async function main() {
  console.log("→ Fetching skills to enrich...");
  const skills = await fetchPendingSkills();
  console.log(`→ ${skills.length} skills need enrichment`);
  if (skills.length === 0) {
    console.log("✅ Nothing to do.");
    return;
  }

  let done = 0;
  let failed = 0;

  for (let i = 0; i < skills.length; i += BATCH_SIZE) {
    const batch = skills.slice(i, i + BATCH_SIZE);
    await Promise.all(
      batch.map(async (skill) => {
        try {
          const enrichment = await enrichOne(skill);
          await updateSkill(skill, enrichment);
          done++;
        } catch (err) {
          failed++;
          console.error(`  ✖ [${skill.name}] ${(err as Error).message}`);
        }
      })
    );
    process.stdout.write(`  ↳ ${done + failed}/${skills.length} processed (${done} ok, ${failed} failed)\r`);
  }

  process.stdout.write("\n");
  console.log(`\n✅ Done. ${done} enriched, ${failed} failed.`);
  assertNoBatchFailures("skill enrichment", failed);
}

main().catch((err) => {
  console.error("\n✖ Enrichment failed:");
  console.error(err);
  process.exit(1);
});
