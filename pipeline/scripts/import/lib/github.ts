import { env } from "./env";
import { fetchRepoStarsFromGitHub } from "../../lib/repo-stars";

export { repoStarsPatch } from "../../lib/repo-stars";

function authHeaders(): Record<string, string> {
  const h: Record<string, string> = {
    Accept: "application/vnd.github+json",
    "User-Agent": "skiller-importer",
    "X-GitHub-Api-Version": "2022-11-28",
  };
  if (env.githubToken) h.Authorization = `Bearer ${env.githubToken}`;
  return h;
}

/** A missing repo is omitted; request or schema failures abort the import. */
export async function fetchRepoStars(owner: string, repo: string): Promise<number | undefined> {
  return fetchRepoStarsFromGitHub(owner, repo, authHeaders());
}
