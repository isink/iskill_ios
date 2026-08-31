import assert from "node:assert/strict";
import test from "node:test";

import { assertCompleteGitHubSearch } from "../lib/github-search";
import { collectKeysetPages, nextPageSize } from "../lib/pagination";

test("incomplete GitHub searches fail instead of publishing partial results", () => {
  assert.doesNotThrow(() => assertCompleteGitHubSearch(false));
  assert.throws(() => assertCompleteGitHubSearch(true), /incomplete results/);
});

test("page size respects a limit smaller than the server page maximum", () => {
  assert.equal(nextPageSize(1_000, 0, 10), 10);
  assert.equal(nextPageSize(1_000, 10, 10), 0);
  assert.equal(nextPageSize(1_000, 0, undefined), 1_000);
});

test("keyset pagination reads an exact full page and checks the next page", async () => {
  const rows = Array.from({ length: 1_000 }, (_, index) => ({
    id: String(index).padStart(4, "0"),
  }));
  let calls = 0;
  const collected = await collectKeysetPages(1_000, async (after, size) => {
    calls++;
    return rows.filter((row) => after === undefined || row.id > after).slice(0, size);
  }, (row) => row.id);

  assert.equal(collected.length, 1_000);
  assert.equal(calls, 2);
});

test("keyset pagination does not skip existing rows after an earlier insert", async () => {
  const rows = [{ id: "001" }, { id: "002" }, { id: "003" }];
  let calls = 0;
  const collected = await collectKeysetPages(2, async (after, size) => {
    calls++;
    const page = rows
      .filter((row) => after === undefined || row.id > after)
      .slice(0, size);
    if (calls === 1) rows.unshift({ id: "000" });
    return page;
  }, (row) => row.id);

  assert.deepEqual(collected.map((row) => row.id), ["001", "002", "003"]);
});
