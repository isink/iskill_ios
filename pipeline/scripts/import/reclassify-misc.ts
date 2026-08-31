/**
 * Re-classify skills currently in "misc" using the updated category-map rules.
 * Fetches skill slug + name + description from Supabase, runs mapCategory()
 * against each, and updates any that now resolve to a non-misc category.
 *
 *   npm run reclassify
 */

import { db } from "./lib/supabase";
import { mapCategory } from "./lib/category-map";
import { assertNoBatchFailures } from "../lib/batch-failures";

type Row = { id: string; slug: string; name: string; description: string };

async function fetchAllMisc(): Promise<Row[]> {
  const PAGE = 1000;
  const all: Row[] = [];
  let from = 0;
  while (true) {
    const { data, error } = await db
      .from("skills")
      .select("id, slug, name, description")
      .eq("category", "misc")
      .order("slug")
      .range(from, from + PAGE - 1);
    if (error) throw error;
    const batch = (data ?? []) as Row[];
    all.push(...batch);
    if (batch.length < PAGE) break;
    from += PAGE;
  }
  return all;
}

async function main() {
  console.log("→ Fetching misc skills...");
  const rows = await fetchAllMisc();
  console.log(`✓ ${rows.length} skills in misc`);

  let updated = 0;
  let stayed = 0;
  let failed = 0;

  for (const row of rows) {
    // Try mapping against slug first, then name, then description words
    const candidate =
      mapCategory(row.slug) !== "misc"
        ? mapCategory(row.slug)
        : mapCategory(row.name) !== "misc"
        ? mapCategory(row.name)
        : mapCategory(row.description.slice(0, 200));

    if (candidate === "misc") {
      stayed++;
      continue;
    }

    const { error: updateError } = await db
      .from("skills")
      .update({ category: candidate })
      .eq("id", row.id);

    if (updateError) {
      console.error(`  ✖ ${row.slug}: ${updateError.message}`);
      failed++;
      continue;
    }

    updated++;
    process.stdout.write(`  ↳ ${updated} updated · last: ${row.slug} → ${candidate}\r`);
  }

  process.stdout.write("\n");
  console.log(`\n✅ Done. ${updated} reclassified, ${stayed} remain in misc, ${failed} failed.`);
  assertNoBatchFailures("skill reclassification", failed);
}

main().catch((err) => {
  console.error("\n✖ Failed:", err);
  process.exit(1);
});
