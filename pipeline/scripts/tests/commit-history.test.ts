import assert from "node:assert/strict";
import test from "node:test";

import { fetchEarliestCommitDate } from "../lib/commit-history";

test("earliest commit date is selected across reverse-chronological pages", async () => {
  const pages = [
    [
      { commit: { author: { date: "2026-03-01T00:00:00Z" } } },
      { commit: { author: { date: "2025-02-01T00:00:00Z" } } },
    ],
    [
      { commit: { author: { date: "2024-01-01T00:00:00Z" } } },
      { commit: { author: { date: "2020-01-01T00:00:00Z" } } },
    ],
    [],
  ];

  const date = await fetchEarliestCommitDate(
    async (page) => pages[page - 1] ?? [],
    2,
  );

  assert.equal(date, "2020-01-01T00:00:00Z");
});

test("empty commit history omits published_at", async () => {
  assert.equal(await fetchEarliestCommitDate(async () => [], 100), undefined);
});

test("malformed commit dates reject the import", async () => {
  await assert.rejects(
    fetchEarliestCommitDate(
      async () => [{ commit: { author: { date: "not-a-date" } } }],
      100,
    ),
    /invalid commit date/,
  );
});
