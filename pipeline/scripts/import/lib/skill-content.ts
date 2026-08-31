export type TextResponse = {
  ok: boolean;
  status: number;
  statusText: string;
  text(): Promise<string>;
};

export type TextFetcher = (
  url: string,
  init?: { headers?: Record<string, string> },
) => Promise<TextResponse>;

const defaultFetcher: TextFetcher = (url, init) => fetch(url, init);

export async function fetchSkillMarkdown(
  url: string,
  request: TextFetcher = defaultFetcher,
  headers: Record<string, string> = {},
): Promise<string | undefined> {
  const response = await request(url, { headers });
  if (response.status === 404) return undefined;
  if (!response.ok) {
    throw new Error(`SKILL.md fetch ${response.status} ${response.statusText}: ${url}`);
  }
  return (await response.text()).replace(/\u0000/g, "");
}

export function skillContentPatch(
  content: string | undefined,
): { skill_md_content?: string } {
  return content === undefined ? {} : { skill_md_content: content };
}
