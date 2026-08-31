const MAX_RETRIES = 3;
const MAX_DELAY_MS = 60_000;

export function boundedRetryDelayMs(
  attempt: number,
  suggestedDelayMs: number,
): number | undefined {
  if (!Number.isInteger(attempt) || attempt < 0) {
    throw new Error(`Invalid retry attempt: ${attempt}`);
  }
  if (attempt >= MAX_RETRIES) return undefined;
  if (!Number.isFinite(suggestedDelayMs) || suggestedDelayMs < 0) {
    return MAX_DELAY_MS;
  }
  return Math.min(suggestedDelayMs, MAX_DELAY_MS);
}
