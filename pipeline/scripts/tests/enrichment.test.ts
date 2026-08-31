import assert from "node:assert/strict";
import test from "node:test";

import {
  enrichmentNeeds,
  validateEnrichment,
  validateEnrichmentForExisting,
} from "../lib/enrichment";

const generated = {
  description_zh: ` ${"这是一段准确自然并能清楚说明技能核心能力和适用方式的中文简介".padEnd(50, "好")} `,
  use_cases: [" 代码审查 ", "文档生成", "数据分析"],
  use_cases_en: [" Code Review ", "Docs", "Data Analysis"],
  skill_md_summary_zh: ` ${"这是一段面向中文用户的完整技能摘要，说明主要功能、使用方法和适用场景".padEnd(150, "好")} `,
};

test("enrichment output is non-empty, bounded, and normalized", () => {
  assert.deepEqual(validateEnrichment(generated), {
    description_zh: generated.description_zh.trim(),
    use_cases: ["代码审查", "文档生成", "数据分析"],
    use_cases_en: ["Code Review", "Docs", "Data Analysis"],
    skill_md_summary_zh: generated.skill_md_summary_zh.trim(),
  });

  assert.throws(
    () => validateEnrichment({ ...generated, use_cases: [] }),
    /use_cases must contain 3-5 non-empty strings/,
  );
  assert.throws(
    () => validateEnrichment({ ...generated, description_zh: "  " }),
    /description_zh must contain 50-80 characters/,
  );
  assert.throws(
    () => validateEnrichment({ ...generated, skill_md_summary_zh: "太短" }),
    /skill_md_summary_zh must contain 150-250 characters/,
  );
  assert.throws(
    () => validateEnrichment({ ...generated, use_cases: ["短", "文档生成", "数据分析"] }),
    /use_cases items must contain 4-8 characters/,
  );
  assert.throws(
    () => validateEnrichment({
      ...generated,
      use_cases_en: ["Review Code Carefully Now", "Docs", "Data Analysis"],
    }),
    /use_cases_en items must contain 1-3 words/,
  );
});

test("historical blank and out-of-contract enrichment is queued again", () => {
  assert.deepEqual(
    enrichmentNeeds({
      description_zh: " ",
      use_cases: ["短", "文档生成", "数据分析"],
      use_cases_en: ["Too Many English Words", "Docs", "Data Analysis"],
      skill_md_summary_zh: "旧摘要太短",
    }),
    {
      descriptionZh: true,
      useCasePair: true,
      summaryZh: true,
    },
  );

  assert.deepEqual(
    enrichmentNeeds({
      description_zh: generated.description_zh.trim(),
      use_cases: generated.use_cases.map((item) => item.trim()),
      use_cases_en: generated.use_cases_en.map((item) => item.trim()),
      skill_md_summary_zh: generated.skill_md_summary_zh.trim(),
    }),
    {
      descriptionZh: false,
      useCasePair: false,
      summaryZh: false,
    },
  );
});

test("partial bilingual tags preserve the valid side during repair", () => {
  const current = {
    description_zh: generated.description_zh.trim(),
    use_cases: ["代码审查", "文档生成", "数据分析"],
    use_cases_en: [],
    skill_md_summary_zh: generated.skill_md_summary_zh.trim(),
  };

  assert.throws(
    () => validateEnrichmentForExisting({
      ...generated,
      use_cases: ["安全检查", "内容撰写", "报表分析"],
    }, current),
    /use_cases must preserve the existing valid Chinese tags/,
  );

  assert.deepEqual(
    validateEnrichmentForExisting({
      ...generated,
      use_cases: current.use_cases,
    }, current).use_cases,
    current.use_cases,
  );
});
