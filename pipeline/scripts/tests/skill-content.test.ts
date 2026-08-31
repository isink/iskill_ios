import assert from "node:assert/strict";
import test from "node:test";

import {
  fetchSkillMarkdown,
  skillContentPatch,
  type TextFetcher,
} from "../import/lib/skill-content";

function response(status: number, body = ""): ReturnType<TextFetcher> {
  return Promise.resolve({
    ok: status >= 200 && status < 300,
    status,
    statusText: status === 404 ? "Not Found" : "Error",
    text: async () => body,
  });
}

test("404 omits skill_md_content instead of clearing stored content", async () => {
  const content = await fetchSkillMarkdown("https://example.test/SKILL.md", async () => response(404));

  assert.equal(content, undefined);
  assert.deepEqual(skillContentPatch(content), {});
});

test("transient HTTP failures reject the import", async () => {
  await assert.rejects(
    fetchSkillMarkdown("https://example.test/SKILL.md", async () => response(429)),
    /429/,
  );
});

test("network failures reject the import", async () => {
  await assert.rejects(
    fetchSkillMarkdown("https://example.test/SKILL.md", async () => {
      throw new Error("offline");
    }),
    /offline/,
  );
});

test("successful markdown is sanitized and included", async () => {
  const content = await fetchSkillMarkdown(
    "https://example.test/SKILL.md",
    async () => response(200, "hello\u0000world"),
  );

  assert.equal(content, "helloworld");
  assert.deepEqual(skillContentPatch(content), { skill_md_content: "helloworld" });
});
