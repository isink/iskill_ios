import {
  CURATED_CATEGORIES,
  type CuratedCategory,
} from "../import/lib/category-map";

export type Overrides = {
  featured: string[];
  ranks: Record<string, number>;
  categoryOverrides: Record<string, CuratedCategory>;
};

export type OverrideApplicationResult = {
  featuredApplied: number;
  ranksApplied: number;
  categoriesApplied: number;
  missingSlugs: string[];
};

function recordField(value: unknown, field: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${field} must be an object`);
  }
  return value as Record<string, unknown>;
}

export function parseOverrides(value: unknown): Overrides {
  const root = recordField(value, "overrides");
  const featuredValue = root.featured ?? [];
  if (!Array.isArray(featuredValue)
    || featuredValue.some((slug) => typeof slug !== "string" || !slug.trim())) {
    throw new Error("featured must contain non-empty slugs");
  }
  const featured = featuredValue.map((slug) => (slug as string).trim());
  if (new Set(featured).size !== featured.length) {
    throw new Error("featured must contain unique slugs");
  }

  const ranksValue = recordField(root.ranks ?? {}, "ranks");
  const ranks: Record<string, number> = {};
  for (const [slug, rank] of Object.entries(ranksValue)) {
    if (!slug.trim() || typeof rank !== "number" || !Number.isInteger(rank)) {
      throw new Error(`rank for ${slug || "<empty>"} must be an integer`);
    }
    ranks[slug] = rank;
  }

  const categoriesValue = recordField(
    root.categoryOverrides ?? {},
    "categoryOverrides",
  );
  const categoryOverrides: Record<string, CuratedCategory> = {};
  for (const [slug, category] of Object.entries(categoriesValue)) {
    if (!slug.trim()
      || typeof category !== "string"
      || !CURATED_CATEGORIES.includes(category as CuratedCategory)) {
      throw new Error(`category override for ${slug || "<empty>"} is invalid`);
    }
    categoryOverrides[slug] = category as CuratedCategory;
  }

  return { featured, ranks, categoryOverrides };
}

export function parseOverrideApplicationResult(
  value: unknown,
): OverrideApplicationResult {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Invalid apply_skill_overrides result");
  }
  const result = value as Record<string, unknown>;
  const counts = [
    result.featured_applied,
    result.ranks_applied,
    result.categories_applied,
  ];
  if (counts.some((count) => typeof count !== "number"
      || !Number.isInteger(count)
      || count < 0)
    || !Array.isArray(result.missing_slugs)
    || result.missing_slugs.some((slug) => typeof slug !== "string")) {
    throw new Error("Invalid apply_skill_overrides result");
  }
  return {
    featuredApplied: result.featured_applied as number,
    ranksApplied: result.ranks_applied as number,
    categoriesApplied: result.categories_applied as number,
    missingSlugs: result.missing_slugs as string[],
  };
}

export function assertOverridesComplete(result: OverrideApplicationResult): void {
  if (result.missingSlugs.length > 0) {
    throw new Error(`Override slugs not found: ${result.missingSlugs.join(", ")}`);
  }
}
