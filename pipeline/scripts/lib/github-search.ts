export function assertCompleteGitHubSearch(incomplete: boolean): void {
  if (incomplete) {
    throw new Error("GitHub search returned incomplete results");
  }
}
