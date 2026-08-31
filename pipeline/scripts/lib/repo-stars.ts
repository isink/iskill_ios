export type JSONResponse = {
  ok: boolean;
  status: number;
  statusText: string;
  json(): Promise<unknown>;
};

export type JSONFetcher = (
  url: string,
  init?: { headers?: Record<string, string> },
) => Promise<JSONResponse>;

const defaultFetcher: JSONFetcher = (url, init) => fetch(url, init);

export async function fetchRepoStarsFromGitHub(
  owner: string,
  repo: string,
  headers: Record<string, string>,
  request: JSONFetcher = defaultFetcher,
): Promise<number | undefined> {
  const url = `https://api.github.com/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}`;
  const response = await request(url, { headers });
  if (response.status === 404) return undefined;
  if (!response.ok) {
    throw new Error(`GitHub repo API ${response.status} ${response.statusText}: ${owner}/${repo}`);
  }

  const body = (await response.json()) as { stargazers_count?: unknown };
  const stars = body.stargazers_count;
  if (typeof stars !== "number" || !Number.isInteger(stars) || stars < 0) {
    throw new Error(`GitHub repo API returned no valid star count: ${owner}/${repo}`);
  }
  return stars;
}

export function repoStarsPatch(stars: number | undefined): { github_stars?: number } {
  return stars === undefined ? {} : { github_stars: stars };
}
