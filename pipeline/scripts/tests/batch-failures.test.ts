import assert from "node:assert/strict";
import test from "node:test";

import { assertNoBatchFailures } from "../lib/batch-failures";
import { boundedRetryDelayMs } from "../lib/rate-limit";

test("zero failures completes normally", () => {
  assert.doesNotThrow(() => assertNoBatchFailures("skill import", 0));
});

test("one or more failures rejects a partial-success batch", () => {
  assert.throws(
    () => assertNoBatchFailures("skill import", 2),
    /2 skill import operation\(s\) failed/,
  );
});

test("invalid failure counts are rejected", () => {
  assert.throws(() => assertNoBatchFailures("skill import", -1), /Invalid failure count/);
  assert.throws(() => assertNoBatchFailures("skill import", 1.5), /Invalid failure count/);
});

test("rate-limit retries use a bounded delay", () => {
  assert.equal(boundedRetryDelayMs(0, 5_000), 5_000);
  assert.equal(boundedRetryDelayMs(1, 600_000), 60_000);
  assert.equal(boundedRetryDelayMs(2, Number.NaN), 60_000);
});

test("rate-limit retries stop after three retries", () => {
  assert.equal(boundedRetryDelayMs(3, 1_000), undefined);
});
