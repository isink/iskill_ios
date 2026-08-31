export type GitHubRepository = { owner: string; repo: string };

export function parseGitHubRepositoryURL(
  value: string | null,
): GitHubRepository | undefined {
  if (value === null || !value.trim()) return undefined;

  try {
    const url = new URL(value);
    const segments = url.pathname.split("/").filter(Boolean);
    if (url.protocol !== "https:"
      || url.hostname.toLowerCase() !== "github.com"
      || segments.length < 2) {
      throw new Error();
    }
    const owner = segments[0];
    const repo = segments[1].replace(/\.git$/, "");
    if (!owner || !repo) throw new Error();
    return { owner, repo };
  } catch {
    throw new Error(`Invalid GitHub repository URL: ${value}`);
  }
}
