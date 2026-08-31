import assert from "node:assert/strict";
import test from "node:test";

import {
  MIN_EXPECTED_ANTIGRAVITY_SKILLS,
  validateAntigravitySkills,
} from "../lib/antigravity-source";

const validSkill = {
  id: "example-skill",
  path: "skills/example-skill",
  category: "Development",
  name: "Example Skill",
  description: "A useful example skill.",
  risk: "none",
  source: "community",
  date_added: "2026-08-31",
};

test("Antigravity source accepts complete unique records", () => {
  const completeSource = Array.from(
    { length: MIN_EXPECTED_ANTIGRAVITY_SKILLS },
    (_, index) => ({
      ...validSkill,
      id: `example-skill-${index}`,
      path: `skills/example-skill-${index}`,
    }),
  );
  assert.deepEqual(validateAntigravitySkills(completeSource), completeSource);
});

test("Antigravity source rejects empty or implausibly truncated indexes", () => {
  assert.throws(
    () => validateAntigravitySkills([]),
    /expected at least 1000 records, received 0/,
  );
  assert.throws(
    () => validateAntigravitySkills([validSkill]),
    /expected at least 1000 records, received 1/,
  );
});

test("Antigravity source rejects schema drift before any write", () => {
  const enoughRecords = Array.from(
    { length: MIN_EXPECTED_ANTIGRAVITY_SKILLS },
    (_, index) => ({
      ...validSkill,
      id: `example-skill-${index}`,
      path: `skills/example-skill-${index}`,
    }),
  );
  assert.throws(
    () => validateAntigravitySkills([
      { ...enoughRecords[0], path: 42 },
      ...enoughRecords.slice(1),
    ]),
    /record 1 path must be a non-empty string/,
  );
  assert.throws(
    () => validateAntigravitySkills([
      { ...enoughRecords[0], id: "" },
      ...enoughRecords.slice(1),
    ]),
    /record 1 id must be a non-empty string/,
  );
});

test("Antigravity source rejects duplicate ids instead of dropping rows", () => {
  const enoughRecords = Array.from(
    { length: MIN_EXPECTED_ANTIGRAVITY_SKILLS },
    (_, index) => ({
      ...validSkill,
      id: `example-skill-${index}`,
      path: `skills/example-skill-${index}`,
    }),
  );
  assert.throws(
    () => validateAntigravitySkills([
      ...enoughRecords,
      { ...enoughRecords[0] },
    ]),
    /duplicate id: example-skill-0/,
  );
});
