import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { db } from "./supabase";
import {
  assertOverridesComplete,
  parseOverrideApplicationResult,
  parseOverrides,
  type Overrides,
} from "../../lib/overrides-config";

const __dirname = dirname(fileURLToPath(import.meta.url));
const OVERRIDES_PATH = join(__dirname, "..", "sources.json");

export function loadOverrides(): Overrides {
  const raw = readFileSync(OVERRIDES_PATH, "utf8");
  return parseOverrides(JSON.parse(raw));
}

/**
 * Apply featured flags and rank overrides from sources.json to every skill
 * currently in the catalog. Safe to run multiple times.
 */
export async function applyOverrides(
  options: { strict?: boolean } = {},
): Promise<void> {
  const overrides = loadOverrides();

  const { data, error } = await db.rpc("apply_skill_overrides", {
    p_featured_slugs: overrides.featured,
    p_ranks: overrides.ranks,
    p_category_overrides: overrides.categoryOverrides,
    p_strict: options.strict ?? false,
  });
  if (error) throw new Error(`apply skill overrides: ${error.message}`);
  const result = parseOverrideApplicationResult(data);

  if (result.missingSlugs.length > 0) {
    if (options.strict) {
      assertOverridesComplete(result);
    }
    console.warn(`⚠ Override slugs not found: ${result.missingSlugs.join(", ")}`);
  }

  console.log(
    `✓ Applied overrides: ${result.featuredApplied} featured, ` +
      `${result.ranksApplied} ranked, ` +
      `${result.categoriesApplied} recategorized`,
  );
}
