import assert from "node:assert/strict";
import test from "node:test";

import {
  parseOptionalPositiveInteger,
  parsePositiveInteger,
} from "../lib/env-number";

test("positive integer environment values are accepted", () => {
  assert.equal(parsePositiveInteger("BATCH_SIZE", "4", 5), 4);
  assert.equal(parsePositiveInteger("BATCH_SIZE", undefined, 5), 5);
  assert.equal(parseOptionalPositiveInteger("LIMIT", undefined), undefined);
  assert.equal(parseOptionalPositiveInteger("LIMIT", "12"), 12);
});

test("zero, negative, fractional, and malformed values are rejected", () => {
  for (const value of ["0", "-2", "1.5", "nope", ""]) {
    assert.throws(
      () => parsePositiveInteger("BATCH_SIZE", value, 5),
      /BATCH_SIZE must be a positive integer/,
    );
  }
});
