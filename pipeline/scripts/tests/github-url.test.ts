import assert from "node:assert/strict";
import test from "node:test";

import { parseGitHubRepositoryURL } from "../lib/github-url";

test("GitHub repository URLs are parsed only from the exact HTTPS host", () => {
  assert.deepEqual(
    parseGitHubRepositoryURL("https://github.com/openai/codex/tree/main/example"),
    { owner: "openai", repo: "codex" },
  );
  assert.deepEqual(
    parseGitHubRepositoryURL("https://github.com/openai/codex.git"),
    { owner: "openai", repo: "codex" },
  );
});

test("missing URLs are skipped but malformed non-empty URLs fail", () => {
  assert.equal(parseGitHubRepositoryURL(null), undefined);
  assert.equal(parseGitHubRepositoryURL("  "), undefined);
  assert.throws(
    () => parseGitHubRepositoryURL("https://notgithub.com/openai/codex"),
    /Invalid GitHub repository URL/,
  );
  assert.throws(
    () => parseGitHubRepositoryURL("https://github.com/openai"),
    /Invalid GitHub repository URL/,
  );
});
