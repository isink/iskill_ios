export type Enrichment = {
  description_zh: string;
  use_cases: string[];
  use_cases_en: string[];
  skill_md_summary_zh: string;
};

export type ExistingEnrichment = {
  description_zh: string | null;
  use_cases: string[] | null;
  use_cases_en: string[] | null;
  skill_md_summary_zh: string | null;
};

export type EnrichmentNeeds = {
  descriptionZh: boolean;
  useCasePair: boolean;
  summaryZh: boolean;
};

function boundedText(
  value: unknown,
  field: string,
  minimum: number,
  maximum: number,
): string {
  if (typeof value !== "string") {
    throw new Error(`${field} must contain ${minimum}-${maximum} characters`);
  }
  const normalized = value.trim();
  const length = Array.from(normalized).length;
  if (length < minimum || length > maximum) {
    throw new Error(`${field} must contain ${minimum}-${maximum} characters`);
  }
  return normalized;
}

function boundedStringList(value: unknown, field: string): string[] {
  if (!Array.isArray(value) || value.length < 3 || value.length > 5) {
    throw new Error(`${field} must contain 3-5 non-empty strings`);
  }
  const normalized = value.map((item) =>
    typeof item === "string" ? item.trim() : ""
  );
  if (normalized.some((item) => !item)) {
    throw new Error(`${field} must contain 3-5 non-empty strings`);
  }
  return normalized;
}

function validateListItems(
  items: string[],
  field: string,
  isValid: (item: string) => boolean,
  rule: string,
): string[] {
  if (items.some((item) => !isValid(item))) {
    throw new Error(`${field} items must contain ${rule}`);
  }
  return items;
}

function normalizedValidList(
  value: string[] | null,
  isValid: (item: string) => boolean,
): string[] | null {
  if (!Array.isArray(value) || value.length < 3 || value.length > 5) {
    return null;
  }
  const normalized = value.map((item) =>
    typeof item === "string" ? item.trim() : ""
  );
  return normalized.every((item) => item && isValid(item)) ? normalized : null;
}

function validChineseUseCases(value: string[] | null): string[] | null {
  return normalizedValidList(value, (item) => {
    const length = Array.from(item).length;
    return length >= 4 && length <= 8;
  });
}

function validEnglishUseCases(value: string[] | null): string[] | null {
  return normalizedValidList(value, (item) => {
    const words = item.split(/\s+/).filter(Boolean).length;
    return words >= 1 && words <= 3;
  });
}

function validBoundedText(
  value: string | null,
  minimum: number,
  maximum: number,
): boolean {
  if (typeof value !== "string") return false;
  const length = Array.from(value.trim()).length;
  return length >= minimum && length <= maximum;
}

export function enrichmentNeeds(value: ExistingEnrichment): EnrichmentNeeds {
  const chineseUseCases = validChineseUseCases(value.use_cases);
  const englishUseCases = validEnglishUseCases(value.use_cases_en);
  return {
    descriptionZh: !validBoundedText(value.description_zh, 50, 80),
    useCasePair: !chineseUseCases
      || !englishUseCases
      || chineseUseCases.length !== englishUseCases.length,
    summaryZh: !validBoundedText(value.skill_md_summary_zh, 150, 250),
  };
}

export function preservedUseCaseSide(
  value: ExistingEnrichment,
): { field: "use_cases" | "use_cases_en"; values: string[] } | null {
  if (!enrichmentNeeds(value).useCasePair) return null;
  const chineseUseCases = validChineseUseCases(value.use_cases);
  if (chineseUseCases) return { field: "use_cases", values: chineseUseCases };
  const englishUseCases = validEnglishUseCases(value.use_cases_en);
  if (englishUseCases) {
    return { field: "use_cases_en", values: englishUseCases };
  }
  return null;
}

export function validateEnrichment(value: unknown): Enrichment {
  if (!value || typeof value !== "object") {
    throw new Error("Enrichment must be an object");
  }
  const record = value as Record<string, unknown>;
  const useCases = validateListItems(
    boundedStringList(record.use_cases, "use_cases"),
    "use_cases",
    (item) => {
      const length = Array.from(item).length;
      return length >= 4 && length <= 8;
    },
    "4-8 characters",
  );
  const useCasesEnglish = validateListItems(
    boundedStringList(record.use_cases_en, "use_cases_en"),
    "use_cases_en",
    (item) => {
      const words = item.split(/\s+/).filter(Boolean).length;
      return words >= 1 && words <= 3;
    },
    "1-3 words",
  );
  if (useCases.length !== useCasesEnglish.length) {
    throw new Error("use_cases and use_cases_en must have matching lengths");
  }
  return {
    description_zh: boundedText(record.description_zh, "description_zh", 50, 80),
    use_cases: useCases,
    use_cases_en: useCasesEnglish,
    skill_md_summary_zh: boundedText(
      record.skill_md_summary_zh,
      "skill_md_summary_zh",
      150,
      250,
    ),
  };
}

export function validateEnrichmentForExisting(
  value: unknown,
  existing: ExistingEnrichment,
): Enrichment {
  const enrichment = validateEnrichment(value);
  const preserved = preservedUseCaseSide(existing);
  if (!preserved) return enrichment;
  const generated = enrichment[preserved.field];
  if (generated.length !== preserved.values.length
    || generated.some((item, index) => item !== preserved.values[index])) {
    const label = preserved.field === "use_cases"
      ? "existing valid Chinese tags"
      : "existing valid English tags";
    throw new Error(`${preserved.field} must preserve the ${label}`);
  }
  return enrichment;
}
