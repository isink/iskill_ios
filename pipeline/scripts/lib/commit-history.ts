export type CommitPageFetcher = (
  page: number,
  perPage: number,
) => Promise<unknown>;

const MAX_PAGES = 100;

export async function fetchEarliestCommitDate(
  fetchPage: CommitPageFetcher,
  perPage = 100,
): Promise<string | undefined> {
  if (!Number.isInteger(perPage) || perPage <= 0 || perPage > 100) {
    throw new Error("Commit page size must be between 1 and 100");
  }

  let earliest: { value: string; timestamp: number } | undefined;

  for (let page = 1; page <= MAX_PAGES; page++) {
    const payload = await fetchPage(page, perPage);
    if (!Array.isArray(payload)) {
      throw new Error("GitHub commits response must be an array");
    }

    for (const item of payload) {
      const record = item as {
        commit?: {
          author?: { date?: unknown } | null;
          committer?: { date?: unknown } | null;
        };
      };
      const rawDate = record.commit?.author?.date ?? record.commit?.committer?.date;
      if (typeof rawDate !== "string" || !Number.isFinite(Date.parse(rawDate))) {
        throw new Error("GitHub commits response contains an invalid commit date");
      }
      const timestamp = Date.parse(rawDate);
      if (!earliest || timestamp < earliest.timestamp) {
        earliest = { value: rawDate, timestamp };
      }
    }

    if (payload.length < perPage) return earliest?.value;
  }

  throw new Error(`Commit history exceeded ${MAX_PAGES} pages`);
}
