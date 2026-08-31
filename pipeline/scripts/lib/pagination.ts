export function nextPageSize(
  maximum: number,
  collected: number,
  limit: number | undefined,
): number {
  if (!Number.isInteger(maximum) || maximum <= 0) {
    throw new Error("Page maximum must be a positive integer");
  }
  if (!Number.isInteger(collected) || collected < 0) {
    throw new Error("Collected count must be a non-negative integer");
  }
  if (limit === undefined) return maximum;
  if (!Number.isInteger(limit) || limit <= 0) {
    throw new Error("Page limit must be a positive integer");
  }
  return Math.max(0, Math.min(maximum, limit - collected));
}

export async function collectKeysetPages<T>(
  pageSize: number,
  fetchPage: (after: string | undefined, size: number) => Promise<T[]>,
  keyFor: (item: T) => string,
): Promise<T[]> {
  if (!Number.isInteger(pageSize) || pageSize <= 0) {
    throw new Error("Page size must be a positive integer");
  }

  const collected: T[] = [];
  let after: string | undefined;
  while (true) {
    const page = await fetchPage(after, pageSize);
    if (page.length > pageSize) {
      throw new Error("Page exceeded requested size");
    }
    for (const item of page) {
      const key = keyFor(item);
      if (!key || (after !== undefined && key <= after)) {
        throw new Error("Keyset page must be strictly ordered after its cursor");
      }
      after = key;
      collected.push(item);
    }
    if (page.length < pageSize) return collected;
  }
}
