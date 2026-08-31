import assert from "node:assert/strict";
import test from "node:test";

import {
  assertOverridesComplete,
  parseOverrideApplicationResult,
  parseOverrides,
} from "../lib/overrides-config";

test("curation overrides are validated before any database write", () => {
  assert.deepEqual(
    parseOverrides({
      featured: ["pdf"],
      ranks: { pdf: 99 },
      categoryOverrides: { pdf: "office" },
    }),
    {
      featured: ["pdf"],
      ranks: { pdf: 99 },
      categoryOverrides: { pdf: "office" },
    },
  );
});

test("invalid ranks, categories, and duplicate slugs are rejected", () => {
  assert.throws(
    () => parseOverrides({ featured: ["pdf", "pdf"], ranks: {}, categoryOverrides: {} }),
    /featured must contain unique/,
  );
  assert.throws(
    () => parseOverrides({ featured: [], ranks: { pdf: 1.5 }, categoryOverrides: {} }),
    /rank for pdf must be an integer/,
  );
  assert.throws(
    () => parseOverrides({ featured: [], ranks: {}, categoryOverrides: { pdf: "unknown" } }),
    /category override for pdf is invalid/,
  );
});

test("override RPC results expose missing slugs instead of claiming full success", () => {
  assert.deepEqual(
    parseOverrideApplicationResult({
      featured_applied: 2,
      ranks_applied: 1,
      categories_applied: 1,
      missing_slugs: ["missing-skill"],
    }),
    {
      featuredApplied: 2,
      ranksApplied: 1,
      categoriesApplied: 1,
      missingSlugs: ["missing-skill"],
    },
  );
  assert.throws(
    () => parseOverrideApplicationResult({ missing_slugs: "missing-skill" }),
    /Invalid apply_skill_overrides result/,
  );
});

test("final sync rejects missing override targets", () => {
  assert.throws(
    () => assertOverridesComplete({
      featuredApplied: 1,
      ranksApplied: 1,
      categoriesApplied: 0,
      missingSlugs: ["missing-skill"],
    }),
    /Override slugs not found: missing-skill/,
  );
});
