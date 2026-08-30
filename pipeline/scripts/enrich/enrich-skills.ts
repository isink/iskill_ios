/**
 * Enrich skills with Chinese descriptions and use-case tags using Claude API.
 *
 * For each skill that is missing description_zh or has empty use_cases,
 * we call Claude haiku to generate:
 *   - description_zh: 50-80 char Chinese summary
 *   - use_cases: 3-5 short Chinese scenario tags (e.g. "代码审查", "文档生成")
 *
 * Usage:
 *   ANTHROPIC_API_KEY=sk-... npm run enrich:skills
 *
 * Env vars:
 *   ANTHROPIC_API_KEY  — required
 *   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY — required (from .env)
 *   BATCH_SIZE         — optional, default 5 (parallel requests per round)
 *   LIMIT              — optional, max skills to process (for testing)
 */

import "dotenv/config";
import { db } from "../import/lib/supabase";

const BATCH_SIZE = parseInt(process.env.BATCH_SIZE ?? "5", 10);
const LIMIT = process.env.LIMIT ? parseInt(process.env.LIMIT, 10) : undefined;

const apiKey = process.env.DEEPSEEK_API_KEY;
if (!apiKey) {
  console.error("✖ DEEPSEEK_API_KEY is not set");
  process.exit(1);
}

type SkillRow = {
  id: string;
  name: string;
  description: string;
  skill_md_content: string | null;
};

type Enrichment = {
  description_zh: string;
  use_cases: string[];
  use_cases_en: string[];
  skill_md_summary_zh: string;
};

async function enrichOne(skill: SkillRow): Promise<Enrichment> {
  const mdBody = skill.skill_md_content
    ? skill.skill_md_content.replace(/^---[\s\S]*?---\n?/, "").trimStart()
    : "";
  const context = Array.from(mdBody).slice(0, 800).join("");

  const prompt = `你是一个技术文案专家，帮助用户了解 Claude AI 的技能插件，输出双语内容。

技能名称：${skill.name}
英文描述：${skill.description}
${context ? `\n技能内容（节选）：\n${context}` : ""}

请用 JSON 格式输出以下内容：
1. description_zh：50-80 字的中文描述，准确传达该技能的核心功能，语言简洁自然
2. use_cases：3-5 个中文使用场景短标签（每个 4-8 个字），描述用户会在什么情况下用到这个技能
3. use_cases_en：use_cases 的英文版，3-5 个 Title Case 短标签（每个 1-3 个英文单词），与中文版语义对应
4. skill_md_summary_zh：150-250 字的中文摘要，面向中文用户介绍这个技能的完整功能、使用方式和适用场景，语言流畅易懂

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
  const json = await res.json() as { choices: { message: { content: string } }[] };
  const text = json.choices[0].message.content.trim();
  // Extract JSON even if wrapped in markdown code block
  const jsonMatch = text.match(/\{[\s\S]*\}/);
  if (!jsonMatch) throw new Error(`No JSON in response: ${text}`);
  const parsed = JSON.parse(jsonMatch[0]) as Enrichment;

  if (
    !parsed.description_zh ||
    !Array.isArray(parsed.use_cases) ||
    !Array.isArray(parsed.use_cases_en) ||
    !parsed.skill_md_summary_zh
  ) {
    throw new Error(`Unexpected shape: ${text}`);
  }
  return parsed;
}

async function fetchPendingSkills(): Promise<SkillRow[]> {
  let query = db
    .from("skills")
    .select("id, name, description, skill_md_content")
    .or("description_zh.is.null,use_cases.eq.{},use_cases_en.eq.{},skill_md_summary_zh.is.null")
    .order("github_stars", { ascending: false, nullsFirst: false });

  if (LIMIT) query = query.limit(LIMIT);

  const { data, error } = await query;
  if (error) throw error;
  return (data ?? []) as SkillRow[];
}

async function updateSkill(id: string, enrichment: Enrichment): Promise<void> {
  const { error } = await db
    .from("skills")
    .update({
      description_zh: enrichment.description_zh,
      use_cases: enrichment.use_cases,
      use_cases_en: enrichment.use_cases_en,
      skill_md_summary_zh: enrichment.skill_md_summary_zh,
    })
    .eq("id", id);
  if (error) throw error;
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
          await updateSkill(skill.id, enrichment);
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
}

main().catch((err) => {
  console.error("\n✖ Enrichment failed:");
  console.error(err);
  process.exit(1);
});
