import assert from "node:assert/strict";
import test from "node:test";

import {
  fetchRepoStarsFromGitHub,
  repoStarsPatch,
  type JSONFetcher,
} from "../lib/repo-stars";

function response(status: number, body: unknown): ReturnType<JSONFetcher> {
  return Promise.resolve({
    ok: status >= 200 && status < 300,
    status,
    statusText: status === 404 ? "Not Found" : "Error",
    json: async () => body,
  });
}

test("missing repositories omit github_stars instead of clearing stored data", async () => {
  const stars = await fetchRepoStarsFromGitHub("owner", "repo", {}, async () => response(404, {}));

  assert.equal(stars, undefined);
  assert.deepEqual(repoStarsPatch(stars), {});
});

test("repository API failures reject the import", async () => {
  await assert.rejects(
    fetchRepoStarsFromGitHub("owner", "repo", {}, async () => response(503, {})),
    /503/,
  );
});

test("repository API validates and preserves a star count", async () => {
  const stars = await fetchRepoStarsFromGitHub(
    "owner",
    "repo",
    {},
    async () => response(200, { stargazers_count: 42 }),
  );

  assert.equal(stars, 42);
  assert.deepEqual(repoStarsPatch(stars), { github_stars: 42 });
});

test("malformed repository responses reject the import", async () => {
  await assert.rejects(
    fetchRepoStarsFromGitHub("owner", "repo", {}, async () => response(200, {})),
    /no valid star count/,
  );
});
