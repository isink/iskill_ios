export type AntigravitySkill = {
  id: string;
  path: string;
  category: string;
  name: string;
  description: string;
  risk: string;
  source: string;
  date_added: string | null;
  plugin?: {
    targets?: { codex?: string; claude?: string };
    setup?: { type?: string; summary?: string; docs?: string | null };
    reasons?: string[];
  };
};

// The upstream index is documented at roughly 1,400 records. Fail closed on a
// major unexplained contraction so a partial CDN/GitHub response cannot be
// reported as a successful full sync.
export const MIN_EXPECTED_ANTIGRAVITY_SKILLS = 1_000;

function record(value: unknown, field: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${field} must be an object`);
  }
  return value as Record<string, unknown>;
}

function nonEmptyString(value: unknown, field: string): asserts value is string {
  if (typeof value !== "string" || !value.trim()) {
    throw new Error(`${field} must be a non-empty string`);
  }
}

function optionalString(value: unknown, field: string): void {
  if (value !== undefined && typeof value !== "string") {
    throw new Error(`${field} must be a string`);
  }
}

function validatePlugin(value: unknown, index: number): void {
  if (value === undefined) return;
  const plugin = record(value, `record ${index} plugin`);
  if (plugin.targets !== undefined) {
    const targets = record(plugin.targets, `record ${index} plugin.targets`);
    optionalString(targets.codex, `record ${index} plugin.targets.codex`);
    optionalString(targets.claude, `record ${index} plugin.targets.claude`);
  }
  if (plugin.setup !== undefined) {
    const setup = record(plugin.setup, `record ${index} plugin.setup`);
    optionalString(setup.type, `record ${index} plugin.setup.type`);
    optionalString(setup.summary, `record ${index} plugin.setup.summary`);
    if (setup.docs !== undefined && setup.docs !== null) {
      optionalString(setup.docs, `record ${index} plugin.setup.docs`);
    }
  }
  if (plugin.reasons !== undefined
    && (!Array.isArray(plugin.reasons)
      || plugin.reasons.some((reason) => typeof reason !== "string"))) {
    throw new Error(`record ${index} plugin.reasons must be a string array`);
  }
}

export function validateAntigravitySkills(value: unknown): AntigravitySkill[] {
  if (!Array.isArray(value)) {
    throw new Error("Unexpected payload: top-level is not an array");
  }
  if (value.length < MIN_EXPECTED_ANTIGRAVITY_SKILLS) {
    throw new Error(
      `Unexpected payload: expected at least ${MIN_EXPECTED_ANTIGRAVITY_SKILLS} records, received ${value.length}`,
    );
  }

  const seen = new Set<string>();
  return value.map((item, zeroBasedIndex) => {
    const index = zeroBasedIndex + 1;
    const skill = record(item, `record ${index}`);
    for (const field of [
      "id",
      "path",
      "category",
      "name",
      "description",
      "risk",
      "source",
    ] as const) {
      nonEmptyString(skill[field], `record ${index} ${field}`);
    }
    const id = skill.id as string;
    if (skill.date_added !== null && typeof skill.date_added !== "string") {
      throw new Error(`record ${index} date_added must be a string or null`);
    }
    validatePlugin(skill.plugin, index);
    if (seen.has(id)) {
      throw new Error(`duplicate id: ${id}`);
    }
    seen.add(id);
    return item as AntigravitySkill;
  });
}
